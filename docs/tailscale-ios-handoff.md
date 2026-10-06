# Remote iPhone installs over Tailscale

Set up and verify a persistent installation bridge for Xcode-signed Subway Nerds
builds. This work is deferred until the user is available for the initial phone
pairing. The widget refresh settings are implemented and tested; their latest
signed build is ready, but installation was blocked by unavailable CoreDevice
services.

## Current state

- The Mac and iPhone are connected to the same Tailscale tailnet. The phone
  appeared as `iphone185` and answered a Tailscale ping in 42 ms on October 6,
  2026. Recheck its current address rather than assuming the saved address is
  still correct.
- Xcode's normal pairing and Developer Mode are already configured. CoreDevice
  reported error 4016 when accessing the paired phone and error 1000 when given
  its Tailscale DNS name. Network reachability alone did not establish a trusted
  developer connection.
- The target phone runs iOS 27.0.1. Compatibility with the proposed bridge still
  needs physical-device verification.
- No bridge, additional pairing, or new dependencies were installed for this
  investigation. Follow the workspace's package-installation approval rules
  before adding tools.
- Local evidence lives under `artifacts/widgets/`: `tailscale-status.json`,
  `tailscale-phone-ping.log`, `tailscale-phone-coredevice.log`, and
  `tailscale-phone-processes.log`. These artifacts are ignored by Git.

## Proposed installation bridge

The third-party [iOS OTA project](https://github.com/lyo-eos/ios-ota#english)
documents a persistent RemotePairing connection over Tailscale. Xcode builds and
signs; the bridge installs. It does not add a native remote Xcode Run Destination.

Its documented limits are:

- Initial pairing: unlocked phone on the Mac's LAN.
- Subsequent connection acquisition: phone on any Wi-Fi network.
- Cellular installs: supported by continuing an already active session.
- Recovery after a dropped cellular session: phone must rejoin Wi-Fi.

Physical verification on this iOS 27 phone is still required.

## Setup for the next session

1. Obtain required installation approval, review and pin the upstream revision,
   and follow its Bootstrap, Install, and Configure instructions. Keep this
   tooling outside the application repository.
2. Recheck the intended phone's address using
   `/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json` and a
   bounded `ping`.
3. Arrange the one-time pairing through **Settings > Developer > Paired Macs**,
   selecting **iOS OTA**. Preserve the existing Xcode pairing. Keep pairing
   credentials private and outside Git and logs.
4. Configure the verified phone, start the bridge's LaunchAgent, and require a
   sustained `active` state after the pairing helper exits. `doctor` alone only
   establishes local prerequisites.
5. Build with existing signing, then invoke the bridge's
   `install --profile <private-profile> <signed-app>`. Use an in-place upgrade
   to preserve favorites, filters, and downloaded data.

From the repository root, the existing device build command is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project ios/SubwaysForNerds.xcodeproj \
  -scheme SubwaysForNerds -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios/DerivedData/WidgetPhone \
  -allowProvisioningUpdates -jobs 2
```

The signed output is
`ios/DerivedData/WidgetPhone/Build/Products/Debug-iphoneos/SubwaysForNerds.app`,
with bundle ID `nyc.juliet.subwaysfornerds`. Both app and widget extension use
the existing development team and matching App Group. Keep signing overrides,
profiles, and pairing records in their existing private locations.

## Acceptance and repeatable use

- Confirm the bridge reads back the installed bundle and that the phone opens
  the latest build. Check separate Home Screen and Lock Screen refresh choices
  under **Settings > Widgets**, plus preserved favorites and widget filters.
- After `status` reports `active`, move the phone to a different network and
  then cellular. Verify another in-place install over the existing session.
- Record the bridge revision, phone OS, network conditions, commands, and
  redacted receipts in `artifacts/`. Report Wi-Fi acquisition and cellular
  continuation separately; a ping or `doctor` result is not installation proof.
- Exercise loss and recovery of the session. Verify that returning to Wi-Fi
  restores the connection without replacing the pairing identity.
- Add a repeatable project installation command only after physical validation.
  Preserve the ordinary Xcode/USB workflow alongside it.

For widget implementation and completed QA, see [iOS development](ios.md) and
[validation results](validation.md).
