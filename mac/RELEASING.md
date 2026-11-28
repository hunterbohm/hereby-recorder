# Releasing the signed app

`mac/scripts/release.sh` turns a release tag into a signed, notarized app that people download, and that installed
copies update to from the panel. A source build (`build-app.sh`) needs none of this.

## How the pieces fit

- **Developer ID certificate.** Signs the app so macOS knows who made it. macOS keys the microphone, system audio and
  Screen Recording grants to the app's bundle id (`sh.hereby.recorder`) and its signer's team, so every release keeps
  the same bundle id and the same team, and the grants survive updates.
- **Notarization.** Apple scans the signed app and issues a ticket, which `stapler` attaches to the app, so Gatekeeper
  opens it without a warning, even offline.
- **Update key.** An Ed25519 key, separate from the certificate. Each release zip is signed with it, and the app carries
  the public half. The app installs an update only if the zip's signature matches that key, the app inside is
  `sh.hereby.recorder` at the version the feed names, its code signature is Apple-issued for the same team, and
  Gatekeeper accepts it. A stolen GitHub login alone cannot ship an update; it needs this key and the certificate.
- **Feed.** `appcast.json`, a release asset next to the zip. Installed apps read
  `https://github.com/<HEREBY_UPDATE_REPO>/releases/latest/download/appcast.json` about once a day.

Why not Sparkle: the recorder runs as a launchd agent with KeepAlive, and an update must never cut off a recording.
Sparkle relaunches the app through LaunchServices, which would start a second copy beside launchd's, and it knows
nothing about calls. The app already had a panel row and a one-shot launchd job for updates, so the signed path reuses
them: it downloads and checks the release, then `install-app.sh` (shipped inside that release) refuses during a call,
stops the recorder through launchd, swaps the bundle, and restarts it. The signature scheme is Sparkle's (Ed25519 over
the archive, base64), so moving to Sparkle later keeps the key. Sparkle would also need its framework and XPC helpers
embedded and re-signed in a bundle that SwiftPM, not Xcode, builds.

## One-time setup

1. **Certificate.** The account holder makes a "Developer ID Application" certificate (developer.apple.com, Certificates,
   or Xcode, Settings, Accounts, Manage Certificates) and installs it in the login keychain of the Mac that releases.
   Check it: `security find-identity -v -p codesigning` lists
   `"Developer ID Application: <company> (<TEAM ID>)"`.
2. **Notarization login**, one of:
   - an App Store Connect API key (Users and Access, Integrations, Team Keys, role Developer): keep its `.p8` text,
     key id and issuer id in Infisical; or
   - a keychain profile on the releasing Mac: `xcrun notarytool store-credentials hereby-notary --apple-id <id>
     --team-id <TEAM ID>` with an app-specific password, then set `HEREBY_NOTARY_PROFILE=hereby-notary`.
3. **Update key.** From `mac/`: `swift build -c release --product lml-release`, then
   `.build/release/lml-release keygen /tmp/hereby-update.key`. It prints the public key. Store the file's contents in
   Infisical as `HEREBY_UPDATE_KEY`, then delete the file. Losing this key means installed apps can never update again
   on their own (they would need a manual download), so keep a second copy in the password manager.
4. **Infisical secrets** (names `release.sh` reads):

   | Name | Value |
   | --- | --- |
   | `HEREBY_SIGN_IDENTITY` | the certificate's full name from step 1 |
   | `HEREBY_TEAM_ID` | the ten-character team id |
   | `HEREBY_UPDATE_KEY` | the update key from step 3 |
   | `HEREBY_UPDATE_REPO` | `owner/name` of the public repo apps download from |
   | `HEREBY_NOTARY_KEY`, `HEREBY_NOTARY_KEY_ID`, `HEREBY_NOTARY_ISSUER` | the API key's `.p8` text, key id, issuer id |
   | or `HEREBY_NOTARY_PROFILE` | the keychain profile name, instead of the three above |
   | `HEREBY_RELEASE_REPO` (optional) | where to upload first; defaults to this clone's GitHub repo |

## Each release

1. Tag the commit `vX.Y.Z` as usual, with a clean clone on that tag.
2. `infisical run -- mac/scripts/release.sh` builds, signs (hardened runtime, `LiveMeetingListener.entitlements`),
   notarizes, staples, zips, writes `appcast.json`, checks the zip against the feed, and uploads both to that tag's
   release on this repo. `--no-upload` stops after writing them to `mac/.build/release-out/<tag>`.
3. Installed apps only see a release on the public repo, because a private repo's downloads need a login. After the
   scanned public snapshot of the tag is pushed to the public repo and tagged there, run
   `infisical run -- mac/scripts/release.sh --public`. It uploads the same two files to the public release, marks it
   latest, and from then on installed apps offer it within a day.

## The first signed install on a Mac that ran a source build

A source build is signed by a local certificate, so its grants belong to that signer. The first signed release is a new
signer: macOS asks once more for the microphone, system audio and Screen Recording. Install it by hand at the Mac,
when no meeting is due: quit the recorder (`launchctl bootout gui/$(id -u)/sh.hereby.recorder`), replace
`~/Applications/LiveMeetingListener.app` with the downloaded one, start it again
(`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/sh.hereby.recorder.plist`), and allow the permissions.
Later signed updates keep them.
