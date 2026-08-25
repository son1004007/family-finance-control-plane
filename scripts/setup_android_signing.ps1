param(
    [string]$Repository = "son1004007/family-finance-control-plane",
    [string]$KeystorePath = "$env:USERPROFILE\.family-finance\android-notifier-release.jks",
    [string]$KeyAlias = "family-finance-notifier",
    [string]$DownloadRoot = "$env:USERPROFILE\Downloads"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Set-ActionsSecret([string]$Name, [string]$Value) {
    $ghPath = (Get-Command gh).Source
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ghPath
    $psi.Arguments = "secret set $Name --repo $Repository --app actions"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $process.StandardInput.Write($Value)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "Failed to set $Name via GitHub CLI. $stderr"
    }
}

function Get-LatestReleaseRunId {
    $runId = & gh run list `
        --repo $Repository `
        --workflow android-notifier-release.yml `
        --branch main `
        --event workflow_dispatch `
        --limit 1 `
        --json databaseId `
        --jq '.[0].databaseId'
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query Android release workflow runs."
    }
    return (($runId | Out-String).Trim())
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
Set-ActionsSecret "ANDROID_SIGNING_KEYSTORE_BASE64" $keystoreBase64
Set-ActionsSecret "ANDROID_SIGNING_STORE_PASSWORD" $password
Set-ActionsSecret "ANDROID_SIGNING_KEY_ALIAS" $KeyAlias
Set-ActionsSecret "ANDROID_SIGNING_KEY_PASSWORD" $password

$secretNames = @(
    "ANDROID_SIGNING_KEYSTORE_BASE64",
    "ANDROID_SIGNING_STORE_PASSWORD",
    "ANDROID_SIGNING_KEY_ALIAS",
    "ANDROID_SIGNING_KEY_PASSWORD"
)
$listed = & gh secret list --repo $Repository --app actions --json name --jq '.[].name'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to list repository Actions secrets."
}
$missing = @($secretNames | Where-Object { $_ -notin $listed })
if ($missing.Count -gt 0) {
    throw "Signing secrets were not all registered: $($missing -join ', ')"
}

Remove-Variable password -ErrorAction SilentlyContinue
Remove-Variable securePassword -ErrorAction SilentlyContinue
Remove-Variable keystoreBase64 -ErrorAction SilentlyContinue

Write-Host "ANDROID_SIGNING_SETUP=PASS"
Write-Host "Keystore: $KeystorePath"
Write-Host "Back up this keystore and its password separately. Never commit either one to Git."

$previousRunId = Get-LatestReleaseRunId
& gh workflow run android-notifier-release.yml --repo $Repository --ref main
if ($LASTEXITCODE -ne 0) {
    throw "Failed to dispatch Android signed release workflow."
}
Write-Host "ANDROID_RELEASE_DISPATCH=PASS"

$runId = ""
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Seconds 2
    $candidate = Get-LatestReleaseRunId
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -ne $previousRunId) {
        $runId = $candidate
        break
    }
}
if ([string]::IsNullOrWhiteSpace($runId)) {
    throw "Timed out while locating the newly dispatched Android release workflow run."
}

& gh run watch $runId --repo $Repository --exit-status
if ($LASTEXITCODE -ne 0) {
    throw "Android signed release workflow failed. Run ID: $runId"
}
Write-Host "ANDROID_RELEASE_WORKFLOW=PASS run_id=$runId"

$downloadDirectory = Join-Path $DownloadRoot "family-finance-notifier-$runId"
New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null
& gh run download $runId --repo $Repository --dir $downloadDirectory
if ($LASTEXITCODE -ne 0) {
    throw "Failed to download Android release artifact. Run ID: $runId"
}

$apk = Get-ChildItem -LiteralPath $downloadDirectory -Recurse -File -Filter "app-release.apk" | Select-Object -First 1
$checksum = Get-ChildItem -LiteralPath $downloadDirectory -Recurse -File -Filter "app-release.apk.sha256" | Select-Object -First 1
if ($null -eq $apk -or $null -eq $checksum) {
    throw "Downloaded artifact does not contain the expected APK and checksum."
}

Write-Host "ANDROID_RELEASE_DOWNLOAD=PASS"
Write-Host "APK: $($apk.FullName)"
Write-Host "SHA256: $($checksum.FullName)"
Write-Host "Next: install this APK on the Galaxy device and open Family Finance Notifier."
