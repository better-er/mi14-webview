<#
生成发布用密钥库，默认落在仓库内的 keystore 目录，该目录已被 .gitignore 排除。
私钥丢失后无法覆盖升级已发布的包，请连同口令一起备份到仓库外。
用法：pwsh -File tools\gen-keystore.ps1
#>
param(
    [string]$Jdk = '',
    [string]$Path = "$PSScriptRoot\..\keystore\release.keystore",
    [string]$Alias = 'release',
    [string]$Password = ''
)

$ErrorActionPreference = 'Stop'

# 命令行参数优先，其次环境变量，最后才回退到本机默认位置
if (-not $Jdk) { $Jdk = if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:\Program Files\Zulu\zulu-25' } }
$Jdk = $Jdk.TrimEnd('\')

if (Test-Path $Path) { throw "密钥库已存在，确认要重建请先手动备份并删除：$Path" }

if ([string]::IsNullOrWhiteSpace($Password)) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $Password = [Convert]::ToBase64String($bytes)
}

New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
& "$Jdk\bin\keytool.exe" -genkeypair -keystore $Path -alias $Alias `
    -storepass $Password -keypass $Password `
    -keyalg RSA -keysize 2048 -validity 10000 `
    -dname "CN=DSH Mobile, OU=Personal, O=Personal, L=Personal, S=Personal, C=CN"
if ($LASTEXITCODE -ne 0) { throw 'keytool 失败' }

Set-Content -Path (Join-Path (Split-Path $Path) 'password.txt') -Value $Password -NoNewline -Encoding utf8
Write-Host "密钥库：$Path"
Write-Host "别名：$Alias"
Write-Host "口令：$Password"
Write-Host '口令已写入同目录的 password.txt，请一并备份。'
