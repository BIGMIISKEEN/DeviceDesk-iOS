# Setup and installation

## A. Windows bridge

Use a supported, domain-connected Windows PC/server with 64-bit Windows PowerShell 5.1 and Python 3.12 or newer. For AD features, install RSAT Active Directory tools. For remote devices, WinRM and its firewall/certificate configuration must already work. This package does not automatically change your domain, firewall or remoting policy.

Run the bridge under a dedicated Windows identity with only the delegated permissions required for your selected computers and AD actions. The iPhone token selects an application permission profile; it does not impersonate a separate AD identity. If individual Windows impersonation/SSO is required, integrate your organization's identity system before deployment.

Open Command Prompt in `WindowsBridge` and run:

```cmd
py -3 -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
copy config.example.json config.json
.venv\Scripts\python.exe bridge.py --new-token
```

The last command prints an access token and its SHA256 hash. Keep the token privately for entry on the iPhone. Put only the hash in `config.json` as `tokenSHA256`. Generate a different token for each operator.

Edit `config.json`:

| Field | What to enter |
| --- | --- |
| `bind` | The bridge PC's private network IP. The sample uses loopback and is deliberately not reachable from an iPhone until configured. |
| `port` | The chosen HTTPS port, default 9443 |
| `allowedHosts` | Exact bridge DNS hostname(s), without scheme or port |
| `certificate` | PEM certificate/full-chain path, relative to the config directory |
| `privateKey` | PEM private-key path, relative to the config directory |
| `winrmHTTPS` | `true` for already configured WinRM HTTPS; `false` only if your approved domain WinRM setup uses HTTP with its normal Windows authentication protections |
| `directoryServer` | Your domain controller's DNS name; not supplied by the phone |
| `operators[].id` | A unique technician identifier |
| `operators[].tokenSHA256` | Hash generated above, never the access token itself |
| `operators[].targets` | Exact permitted PC names/FQDNs; no wildcards |
| `operators[].actions` | Explicitly allowed actions from the list below |

Start with the sample's read-only actions. Add only actions that this operator should perform:

```text
Inventory
DriverUpdates
DirectorySearch
PopupMessage
TempPreview
TempDelete
TempDiscard
Restart
Trim
DirectoryUnlock
DirectoryResetPassword
```

For cleanup, permit TempPreview, TempDelete and TempDiscard together. Directory actions require RSAT and suitable delegated rights. Write actions have confirmation screens in the app and require an explicit confirmed request at the bridge.

Ask your network/PKI administrator for a certificate whose SAN matches the bridge DNS name, with its full chain trusted by the iPhone. A managed device may receive enterprise trust through MDM. No trust-all certificate handler or ATS exception is included. Ensure company DNS resolves the bridge from the iPhone and the approved network/VPN permits its HTTPS port. Keep this service inside the approved network; do not publish a privileged administration endpoint to the public internet as a shortcut.

Protect the entire bridge folder, `config.json`, certificate key and `jobs.sqlite3` so only the bridge identity and authorized administrators can access them. Keep deployment code non-writable by ordinary users. Use your organization's normal service supervision and log retention process if you want it to run unattended. The provided starter runs in the foreground and stops when you close it.

Run:

```cmd
Start-Bridge.cmd
```

No PowerShell activation script is needed. The worker invokes Windows PowerShell with a process-only execution policy; enforced company signing/application-control policies remain in effect. Use your approved signing/deployment route if those policies block it.

The starter uses one Uvicorn process. Do not run multiple bridge processes against the same database: they would mark each other's running jobs as interrupted. Restart the bridge after changing operators/tokens. Preserve the database across restarts so interrupted jobs and request IDs can be reconciled.

## B. Build the native app on a Mac

1. Install a version of Xcode that includes the iOS 27 SDK and supports your iPhone's installed OS. Check Apple's current Xcode system requirements for the required Mac/macOS.
2. Open `iOS/DeviceDesk.xcodeproj`.
3. Select the **DeviceDesk** target, then **Signing & Capabilities**.
4. Set a unique bundle identifier instead of `com.yourcompany.DeviceDesk`. Select your Apple signing team and enable automatic signing. Set a unique test-target identifier too if needed.
5. Connect the iPhone, trust the Mac and enable Developer Mode if Xcode requests it.
6. Choose the iPhone as the run destination and press Run.
7. Allow local network access when requested, then configure the bridge in **Connection**.

The deployment target is iOS 27.0. Both supported compact iPhone layouts and wider layouts are adaptive; no fixed device model identifiers are required. On iPhone Duo, test both display states and both orientations before distributing the app.

For simulator checks from a Mac terminal:

```sh
xcodebuild -project iOS/DeviceDesk.xcodeproj -scheme DeviceDesk -showdestinations
xcodebuild -project iOS/DeviceDesk.xcodeproj -scheme DeviceDesk -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run unit tests using the exact simulator ID returned by `-showdestinations`:

```sh
xcodebuild -project iOS/DeviceDesk.xcodeproj -scheme DeviceDesk -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' test
```

The simulator can explore Demo mode without the Windows bridge. Live functions require the bridge address to be reachable from the simulator/Mac too.

## B2. Build the app on GitHub without a Mac

`.github/workflows/ios-ipa-build.yml` compiles the app on a GitHub-hosted Mac that has Xcode 27 and publishes an unsigned `DeviceDesk-unsigned.ipa`. The build itself needs no Mac and no Apple developer account.

1. Create a repository on GitHub. Private is recommended, because this folder also contains the Windows bridge code.
2. Put the contents of this folder at the top level of the repository, so that `.github`, `iOS` and `WindowsBridge` sit side by side. Upload them on the repository page with **uploading an existing file**, or push them with git.
3. Open the repository's **Actions** tab, choose **iOS-ipa-build**, then **Run workflow**. If the workflow is not listed, the `.github` folder is not at the top level of the repository.
4. When the run finishes, download the `.ipa` from **Releases** (release `v1.0`). If the build fails, the run's **Summary** page lists the compiler errors.

The `.ipa` is not code-signed, so section C still applies: it has to be signed before an iPhone will install it, and the iPhone must run iOS 27.0 or later. The app keeps the placeholder bundle identifier `com.yourcompany.DeviceDesk` unless you change `PRODUCT_BUNDLE_IDENTIFIER` in the project.

Never upload a live `config.json`, the certificate private key or `jobs.sqlite3`. The included `.gitignore` keeps them out when you use git; GitHub's upload page does not read it.

## C. Distribution

This ZIP cannot be installed directly on an iPhone. Xcode must compile and sign the app. Personal device testing can use your Xcode signing account; TestFlight, App Store or managed enterprise distribution requires the applicable Apple program and your organization's distribution process. No signing certificate, Apple account, provisioning profile or IPA is included.

For a company deployment, use the organization's approved managed distribution method and review App Store privacy disclosures if applicable. Do not put access tokens or Windows passwords into the app bundle.

## D. Interrupted operations

If a network interruption occurs after submission, the app retains a request ID. Reconnect to the same bridge and operator, then tap **Check pending operation**. This only retrieves state; it never resubmits the action. If the bridge restarted during work, the outcome is marked unknown. Verify the Windows target/AD account before acknowledging and clearing the pending reference. Clearing it does not cancel remote work.

## Troubleshooting

- **Cannot connect:** check the HTTPS hostname, private network/VPN routing, certificate trust, port and `allowedHosts`. Do not disable certificate validation.
- **401:** token/hash mismatch or revoked token. Generate and provision a new token.
- **403:** the operation or exact target is not allowed for that operator.
- **Directory unavailable:** verify the configured DC, RSAT and bridge account permissions from the bridge PC.
- **Windows operation unconfirmed:** check the bridge account and WinRM locally. A write may have happened before a transport failure; inspect the target before repeating.
- **Driver scan unknown:** Windows Update policy/service or remote COM restrictions may block it. Check locally on the Windows PC. No offer is not a guarantee of the latest vendor package.
- **No permitted computers:** populate the operator's exact target list and restart the bridge.
