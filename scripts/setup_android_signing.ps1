param(
    [string]$Repository = "son1004007/family-finance-control-plane",
    [string]$KeystorePath = "$env:USERPROFILE\.family-finance\android-notifier-release.jks",
    [string]$KeyAlias = "family-finance-notifier"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

Require-Command "gh"
Require-Command "keytool"

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated. Run: gh auth login"
}

if (Test-Path -LiteralPath $KeystorePath) {
    throw "Refusing to overwrite existing signing key: $KeystorePath"
}

$parent = Split-Path -Parent $KeystorePath
New-Item -ItemType Directory -Force -Path $parent | Out-Null

$securePassword = Read-Host "Enter one strong signing password (12+ chars; used for both store and key)" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrWhiteSpace($password) -or $password.Length -lt 12) {
    throw "Signing password must be at least 12 characters."
}

& keytool -genkeypair `
    -keystore $KeystorePath `
    -storetype PKCS12 `
    -alias $KeyAlias `
    -keyalg RSA `
    -keysize 4096 `
    -validity 10000 `
    -storepass $password `
    -keypass $password `
    -dname "CN=Family Finance Notifier,O=Personal,C=KR"
if ($LASTEXITCODE -ne 0) {
    throw "keytool failed with exit code $LASTEXITCODE"
}

$keystoreBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($KeystorePath))

& gh secret set ANDROID_SIGNING_KEYSTORE_BASE64 --repo $Repository --app actions --body $keystoreBase64
if ($LASTEXITCODE -ne 0) { throw "Failed to set ANDROID_SIGNING_KEYSTORE_BASE64" }

& gh secret set ANDROID_SIGNING_STORE_PASSWORD --repo $Repository --app actions --body $password
if ($LASTEXITCODE -ne 0) { throw "Failed to set ANDROID_SIGNING_STORE_PASSWORD" }

& gh secret set ANDROID_SIGNING_KEY_ALIAS --repo $Repository --app actions --body $KeyAlias
if ($LASTEXITCODE -ne 0) { throw "Failed to set ANDROID_SIGNING_KEY_ALIAS" }

& gh secret set ANDROID_SIGNING_KEY_PASSWORD --repo $Repository --app actions --body $password
if ($LASTEXITCODE -ne 0) { throw "Failed to set ANDROID_SIGNING_KEY_PASSWORD" }

Remove-Variable password -ErrorAction SilentlyContinue
Remove-Variable securePassword -ErrorAction SilentlyContinue
Remove-Variable keystoreBase64 -ErrorAction SilentlyContinue

$secretNames = @(
    "ANDROID_SIGNING_KEYSTORE_BASE64",
    "ANDROID_SIGNING_STORE_PASSWORD",
    "ANDROID_SIGNING_KEY_ALIAS",
    "ANDROID_SIGNING_KEY_PASSWORD"
)
$listed = & gh secret list --repo $Repository --app actions --json name --jq '.[].name'
if ($LASTEXITCODE -ne 0) { throw "Failed to list repository Actions secrets" }

$missing = $secretNames | Where-Object { $_ -notin $listed }
if ($missing.Count -gt 0) {
    throw "Signing secrets were not all registered: $($missing -join ', ')"
}

Write-Host "ANDROID_SIGNING_SETUP=PASS"
Write-Host "Keystore: $KeystorePath"
Write-Host "Back up this keystore and the password separately. Never commit either one to Git."
