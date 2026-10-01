#!/usr/bin/env bash
# 手工构建最小 APK，不需要 Gradle。给 Linux 与 CI 用，Windows 用 build.ps1。
# 用法：bash build.sh
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/android-sdk}}"
BUILD_TOOLS="${BUILD_TOOLS:-36.0.0}"
PLATFORM="${PLATFORM:-android-36}"
MIN_SDK="${MIN_SDK:-26}"
TARGET_SDK="${TARGET_SDK:-36}"
VERSION_CODE="${VERSION_CODE:-1}"
VERSION_NAME="${VERSION_NAME:-1.0}"
KEYSTORE="${KEYSTORE:-$HOME/.android/debug.keystore}"
KS_ALIAS="${KS_ALIAS:-androiddebugkey}"
KS_PASS="${KS_PASS:-android}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/app/src/main"
OUT="$ROOT/build"
BT="$SDK/build-tools/$BUILD_TOOLS"
ANDROID_JAR="$SDK/platforms/$PLATFORM/android.jar"

for tool in aapt2 zipalign apksigner d8; do
    [ -e "$BT/$tool" ] || { echo "缺少构建工具：$BT/$tool" >&2; exit 1; }
done
[ -f "$ANDROID_JAR" ] || { echo "缺少 android.jar：$ANDROID_JAR" >&2; exit 1; }

# 没有现成密钥库时生成一个临时调试密钥，保证 CI 里开箱就能出包
if [ ! -f "$KEYSTORE" ]; then
    echo "[0/7] 生成临时调试密钥"
    mkdir -p "$(dirname "$KEYSTORE")"
    keytool -genkeypair -keystore "$KEYSTORE" -alias "$KS_ALIAS" \
        -storepass "$KS_PASS" -keypass "$KS_PASS" \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=DSH Mobile, OU=Debug, O=Debug, L=Debug, S=Debug, C=CN"
fi

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex" "$ROOT/dist"

echo "[1/7] 编译资源"
"$BT/aapt2" compile --dir "$SRC/res" -o "$OUT/res.zip"

echo "[2/7] 链接资源与清单"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" \
    --manifest "$SRC/AndroidManifest.xml" --java "$OUT/gen" \
    --min-sdk-version "$MIN_SDK" --target-sdk-version "$TARGET_SDK" \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" "$OUT/res.zip"

echo "[3/7] 编译 Java"
find "$SRC/java" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
javac -encoding UTF-8 -source 11 -target 11 -Xlint:-options \
    -classpath "$ANDROID_JAR" -d "$OUT/classes" @"$OUT/sources.txt"

echo "[4/7] 转 dex"
find "$OUT/classes" -name '*.class' > "$OUT/classfiles.txt"
"$BT/d8" --release --min-api "$MIN_SDK" --lib "$ANDROID_JAR" \
    --output "$OUT/dex" @"$OUT/classfiles.txt"

echo "[5/7] 写入 classes.dex"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT" && zip -q -j unsigned.apk dex/classes.dex)

echo "[6/7] 四字节对齐"
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "[7/7] 签名"
APK="$ROOT/dist/dsh-$VERSION_NAME.apk"
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$KS_ALIAS" \
    --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
    --out "$APK" "$OUT/aligned.apk"

"$BT/apksigner" verify --print-certs "$APK"
echo "完成：$APK  版本 $VERSION_NAME ($VERSION_CODE)"
