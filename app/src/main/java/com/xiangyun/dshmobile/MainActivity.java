package com.xiangyun.dshmobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.net.http.SslError;
import android.os.Bundle;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.HttpAuthHandler;
import android.webkit.SslErrorHandler;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ProgressBar;

import java.util.ArrayList;
import java.util.List;

/**
 * 最小可用的网页壳：用系统 WebView 打开一个自建站点，地址由用户首次启动时填写。
 * 额外处理两件自建站点常遇到的事：自签名证书、HTTP Basic 认证。
 */
public class MainActivity extends Activity {

    /**
     * 预置的默认地址，留空表示首次启动时让用户自己填。
     * 想为固定站点出一个定制包，把地址写在这里。
     */
    private static final String FALLBACK_URL = "";

    private static final String PREFS = "portal";

    private WebView web;
    private ProgressBar progress;
    private SharedPreferences prefs;

    /** 本次进程是否已经用保存的凭据试过一次，避免密码错误时死循环。 */
    private boolean authTried = false;

    /** 同一页面并发的证书错误只弹一次窗，其余挂起等待用户选择。 */
    private final List<SslErrorHandler> pendingSsl = new ArrayList<>();
    private boolean sslDialogShowing = false;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        // Android 15 起 targetSdk 35 以上强制沉浸式，靠这个让内容避开状态栏与导航栏
        root.setFitsSystemWindows(true);

        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        root.addView(progress, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));

        web = new WebView(this);
        root.addView(web, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        s.setBuiltInZoomControls(true);
        s.setDisplayZoomControls(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
                if (prefs.getBoolean("ssl_allowed", false)) {
                    handler.proceed();
                    return;
                }
                pendingSsl.add(handler);
                if (sslDialogShowing) {
                    return;
                }
                sslDialogShowing = true;
                new AlertDialog.Builder(MainActivity.this)
                        .setTitle(R.string.ssl_title)
                        .setMessage(getString(R.string.ssl_message, error.getUrl()))
                        .setCancelable(false)
                        .setPositiveButton(R.string.ssl_continue, new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface dialog, int which) {
                                prefs.edit().putBoolean("ssl_allowed", true).apply();
                                resolvePendingSsl(true);
                            }
                        })
                        .setNeutralButton(R.string.ssl_change_url, new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface dialog, int which) {
                                resolvePendingSsl(false);
                                askForUrl();
                            }
                        })
                        .setNegativeButton(R.string.ssl_cancel, new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface dialog, int which) {
                                resolvePendingSsl(false);
                            }
                        })
                        .show();
            }

            @Override
            public void onReceivedHttpAuthRequest(WebView view, final HttpAuthHandler handler,
                                                  String host, String realm) {
                String user = prefs.getString("user", null);
                String pass = prefs.getString("pass", null);
                if (user != null && pass != null && !authTried) {
                    authTried = true;
                    handler.proceed(user, pass);
                    return;
                }
                showAuthDialog(handler, host, user, pass);
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int newProgress) {
                progress.setProgress(newProgress);
                progress.setVisibility(newProgress >= 100 ? View.GONE : View.VISIBLE);
            }
        });

        if (saved != null) {
            web.restoreState(saved);
        } else {
            String url = prefs.getString("url", null);
            if (url == null || url.isEmpty()) {
                askForUrl();
            } else {
                web.loadUrl(url);
            }
        }
    }

    /** 首次启动没有地址，或用户主动要换站点时，都在这里问。 */
    private void askForUrl() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        box.setPadding(pad, pad, pad, 0);

        final EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setHint(R.string.url_hint);
        String current = prefs.getString("url", null);
        input.setText(current != null ? current : FALLBACK_URL);
        input.setSelection(input.getText().length());
        box.addView(input);

        new AlertDialog.Builder(this)
                .setTitle(R.string.url_title)
                .setView(box)
                .setCancelable(true)
                .setOnCancelListener(new DialogInterface.OnCancelListener() {
                    @Override
                    public void onCancel(DialogInterface dialog) {
                        // 地址框被返回键关掉且还没有可用地址，直接退出而不是停在空白页
                        finish();
                    }
                })
                .setPositiveButton(android.R.string.ok, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        openUrl(normalizeUrl(input.getText().toString()));
                    }
                })
                .show();
    }

    /** 只补协议头，不做别的猜测；输入为空返回 null，调用方重新询问。 */
    private String normalizeUrl(String raw) {
        String url = raw.trim();
        if (url.isEmpty()) {
            return null;
        }
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            url = "https://" + url;
        }
        return url;
    }

    /** 换站点后，上一个站点的证书许可与登录凭据都要作废。 */
    private void openUrl(String url) {
        if (url == null) {
            askForUrl();
            return;
        }
        String old = prefs.getString("url", null);
        if (old == null || !old.equals(url)) {
            prefs.edit().remove("ssl_allowed").remove("user").remove("pass").apply();
        }
        prefs.edit().putString("url", url).apply();
        authTried = false;
        web.loadUrl(url);
    }

    /** 用户做出选择后统一处理挂起的证书错误。 */
    private void resolvePendingSsl(boolean proceed) {
        sslDialogShowing = false;
        for (SslErrorHandler handler : pendingSsl) {
            if (proceed) {
                handler.proceed();
            } else {
                handler.cancel();
            }
        }
        pendingSsl.clear();
    }

    /** HTTP Basic 认证没有系统弹窗，只能自己问一次并记住。 */
    private void showAuthDialog(final HttpAuthHandler handler, String host, String user, String pass) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        box.setPadding(pad, pad, pad, 0);

        final EditText userInput = new EditText(this);
        userInput.setHint(R.string.auth_user);
        userInput.setSingleLine(true);
        if (user != null) {
            userInput.setText(user);
        }
        box.addView(userInput);

        final EditText passInput = new EditText(this);
        passInput.setHint(R.string.auth_pass);
        passInput.setSingleLine(true);
        passInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        if (pass != null) {
            passInput.setText(pass);
        }
        box.addView(passInput);

        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.auth_title, host))
                .setView(box)
                .setCancelable(false)
                .setPositiveButton(android.R.string.ok, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        String u = userInput.getText().toString().trim();
                        String p = passInput.getText().toString();
                        prefs.edit().putString("user", u).putString("pass", p).apply();
                        authTried = true;
                        handler.proceed(u, p);
                    }
                })
                .setNegativeButton(android.R.string.cancel, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        handler.cancel();
                    }
                })
                .show();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @Override
    protected void onPause() {
        web.onPause();
        super.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && web.canGoBack()) {
            web.goBack();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }
}