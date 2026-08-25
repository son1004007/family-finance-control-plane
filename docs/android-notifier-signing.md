# Android Notifier stable signing and sideload release

This project distributes the personal `Family Finance Notifier` APK by sideloading, not through a public app store.

## Security boundary

- The Android signing private key must never be committed to this public repository.
- Release signing material is injected only through GitHub Actions repository secrets.
- Pull-request CI never receives the production signing key. It generates an ephemeral CI-only key to exercise the same Gradle release-signing path.
- The release workflow is `workflow_dispatch` only and uploads the signed APK as a bounded GitHub Actions artifact.
- Keep the local keystore backup and its password in separate protected locations. Losing the signing key prevents future APK updates from being installed over the existing app.

Required Actions secrets:

- `ANDROID_SIGNING_KEYSTORE_BASE64`
- `ANDROID_SIGNING_STORE_PASSWORD`
- `ANDROID_SIGNING_KEY_ALIAS`
- `ANDROID_SIGNING_KEY_PASSWORD`

## One-time Windows setup

Prerequisites:

- GitHub CLI (`gh`) authenticated to the repository.
- JDK with `keytool` available on `PATH`.
- PowerShell.

From a fresh clone of this repository, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup_android_signing.ps1
```

The script:

1. refuses to overwrite an existing signing key;
2. asks for one strong password;
3. creates a long-lived PKCS12 signing keystore under `%USERPROFILE%\.family-finance\`;
4. registers the four Actions secrets with GitHub CLI;
5. verifies that all required secret names exist.

After the script reports `ANDROID_SIGNING_SETUP=PASS`, back up the generated keystore and store its password separately. Do not put either in Git, cloud notes, chat history, or source documentation.

## Build a signed APK

Run the GitHub Actions workflow `Android Notifier Signed Release` from `main` after the signing secrets exist.

The workflow:

1. restores the keystore only into the ephemeral runner;
2. generates a monotonically increasing sideload `versionCode` from the workflow run number;
3. builds the minified release APK;
4. verifies the APK signature with Android `apksigner`;
5. publishes the APK plus SHA-256 checksum as a 30-day workflow artifact.

The expected artifact contains:

```text
app-release.apk
app-release.apk.sha256
```

## Phone activation

Only install a release APK produced by the signed-release workflow.

On the Galaxy device:

1. install the APK;
2. open `Family Finance Notifier`;
3. tap `1. 알림 접근 허용` and enable the notifier;
4. tap `2. 비공개 릴레이 승인` and approve the Google `drive.appdata` authorization;
5. tap `3. 절전 예외 설정` if Samsung battery management could suspend background work.

Notification sound, vibration and popup are not required. Android notification posting itself must remain enabled for the financial apps whose events should be collected.

## Update rule

Future APKs must be signed with the same keystore and must have a higher `versionCode`. The release workflow enforces the latter by deriving `versionCode` from its monotonically increasing workflow run number.

If the signing key is lost, do not create a different key and present it as an update. Android will treat the new signature as a different trust lineage and an in-place update will fail.
