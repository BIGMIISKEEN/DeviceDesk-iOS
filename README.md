# DeviceDesk for iPhone — native iOS project

This package contains a native SwiftUI iPhone app targeting iOS 27.0 and a Windows HTTPS bridge that reuses DeviceDesk's Windows management engine. The layout uses adaptive navigation, scrolling forms and system text sizes for iPhone 18 Pro and the compact/expanded layouts of iPhone Duo. It does not depend on hard-coded screen dimensions or a browser wrapper.

**Delivery status:** source project and tested bridge API logic. This ZIP is not a signed IPA. Xcode compilation, simulator/device testing and signing still need to be completed on a Mac. Compatibility is a development target, not a claim that the app was tested on either physical iPhone.

## What is included

- `iOS/DeviceDesk.xcodeproj`: open directly in Xcode 27 or newer; shared DeviceDesk scheme, app icon and unit-test target included.
- `.github/workflows/ios-ipa-build.yml`: builds an unsigned `.ipa` on GitHub without a Mac; see `SETUP.md` section B2.
- `WindowsBridge`: HTTPS API, configuration example, fixed-operation PowerShell runner and the existing device/driver/AD engine.
- `Tests`: offline bridge tests and PowerShell syntax validation.
- `SETUP.md`: exact build, signing and Windows bridge setup steps.
- `VALIDATION.md`: checks performed and tests that still require your environment.

## iPhone features

- Select an administrator-approved Windows computer and scan its inventory.
- View OS, model, serial number, RAM, network, programs, disks, processes and SCCM indicators.
- View connected hardware and installed drivers; request a Windows Update driver scan and open recognized official support websites.
- Search Active Directory users/computers; view details, unlock a user or reset a password when permitted.
- Send a popup message to active users on a selected Windows computer.
- Preview and confirm temporary-file cleanup, restart a computer and trim a selected application's working set.
- English-only interface, landscape support, Dynamic Type, accessible system controls, a privacy cover when inactive and a clearly labelled read-only demo.
- HTTPS certificate validation, per-operator action/target permissions, Keychain token storage and background job reconciliation without automatically repeating changes.

## How it connects

The iPhone connects over HTTPS to your Windows bridge on company Wi-Fi or an approved VPN. The bridge performs operations locally or over WinRM and uses its own delegated Windows identity for Active Directory. It must remain online while you use live features.

This is remote Windows administration. It does not inspect iPhone drivers, install iOS drivers, clear other iPhone apps' memory, run PowerShell on the iPhone or bypass Apple's sandbox. SCCM's Windows remote-control viewer and the Windows AD management console cannot run inside this iOS app. Embedded RDP/SCCM screen control and Wake-on-LAN are not implemented in this first native version. The Windows desktop ZIP remains separate and unchanged.

## First run

1. Complete Windows bridge setup in `SETUP.md`.
2. Open `iOS/DeviceDesk.xcodeproj` on a Mac with Xcode 27+.
3. Set your unique bundle identifier and Apple signing team, then build and run on your iPhone.
4. In the app, open **Connection**, enter your bridge HTTPS origin and access token, then tap **Save & connect**.
5. Choose a permitted computer. Read-only scan permissions are enabled in the sample configuration. Your administrator must explicitly add any write actions you need.

You can open **Connection > Open demo data** before setting up the bridge to explore sample screens. Demo mode never executes an operation.

## Operational limits

Driver checks query the source configured on the Windows computer, such as Windows Update or company WSUS. No offer does not prove the newest vendor release is installed. Driver updates are not automatically downloaded or installed. Unknown manufacturers may not have a mapped support link.

Directory search is capped at 200 matches. AD's delegated permissions and password policy still apply. A password reset can succeed while requiring a change at next sign-in fails; that partial result is reported. LastLogonDate is approximate replicated information, not a live presence indicator.

Cleanup only covers Windows Temp and the bridge execution account's Temp folder, for files older than seven days. It uses a target-side, hashed, expiring preview. Popup messages target active Windows sessions and do not prove that users read them. Working-set trimming is temporary.

## Privacy and deployment

Tokens are unique to each configured operator; never share one token among technicians. The bridge stores only token hashes in configuration. Password reset values travel over HTTPS, then over a local pipe to PowerShell; they are not intentionally persisted in the job database or logs. The bridge account's Windows permissions bound every action. Job records are operator-scoped; result bodies expire after 30 minutes when accessed or when another job is submitted. Request IDs remain as audit/idempotency records. Protect the bridge directory and database with Windows ACLs and encrypted storage.

The app includes no advertising or analytics SDKs. It sends administrator-entered data only to the configured bridge, except when you deliberately open an official manufacturer website. App Store privacy declarations must be reviewed for your final deployment, including your organization's retention and collection practices; the included required-reason manifest covers app-local UserDefaults usage only.

## References

- Apple iOS compatibility: https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-27-iphe3fa5df43/27/ios/27
- Xcode requirements: https://developer.apple.com/xcode/system-requirements/
- Adaptive navigation: https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view
- Running on devices: https://developer.apple.com/documentation/xcode/building-and-running-an-app
- HTTPS: https://developer.apple.com/documentation/security/preventing-insecure-network-connections
- Windows bridge server: https://uvicorn.dev/settings/
