<#
手工构建最小 APK，不需要 Gradle。
用法：pwsh -File build.ps1
发版：pwsh -File build.ps1 -VersionCode 2 -VersionName 1.1 -Keystore ..\keystore\release.keystore -KsAlias release -KsPass 你的口令
#>
param(
    [string]$Sdk = '',
    [string]$Jdk = '',
    [string]$BuildTools = '36.0.0',
    [string]$Platform = 'android-36',
    [int]$MinSdk = 26,
    [int]$TargetSdk = 36,
    [int]$VersionCode = 1,
    [string]$VersionName = '1.0',
    [string]$Keystore = "$env:USERPROFILE\.android\debug.keystore",
    [string]$KsAlias = 'androiddebugkey',
    [string]$KsPass = 'android'
)

$ErrorActionPreference = 'Stop'

# 命令行参数优先，其次环境变量，最后才回退到本机默认位置
if (-not $Sdk) { $Sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'D:\AAA_no_space_root\Android_SDK' } }
if (-not $Jdk) { $Jdk = if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:\Program Files\Zulu\zulu-25' } }
$Sdk = $Sdk.TrimEnd('\')
$Jdk = $Jdk.TrimEnd('\')

$root = $PSScriptRoot
$src = Join-Path $root 'app\src\main'
$out = Join-Path $root 'build'
$bt = Join-Path $Sdk "build-tools\$BuildTools"
$androidJar = Join-Path $Sdk "platforms\$Platform\android.jar"

$env:JAVA_HOME = $Jdk
$javaBin = Join-Path $Jdk 'bin'

foreach ($tool in @('aapt2.exe', 'zipalign.exe', 'apksigner.bat', 'd8.bat')) {
    $p = Join-Path $bt $tool
    if (-not (Test-Path $p)) { throw "缺少构建工具：$p" }
}
if (-not (Test-Path $androidJar)) { throw "缺少 android.jar：$androidJar" }
if (-not (Test-Path $Keystore)) { throw "缺少签名密钥库：$Keystore" }

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $out, "$out\gen", "$out\classes", "$out\dex" | Out-Null

Write-Host '[1/7] 编译资源'
& "$bt\aapt2.exe" compile --dir "$src\res" -o "$out\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 compile 失败' }

Write-Host '[2/7] 链接资源与清单'
& "$bt\aapt2.exe" link -o "$out\base.apk" -I $androidJar --manifest "$src\AndroidManifest.xml" --java "$out\gen" --min-sdk-version $MinSdk --target-sdk-version $TargetSdk --version-code $VersionCode --version-name $VersionName "$out\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link 失败' }

Write-Host '[3/7] 编译 Java'
$sources = @()
$sources += Get-ChildItem -Path "$src\java" -Recurse -Filter *.java | Select-Object -ExpandProperty FullName
$sources += Get-ChildItem -Path "$out\gen" -Recurse -Filter *.java | Select-Object -ExpandProperty FullName
& "$javaBin\javac.exe" -encoding UTF-8 -source 11 -target 11 -Xlint:-options -classpath $androidJar -d "$out\classes" $sources
if ($LASTEXITCODE -ne 0) { throw 'javac 失败' }

Write-Host '[4/7] 转 dex'
$classes = Get-ChildItem -Path "$out\classes" -Recurse -Filter *.class | Select-Object -ExpandProperty FullName
& "$bt\d8.bat" --release --min-api $MinSdk --lib $androidJar --output "$out\dex" $classes
if ($LASTEXITCODE -ne 0) { throw 'd8 失败' }

Write-Host '[5/7] 写入 classes.dex'
Copy-Item "$out\base.apk" "$out\unsigned.apk" -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open("$out\unsigned.apk", 'Update')
try {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$out\dex\classes.dex", 'classes.dex', [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
} finally {
    $zip.Dispose()
}

Write-Host '[6/7] 四字节对齐'
& "$bt\zipalign.exe" -f -p 4 "$out\unsigned.apk" "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'zipalign 失败' }

Write-Host '[7/7] 签名'
New-Item -ItemType Directory -Force -Path "$root\dist" | Out-Null
$apk = Join-Path $root "dist\dsh-$VersionName.apk"
& "$bt\apksigner.bat" sign --ks $Keystore --ks-key-alias $KsAlias --ks-pass "pass:$KsPass" --key-pass "pass:$KsPass" --out $apk "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'apksigner 失败' }

& "$bt\apksigner.bat" verify --print-certs $apk
Write-Host "完成：$apk  版本 $VersionName ($VersionCode)"
