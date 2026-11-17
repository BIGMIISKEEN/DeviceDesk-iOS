# Validation status

## Completed in this build environment

- 11 offline Python API tests passed using a mocked Windows runner: HTTPS/authentication boundaries, host/action/target authorization, required confirmation, payload limits, owner-scoped results, durable request-ID deduplication, request lookup, fixed AD server selection, no password persistence/echo, interrupted-write handling and result expiry.
- All eight Swift app/test source files passed Tree-sitter Swift syntax parsing. This is syntax checking, not Swift type-checking or an Xcode build.
- PowerShell parser and reserved-variable checks passed for the bridge runner and bundled Windows engine.
- Info.plist and privacy manifest XML parsed successfully; the shared Xcode scheme parsed; all referenced project object IDs and app source memberships were checked.
- iOS deployment target is 27.0. No arbitrary-load ATS exception or certificate-validation bypass is included.
- The reused Windows engine's earlier isolated tests covered cleanup preview integrity, small responses for 30,000 files, device/driver ID matching, AD identity guards and popup routing. This does not establish live operation on a company network.

Run API tests after installing the bridge requirements plus `httpx`:

```cmd
WindowsBridge\.venv\Scripts\python.exe -m pip install httpx
WindowsBridge\.venv\Scripts\python.exe Tests\test_bridge.py
```

Run PowerShell parsing checks:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tests\validate_powershell.ps1
```

The native unit-test target includes four tests for JSON Int64 precision, HTTPS-origin validation, single/multiple records and unknown-job response decoding. These tests are supplied but were **not run** because this environment has no Xcode or Apple SDK.

## Required before distribution

1. Build and run the shared DeviceDesk scheme in Xcode with the iOS 27 SDK.
2. Run the native unit tests on an available iOS 27 simulator.
3. On iPhone 18 Pro and iPhone Duo, check portrait/landscape, compact/expanded display states, larger accessibility text, keyboard presentation and safe-area layouts. Verify all confirmation controls remain visible.
4. Confirm HTTPS trust and Local Network permission with the company's actual network/VPN.
5. On a designated test PC, verify inventory and driver scans before permitting write actions.
6. With test users only, verify delegated AD search/unlock/password reset and partial-failure reporting.
7. Verify a popup and a cleanup preview on an approved test device. Only then verify confirmed cleanup/restart/memory actions as appropriate.
8. Interrupt the phone connection after a harmless test request; reconnect and use Check pending operation. Confirm no automatic duplicate operation occurs.
9. Review bridge service identity, allowed computers/actions, certificate lifecycle, token provisioning and Windows file permissions for the final deployment.

No real Windows computer was restarted or cleaned, no popup was sent, and no AD account was modified during this build. No physical iPhone or simulator was available. No signed IPA or App Store submission was produced.

## Changes made after this validation

- Added `.github/workflows/ios-ipa-build.yml` (unsigned GitHub build, see `SETUP.md` section B2) and a `.gitignore`. The workflow's shell steps were dry-run with stand-in tools; it has not yet run on GitHub.
- `iOS/DeviceDesk/Models.swift`: `JSONValue.fields` now converts its sorted dictionary entries to unlabeled pairs explicitly with `.map`. Behaviour is unchanged. This line was not re-parsed with Tree-sitter and, like the rest of the Swift code, has not been compiled.
