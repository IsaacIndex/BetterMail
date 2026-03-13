# BetterMail Developer ID and DMG Release Guide

# TLDR

> [!important] Outcome
> This guide shows how to ship `BetterMail` as a signed, notarized macOS app in a `.dmg` so other people can install it without building in Xcode.
> It is specific to this repo: `BetterMail.xcodeproj`, the `BetterMail` app target, the `MailHelperExtension` target, and the signing config files under `Config/`.

# Scope

This document covers:

* Creating the correct Apple certificates for direct distribution
* Configuring this repo with real bundle IDs and team settings
* Archiving and exporting `BetterMail.app`
* Notarizing and stapling the exported app
* Building a distributable `.dmg`
* Verifying the final deliverables before sharing

This document does not cover:

* Mac App Store submission
* CI/CD automation
* Auto-update infrastructure such as Sparkle

# Repo-Specific Facts

These repo details affect release packaging:

* Project: `BetterMail.xcodeproj`
* Main app scheme: `BetterMail`
* Main app bundle ID source: `Config/AppSigning.xcconfig`
* Mail extension bundle ID source: `Config/ExtensionSigning.xcconfig`
* App entitlements:
  * `BetterMail/BetterMail.Debug.entitlements`
  * `BetterMail/BetterMail.Release.entitlements`
* Mail extension plist: `MailHelperExtension/Info.plist`

The project currently uses:

* `DEVELOPMENT_TEAM = "$(DEVELOPMENT_TEAM_ID)"`
* `PRODUCT_BUNDLE_IDENTIFIER = "$(BETTERMAIL_BUNDLE_ID)"` for the app
* `PRODUCT_BUNDLE_IDENTIFIER = "$(MAIL_EXTENSION_BUNDLE_ID)"` for the extension
* Automatic signing in the Xcode project

# Prerequisites

You need:

* An active Apple Developer membership
* A Mac with Xcode installed
* Access to this repo locally
* An Apple account permitted to create Developer ID certificates for your team

Recommended tools:

* Xcode 16 or newer
* Command Line Tools installed
* `xcodebuild`
* `notarytool`
* `stapler`
* `hdiutil`

Quick checks:

```bash
xcodebuild -version
xcrun notarytool --help >/dev/null
xcrun stapler --help >/dev/null
hdiutil help >/dev/null
```

# Certificates You Need

For direct download outside the Mac App Store, use **Developer ID** certificates.

You typically need:

* **Developer ID Application**
  Used to sign `BetterMail.app`
* **Developer ID Installer**
  Only needed if you decide to ship a `.pkg`

For a `.dmg` flow, the essential certificate is:

* **Developer ID Application**

If you only plan to distribute a signed `.app` inside a `.dmg`, you do not need `Developer ID Installer`.

# Step 1: Create the Developer ID Certificate

## Option A: Create in Xcode

1. Open Xcode.
2. Go to `Xcode > Settings > Accounts`.
3. Select your Apple ID.
4. Select the correct team.
5. Click `Manage Certificates`.
6. Add **Developer ID Application**.
7. If you want future `.pkg` distribution, also add **Developer ID Installer**.

## Option B: Create in the Apple Developer portal

Use this if your org prefers certificate creation in the portal:

1. Go to Apple Developer Certificates.
2. Create a **Developer ID Application** certificate.
3. Download and install it into Keychain Access.
4. Confirm the private key is present in the login keychain.

## Verify the certificate locally

```bash
security find-identity -v -p codesigning
```

You should see a `Developer ID Application: ...` identity in the output.

# Step 2: Configure This Repo for Your Team

Copy the signing templates:

```bash
cp Config/AppSigning.xcconfig.example Config/AppSigning.xcconfig
cp Config/ExtensionSigning.xcconfig.example Config/ExtensionSigning.xcconfig
```

Edit `Config/AppSigning.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM_ID = YOUR_TEAM_ID
BETTERMAIL_BUNDLE_ID = com.yourcompany.BetterMail
```

Edit `Config/ExtensionSigning.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM_ID = YOUR_TEAM_ID
MAIL_EXTENSION_BUNDLE_ID = com.yourcompany.BetterMail.MailHelperExtension
```

Repo-specific rules:

* The extension bundle ID should remain a child-style identifier of the app bundle ID
* The app and extension must use the same Apple Developer team
* Do not reuse the example bundle IDs from the repo templates

Recommended values for this repo:

* App bundle ID: `com.yourcompany.BetterMail`
* Extension bundle ID: `com.yourcompany.BetterMail.MailHelperExtension`

# Step 3: Confirm Signing in Xcode

Open `BetterMail.xcodeproj` and check:

1. The `BetterMail` target uses your team.
2. The `MailHelperExtension` target uses the same team.
3. Signing is valid for both Debug and Release.
4. No target is pointing at placeholder IDs from `Config/*.xcconfig.example`.

This repo already expects team and bundle values to come from the `Config/` xcconfig files, so keep that pattern.

# Step 4: Build Once and Resolve Signing Problems Early

Before archiving, run a normal release build:

```bash
xcrun simctl erase all
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build \
  > /tmp/xcodebuild.log 2>&1
tail -n 200 /tmp/xcodebuild.log
grep -n "error:" /tmp/xcodebuild.log || true
grep -n "BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

Then run a Release build:

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  build \
  > /tmp/xcodebuild-release.log 2>&1
tail -n 200 /tmp/xcodebuild-release.log
grep -n "error:" /tmp/xcodebuild-release.log || true
grep -n "BUILD FAILED" /tmp/xcodebuild-release.log || echo "BUILD SUCCEEDED"
```

Common failures at this step:

* Missing or invalid Developer ID certificate
* Bundle ID mismatch between app and extension
* Extension signing not inheriting the same team
* Capability or entitlement mismatch

# Step 5: Archive BetterMail

Create a clean archive folder:

```bash
mkdir -p build/release
```

Archive the app:

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -archivePath build/release/BetterMail.xcarchive \
  archive \
  > /tmp/xcodebuild-archive.log 2>&1
tail -n 200 /tmp/xcodebuild-archive.log
grep -n "error:" /tmp/xcodebuild-archive.log || true
grep -n "ARCHIVE FAILED" /tmp/xcodebuild-archive.log || echo "ARCHIVE SUCCEEDED"
```

Expected archive output:

* `build/release/BetterMail.xcarchive`

Inside it, the app should exist at:

* `build/release/BetterMail.xcarchive/Products/Applications/BetterMail.app`

# Step 6: Export the Archived App

Create an export options plist for direct distribution:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
```

Save it as `build/release/ExportOptions-DeveloperID.plist`.

Export:

```bash
xcodebuild -exportArchive \
  -archivePath build/release/BetterMail.xcarchive \
  -exportPath build/release/exported \
  -exportOptionsPlist build/release/ExportOptions-DeveloperID.plist \
  > /tmp/xcodebuild-export.log 2>&1
tail -n 200 /tmp/xcodebuild-export.log
grep -n "error:" /tmp/xcodebuild-export.log || true
grep -n "EXPORT FAILED" /tmp/xcodebuild-export.log || echo "EXPORT SUCCEEDED"
```

Expected exported app:

* `build/release/exported/BetterMail.app`

# Step 7: Verify the Exported App Signature

Run:

```bash
codesign --verify --deep --strict --verbose=2 build/release/exported/BetterMail.app
spctl -a -t exec -vv build/release/exported/BetterMail.app
```

What you want to see:

* `codesign` completes without errors
* `spctl` shows Developer ID assessment details instead of a rejection

If `codesign --deep` fails, inspect nested items:

```bash
find build/release/exported/BetterMail.app -type f | rg 'appex|dylib|framework|xpc'
```

For this repo, the first nested item to inspect is the Mail extension inside the app bundle.

# Step 8: Set Up Notarytool Credentials

You need notarization credentials before submitting the app to Apple.

Recommended approaches:

* App Store Connect API key
* Apple ID with app-specific password

## Option A: App Store Connect API key

If your team uses API keys, store credentials in a notary profile:

```bash
xcrun notarytool store-credentials "BetterMail-Notary" \
  --key /ABSOLUTE/PATH/TO/AuthKey_ABC1234567.p8 \
  --key-id ABC1234567 \
  --issuer 00000000-0000-0000-0000-000000000000
```

## Option B: Apple ID and app-specific password

```bash
xcrun notarytool store-credentials "BetterMail-Notary" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

Validate the saved profile:

```bash
xcrun notarytool history --keychain-profile "BetterMail-Notary"
```

# Step 9: Zip the App for Notarization

Apple notarization works cleanly with a zip of the exported `.app`.

```bash
ditto -c -k --keepParent \
  build/release/exported/BetterMail.app \
  build/release/BetterMail-notarize.zip
```

# Step 10: Submit for Notarization

Submit and wait:

```bash
xcrun notarytool submit \
  build/release/BetterMail-notarize.zip \
  --keychain-profile "BetterMail-Notary" \
  --wait \
  > /tmp/notarytool-submit.log 2>&1
cat /tmp/notarytool-submit.log
```

If notarization fails, inspect the log:

```bash
xcrun notarytool log <SUBMISSION_ID> \
  --keychain-profile "BetterMail-Notary"
```

Typical failure causes:

* Unsigned nested content
* Invalid entitlements
* Hardened runtime or signing issues
* Bundle metadata inconsistency between app and extension

# Step 11: Staple the Notarization Ticket

Staple the exported app:

```bash
xcrun stapler staple build/release/exported/BetterMail.app
```

Validate the stapled result:

```bash
xcrun stapler validate build/release/exported/BetterMail.app
spctl -a -t exec -vv build/release/exported/BetterMail.app
```

# Step 12: Create the DMG

Create a staging directory:

```bash
rm -rf build/release/dmg-root
mkdir -p build/release/dmg-root
cp -R build/release/exported/BetterMail.app build/release/dmg-root/
ln -s /Applications build/release/dmg-root/Applications
```

Build the DMG:

```bash
hdiutil create \
  -volname "BetterMail" \
  -srcfolder build/release/dmg-root \
  -ov \
  -format UDZO \
  build/release/BetterMail.dmg
```

Optional verification:

```bash
hdiutil verify build/release/BetterMail.dmg
```

# Step 13: Decide Whether to Notarize the DMG Too

Minimum acceptable flow:

* Notarize the `.app`
* Staple the `.app`
* Put the stapled `.app` into the `.dmg`

Stronger distribution flow:

* Also notarize the final `.dmg`

If you want the stronger flow:

```bash
xcrun notarytool submit \
  build/release/BetterMail.dmg \
  --keychain-profile "BetterMail-Notary" \
  --wait \
  > /tmp/notarytool-dmg.log 2>&1
cat /tmp/notarytool-dmg.log
xcrun stapler staple build/release/BetterMail.dmg
xcrun stapler validate build/release/BetterMail.dmg
```

# Step 14: Final Verification Before Sharing

Run these checks:

```bash
codesign --verify --deep --strict --verbose=2 build/release/exported/BetterMail.app
spctl -a -t exec -vv build/release/exported/BetterMail.app
xcrun stapler validate build/release/exported/BetterMail.app
hdiutil verify build/release/BetterMail.dmg
```

Manual checks on a second Mac are strongly recommended:

1. Download the DMG fresh.
2. Drag `BetterMail.app` to `/Applications`.
3. Launch the app.
4. Confirm macOS does not show an unidentified developer warning.
5. Confirm the app asks for Mail automation permission on first use.
6. Confirm the Mail extension appears in Apple Mail settings if that feature is expected to be enabled.

# Repo-Specific Release Notes

For this repo, expect these post-install behaviors:

* The app will ask for Automation access to `com.apple.mail`
* The app depends on Apple Mail being configured on the target Mac
* The Mail helper extension is packaged with the app, but the user still needs to enable it in Mail
* The app stores cached data under `~/Library/Application Support/BetterMail/Messages.sqlite`

That means packaging solves the Xcode requirement, but it does not remove:

* macOS privacy prompts
* Mail extension enablement by the user
* Apple Mail account setup on the destination machine

# Suggested Release Folder Layout

After a successful run, your repo-local release artifacts should look like:

```text
build/release/
  BetterMail.xcarchive
  BetterMail.dmg
  BetterMail-notarize.zip
  ExportOptions-DeveloperID.plist
  exported/
    BetterMail.app
```

# Copy-Paste Release Checklist

* Copy `Config/AppSigning.xcconfig.example` to `Config/AppSigning.xcconfig`
* Copy `Config/ExtensionSigning.xcconfig.example` to `Config/ExtensionSigning.xcconfig`
* Set real values for `DEVELOPMENT_TEAM_ID`
* Set real values for `BETTERMAIL_BUNDLE_ID`
* Set real values for `MAIL_EXTENSION_BUNDLE_ID`
* Confirm `Developer ID Application` exists in Keychain
* Build Debug and Release successfully
* Archive `BetterMail`
* Export with `method = developer-id`
* Verify signature on `BetterMail.app`
* Notarize the exported app
* Staple the app
* Build the DMG
* Optionally notarize and staple the DMG
* Verify on a second Mac before sharing

# Notes

> [!note] Practical recommendation
> For this repo, the safest first release path is:
> sign `BetterMail.app` with Developer ID, notarize the app, staple it, package it in a `.dmg`, then test the DMG on a different Mac with Apple Mail configured.

> [!warning] Common misunderstanding
> Creating the `.dmg` is not the hard part. The sensitive parts are correct Developer ID signing, notarization, and ensuring the nested Mail extension is signed consistently with the host app.
