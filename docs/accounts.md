# Portable settings and accounts

The iPhone/iPad app and website import and export the same `.nerds` file. Accounts
are optional. File transfer works offline and before provider configuration.

## File format and migration

`.nerds` is UTF-8 JSON with `format: "subways-for-nerds"`, `version: 1`, an ISO
`exportedAt` timestamp, `lastStation`, and `settings`. The latter contains ordered
favorites, theme ID, station preferences, and widget preferences. Station
preferences contain direction, route IDs, and board grouping. Widget settings
include independent station filters, the match-app toggle, and separate Home Screen
and Lock Screen display options, including direction order and service icons.
Older v1 files without Lock Screen settings use the native legacy-display migration.
The TypeScript/Swift fixtures in `test/fixtures/settings.nerds` and
`ios/TransitCore/Tests/TransitCoreTests/Fixtures/settings.nerds` must remain identical.

Imports validate the full structure and a 1 MiB limit before showing a replacement
preview. Unknown station IDs survive offline import and cross-platform round trips.
Unknown theme IDs remain stored and display the default palette until supported.
Future format versions are rejected. Files exclude credentials, precise location,
recent-board bookkeeping, downloaded fleet data, and development API addresses.

The native app migrates `preferences.json` and `widgets.json` into an atomic
`settings.json` record. The website migrates legacy `sfn:` preference keys into
`sfn:settings:v1`. Legacy data remains available for rollback but is not updated.
The canonical record includes the sync baseline and revision, making pending
local edits durable without storing credentials in preference files.

The app declares `nyc.juliet.subwaysfornerds.settings`, conforming to JSON. Opening a
`.nerds` attachment presents the same preview as the file importer. File import
updates the local last station; automatic account sync does not change navigation.
Web edits retain native-only board grouping and widget fields.

## Provider setup from scratch

1. Enroll in the Apple Developer Program through your own Apple account. Enrollment,
   payment, and legal agreements are owner actions. Keep the existing app and widget
   bundle IDs unless their registration requires a change.
2. Enable Sign in with Apple on the native App ID. Create a Services ID for web
   authentication and group it with that primary App ID so native and web identities
   match. Configure `juliet.nyc` and the exact HTTPS return URL:
   `https://juliet.nyc/subwaysForNerds/api/v1/auth/apple/callback`.
3. Create an Apple Sign in with Apple private key. Keep its `.p8` file private;
   record the team ID and key ID. The server generates five-minute client secrets
   with this key, avoiding a manually maintained six-month secret.
4. Create a Google Cloud project and configure its OAuth consent screen, audience,
   support email, homepage, and privacy URL
   `https://juliet.nyc/subwaysForNerds/privacy.html`. Start with test users, then
   complete Google's publishing requirements before public login.
5. Create an iOS OAuth client for the native bundle ID and a Web application OAuth
   client for the server. Set the exact web redirect:
   `https://juliet.nyc/subwaysForNerds/api/v1/auth/google/callback`.
   Only identity/email scopes are used by the web login; the native SDK also uses
   its basic profile scopes. The app does not store profile names or photos.
6. Put the reversed Google **iOS** client ID into the ignored native
   `Local.xcconfig` as `SFN_GOOGLE_REVERSED_CLIENT_ID`. The runtime obtains both
   client IDs from the configured server. Rebuild after changing the callback.
7. Supply the server environment below through the deployment secret mechanism.
   Do not commit real values, private keys, or provisioning files. For direct Node execution, load the private environment with
   `node --env-file=.env --import tsx server/index.ts`; Compose forwards these
   variables from its environment or ignored `.env` file. The account
   origin is distinct from the native Debug transit endpoint setting.

See [Apple web setup](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web),
[Google iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating),
and [Apple account deletion](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

## Server configuration

All settings are required when enabling authentication:

```dotenv
SFN_AUTH_ENABLED=true
SFN_AUTH_ORIGIN=https://juliet.nyc
SFN_ACCOUNT_ENCRYPTION_KEY=<base64 encoding of 32 random bytes>
SFN_APPLE_APP_ID=nyc.juliet.subwaysfornerds
SFN_APPLE_SERVICES_ID=<registered web Services ID>
SFN_APPLE_TEAM_ID=<team ID>
SFN_APPLE_KEY_ID=<key ID>
SFN_APPLE_PRIVATE_KEY=<PEM private key; literal backslash-n separators are accepted>
SFN_GOOGLE_IOS_CLIENT_ID=<iOS client ID>
SFN_GOOGLE_WEB_CLIENT_ID=<Web application client ID>
SFN_GOOGLE_CLIENT_SECRET=<Web application client secret>
```

`STATE_DIR` selects persistent storage; the default is `state`. Account data lives
in `accounts.sqlite`, separately from fleet history. Set `SFN_TRUST_PROXY` to the
actual trusted proxy IP or comma-separated CIDRs (for example `loopback` for a
same-host nginx deployment). Do not trust arbitrary forwarded headers. Docker
operators should configure their actual bridge/proxy source address. Without
this, authentication rate limits may group proxied visitors by proxy address.

Missing or invalid startup configuration disables authentication and logs a
configuration error; transit and file transfer remain available. `/auth/config`
returns only availability and public client IDs. Apply the nginx authentication
location in `deploy/nginx.conf` to prevent OAuth codes appearing in access logs.
The application logger also strips URL query strings. Do not enable request-body
or credential-header logging in a proxy or observability integration.

The web Google button uses the unmodified Google mark from the pinned GoogleSignIn-iOS
SDK (Apache 2.0; Google trademarks remain Google's).

Google's pinned Swift package and its transitive pins are in Xcode's shared
`Package.resolved`. Native core/startup tests remain independent of this SDK.
Provider verifiers are injected only by in-process tests; no production endpoint
or environment flag accepts mock identities.

## Sync, linking, and account lifecycle

The clients save locally first, debounce edits for one second, retry on
foreground/connection recovery, and poll every 30 seconds while active. The
server uses atomic revision comparisons (`If-Match`, HTTP 412 on stale writes).
Three-way comparison merges different settings and favorite membership changes.
Conflicting values require a choice. Edits made during an upload remain pending.

A new account starts with this device's settings. Joining an existing account
with different settings requires choosing the device or account version first.
Native-only fields survive web edits. Imports use the same sync pipeline, and the
preview explicitly warns when replacement settings will sync.

A provider subject, never its email, identifies a login. Link another provider
from an authenticated account; identities already owned by another account
cannot be moved or implicitly merged. Export/import can move settings between
separate accounts. Linking, unlinking, and account deletion require authentication
within ten minutes; use the verification buttons when prompted.

Sessions expire after 30 days and can be revoked server-side. Native sessions
use device-only Keychain storage; browser sessions use secure HttpOnly cookies
with CSRF protection. A short-lived, browser-bound cookie handles Apple's
cross-site form callback. Unlinking revokes all account sessions and requires
signing in again with the remaining method.

Deletion removes the active account, settings, and sessions immediately. Encrypted
provider-grant revocations remain in a durable queue until accepted or confirmed
already invalid. The worker runs on startup, deletion/unlink, and every minute.
Monitor configuration failures, queued-revocation warnings, account 5xx responses,
and repeated 412 conflicts without logging credentials or preference contents.

## Backups and rollout

Back up `accounts.sqlite` with SQLite's online backup facility (or stop the server
before copying it); copying only the main WAL-mode file while running is unsafe.
Keep the encryption key in a separate secret backup. Set an explicit backup
retention policy and ensure restored backups do not resurrect deleted accounts.
Before restoring, export the opaque user IDs and timestamps from
`account_deletions`, and reapply deletions made after the backup. Retain those
tombstones until every older backup has expired. They contain no email or settings.

To rotate the encryption key, stop account writes, back up the database and old
key, decrypt/re-encrypt every `grants.grant`, `revocations.grant`, and the
`account_meta` encryption-check value with an audited
maintenance procedure, and switch the environment key only after all rows have
been converted and verified. Do not simply replace the key: queued revocations
would become unreadable. The startup encryption check rejects a mismatched key. Rotate Apple signing keys and Google client secrets in
their consoles and server environment, then test login and revocation.

Ship the file-transfer UI first with authentication disabled. After enrollment,
provider registration, private configuration, and a signed native build, verify
Apple and Google sign-in on a real device and browser; link both methods, revoke
sessions, exercise deletion, and confirm two-device/offline sync. Enable the
configured deployment only after these checks. No live provider smoke test can
be completed using placeholder credentials.

## Verification

Run `npm run check`, `npm run test:native`, `bash scripts/test-native-startup.sh`,
`RUN_WEBKIT=1 npm run test:browser`, and `npm run test:ios`. Browser reports/traces
and native `.xcresult` bundles are retained by their test runners. The Debug-only
`SFN_TEST_SETTINGS_FILE` environment value accepts a base64 fixture and sends it
through the actual bounded file reader and import preview; Release ignores it.
