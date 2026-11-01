# TestFlight from Windows

Signed builds come from GitHub's macOS runners. No Mac is needed. The pipeline was first built and proven in the Codex version of Folio (Apple accepted its upload on 2026-11-01) and now builds this codebase.

## What is already set up

Repository `Codebater/folio`, environment **`testflight`**:

| Kind | Name | Notes |
|---|---|---|
| Variable | `APPLE_TEAM_ID` | `69XAW2T542` |
| Variable | `APP_BUNDLE_ID` | `com.codebater.folio` (App Store Connect record "Folio Radio") |
| Secret | `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD` | Apple Distribution certificate + key |
| Secret | `APPLE_PROFILE_BASE64` | App Store Connect provisioning profile for the bundle id |
| Secret | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_BASE64` | App Store Connect API key, used only for upload |

Never paste secret values into chat, issues or logs. To replace one, base64 the file in PowerShell and paste it straight into the GitHub secret:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\distribution.p12))) | Set-Clipboard
```

## Making a build

1. Make sure **iOS** CI is green for the commit (package tests, app build, unit and UI tests on the simulator).
2. Actions → **Signed TestFlight build** → Run workflow. Leave **Upload** unticked first. The workflow:
   - runs the package tests and generates the Xcode project
   - checks the profile (team, bundle id, not expired, App Store type) with `scripts/export_options.py`
   - imports the certificate into a temporary keychain
   - archives and exports the IPA (not kept as an artifact, since the repository may be public)
   - deletes the credentials again, even on failure
3. Run it again with **Upload** ticked. `altool` uploads the IPA with the API key. `scripts/verify_upload.py` fails the job unless Apple explicitly acknowledges the upload; some `altool` failures exit with status 0.
4. In App Store Connect → TestFlight, wait for processing and answer export compliance. The app only uses HTTPS through the system, and `ITSAppUsesNonExemptEncryption` is `false`. Then add internal testers.

The build number is the workflow's run number, so it always goes up; a step checks the exported IPA and stops before upload if the number doesn't match. Raise `MARKETING_VERSION` in `Apps/FolioiOS/project.yml` for a new version.

Builds already in App Store Connect: 0.1.0 (3) from the Codex version, and 1.0 (1) from this codebase's first upload (its Info.plist had fixed version numbers; fixed since). TestFlight listed 1.0 (1) above every 0.1.0 build, so it was expired by hand in App Store Connect on 2026-11-01.

Two manual workflows talk to the App Store Connect API with the same key:

- **TestFlight status** (`scripts/asc_status.py`) is read-only. It lists the newest builds with their processing, beta and expiry states, plus the beta groups and tester counts.
- **Expire TestFlight build** (`scripts/asc_expire.py`) expires one build by exact version and build number, and refuses the newest. Apple only allows this for keys with the App Manager or Admin role; the current key gets HTTP 403, so expire builds in App Store Connect (TestFlight → iOS → the build → Expire Build) until the key's role changes.

## If it fails

- **Signing identity not found:** the P12 is missing its private key, or the password is wrong.
- **Profile mismatch or expired:** regenerate the App Store profile for `com.codebater.folio` with the current certificate and update `APPLE_PROFILE_BASE64`.
- **"… does not support provisioning profiles" for a package target:** a profile was passed to every target. The workflow passes `FOLIO_PROFILE_SPECIFIER`, which only the Folio app target uses (`project.yml`); Swift package resource bundles such as FluidAudio's can't take a profile.
- **API authorization:** check the key id, issuer id and the key's role. Expired Apple agreements also block uploads.
- **Duplicate build number:** re-run (the run number increases).
- **SDK too old:** Apple raises the minimum SDK over time. Update `DEVELOPER_DIR` in the workflow to a newer Xcode on the runner.

## Public repository

The repository is prepared to be public (standard GitHub runners, including macOS, are free there):

- Signing and App Store Connect secrets live only in the `testflight` environment. Only the `main` branch may use it, and GitHub never passes secrets to workflows started from forks.
- The signed IPA is not kept as an artifact.
- The default workflow token is read-only.
- Business notes and research live in a private repository (`andrej/folio-notes` on Forgejo), not here.

Right after switching the repository to public, run `scripts/harden-public-repo.sh` once. It turns on secret scanning with push protection, and makes workflows from outside contributors wait for approval. GitHub offers both only on public repositories.
