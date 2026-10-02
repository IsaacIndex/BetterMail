#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BetterMail"
BUNDLE_ID="isaacwongnh.BetterMail"
EXTENSION_BUNDLE_ID="isaacwongnh.BetterMail.MailHelperExtension"
SIGNING_IDENTITY_SHA1="59D9099E689B4FCF247C0E2C021C3B62E80AE4B2"
DEVELOPMENT_TEAM_ID="TN3L2WBKR5"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SIGNING_CONFIG="$ROOT_DIR/Config/AppSigning.xcconfig"
EXTENSION_SIGNING_CONFIG="$ROOT_DIR/Config/ExtensionSigning.xcconfig"
DERIVED_DATA_PATH="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
EXTENSION_BUNDLE="$APP_BUNDLE/Contents/PlugIns/MailHelperExtension.appex"
INSTALLED_APP_BUNDLE="/Users/isaacibm/Applications/$APP_NAME.app"
BUILD_LOG="/tmp/xcodebuild.log"

read_xcconfig_value() {
  local config_path="$1"
  local key="$2"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$config_path" | tail -n 1
}

require_local_signing_value() {
  local config_path="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(read_xcconfig_value "$config_path" "$key")"
  if [[ "$actual" != "$expected" ]]; then
    echo "$config_path must set $key to $expected for local validation." >&2
    exit 1
  fi
}

for local_config in "$APP_SIGNING_CONFIG" "$EXTENSION_SIGNING_CONFIG"; do
  if [[ ! -f "$local_config" ]]; then
    echo "Missing ignored local signing config: $local_config" >&2
    exit 1
  fi
done
if ! git -C "$ROOT_DIR" check-ignore -q Config/AppSigning.xcconfig \
  || ! git -C "$ROOT_DIR" check-ignore -q Config/ExtensionSigning.xcconfig; then
  echo "Local signing overrides must remain ignored by git." >&2
  exit 1
fi
require_local_signing_value "$APP_SIGNING_CONFIG" DEVELOPMENT_TEAM_ID "$DEVELOPMENT_TEAM_ID"
require_local_signing_value "$APP_SIGNING_CONFIG" BETTERMAIL_BUNDLE_ID "$BUNDLE_ID"
require_local_signing_value "$APP_SIGNING_CONFIG" BETTERMAIL_SIGNING_IDENTITY_SHA1 "$SIGNING_IDENTITY_SHA1"
require_local_signing_value "$EXTENSION_SIGNING_CONFIG" DEVELOPMENT_TEAM_ID "$DEVELOPMENT_TEAM_ID"
require_local_signing_value "$EXTENSION_SIGNING_CONFIG" MAIL_EXTENSION_BUNDLE_ID "$EXTENSION_BUNDLE_ID"
require_local_signing_value "$EXTENSION_SIGNING_CONFIG" BETTERMAIL_SIGNING_IDENTITY_SHA1 "$SIGNING_IDENTITY_SHA1"

REPOSITORY_SIGNING_FILES=(
  "$ROOT_DIR/BetterMail.xcodeproj/project.pbxproj"
  "$ROOT_DIR/BetterMail/BetterMail.entitlements"
  "$ROOT_DIR/BetterMail/BetterMail.Debug.entitlements"
  "$ROOT_DIR/BetterMail/BetterMail.Release.entitlements"
  "$ROOT_DIR/Config/AppSigning.xcconfig.example"
  "$ROOT_DIR/Config/ExtensionSigning.xcconfig.example"
)

repository_signing_snapshot() {
  shasum -a 256 "${REPOSITORY_SIGNING_FILES[@]}"
}

INITIAL_REPOSITORY_SIGNING_SNAPSHOT="$(repository_signing_snapshot)"

verify_repository_signing_files_unchanged() {
  if [[ "$(repository_signing_snapshot)" != "$INITIAL_REPOSITORY_SIGNING_SNAPSHOT" ]]; then
    echo "Repository signing or entitlement files changed during local validation." >&2
    return 1
  fi
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY_SHA1" >/dev/null; then
  echo "Required Apple Development identity $SIGNING_IDENTITY_SHA1 is unavailable." >&2
  exit 1
fi

xcodebuild \
  -project "$ROOT_DIR/BetterMail.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -sdk macosx \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY_SHA1" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER= \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG BETTERMAIL_DISABLE_PREVIEWS' \
  clean build \
  > "$BUILD_LOG" 2>&1

verify_repository_signing_files_unchanged

validate_signed_bundle() {
  local bundle_path="$1"
  local expected_bundle_id="$2"
  local signature_details
  local actual_bundle_id
  local certificate_root
  local certificate_prefix
  local leaf_fingerprint
  local actual_leaf_sha1

  if ! codesign --verify --deep --strict --verbose=4 "$bundle_path"; then
    echo "$bundle_path failed deep strict signature verification." >&2
    return 1
  fi
  if ! signature_details="$(codesign -dvvv "$bundle_path" 2>&1)"; then
    echo "$bundle_path signature details are unreadable." >&2
    return 1
  fi
  if [[ "$signature_details" == *"Signature=adhoc"* ]]; then
    echo "$bundle_path is ad-hoc signed." >&2
    return 1
  fi
  if [[ "$signature_details" != *"TeamIdentifier=$DEVELOPMENT_TEAM_ID"* ]]; then
    echo "$bundle_path does not report TeamIdentifier=$DEVELOPMENT_TEAM_ID." >&2
    return 1
  fi
  if ! actual_bundle_id="$(plutil -extract CFBundleIdentifier raw "$bundle_path/Contents/Info.plist")"; then
    echo "$bundle_path bundle identifier is unreadable." >&2
    return 1
  fi
  if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
    echo "$bundle_path changed bundle ID to $actual_bundle_id." >&2
    return 1
  fi

  certificate_root="$(mktemp -d /tmp/bettermail-signature.XXXXXX)"
  certificate_prefix="$certificate_root/codesign"
  if ! codesign -d --extract-certificates="$certificate_prefix" "$bundle_path" >/dev/null 2>&1; then
    rm -rf "$certificate_root"
    echo "$bundle_path signing certificate chain could not be extracted." >&2
    return 1
  fi
  if [[ ! -f "${certificate_prefix}1" ]] \
    || ! security verify-cert \
      -c "${certificate_prefix}0" \
      -c "${certificate_prefix}1" \
      -p codeSign \
      -N \
      -L \
      >/dev/null; then
    rm -rf "$certificate_root"
    echo "$bundle_path signing certificate chain is not trusted for code signing." >&2
    return 1
  fi
  if ! leaf_fingerprint="$(openssl x509 -inform DER -in "${certificate_prefix}0" -noout -fingerprint -sha1)"; then
    rm -rf "$certificate_root"
    echo "$bundle_path leaf signing certificate fingerprint is unreadable." >&2
    return 1
  fi
  actual_leaf_sha1="$(printf '%s' "${leaf_fingerprint#*=}" | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')"
  rm -rf "$certificate_root"
  if [[ "$actual_leaf_sha1" != "$SIGNING_IDENTITY_SHA1" ]]; then
    echo "$bundle_path was signed by unexpected certificate $actual_leaf_sha1." >&2
    return 1
  fi
}

compare_signed_entitlements() {
  local expected_bundle="$1"
  local actual_bundle="$2"
  local label="$3"
  local comparison_root
  comparison_root="$(mktemp -d /tmp/bettermail-entitlements.XXXXXX)"
  (
    trap 'rm -rf "$comparison_root"' EXIT
    if ! codesign -d --entitlements :- "$expected_bundle" \
        > "$comparison_root/expected.plist" 2>/dev/null \
      || ! codesign -d --entitlements :- "$actual_bundle" \
        > "$comparison_root/actual.plist" 2>/dev/null; then
      echo "$label entitlements could not be extracted." >&2
      exit 1
    fi
    plutil -convert binary1 "$comparison_root/expected.plist"
    plutil -convert binary1 "$comparison_root/actual.plist"
    if ! cmp -s "$comparison_root/expected.plist" "$comparison_root/actual.plist"; then
      echo "$label entitlements differ from the clean build product." >&2
      exit 1
    fi
  )
}

launch_and_verify_process() {
  local bundle_path="$1"
  local expected_executable="$bundle_path/Contents/MacOS/$APP_NAME"
  local consecutive_matches=0
  local process_id
  local process_command

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$bundle_path"
  for _ in {1..20}; do
    while IFS= read -r process_id; do
      [[ -n "$process_id" ]] || continue
      process_command="$(ps -p "$process_id" -o command= 2>/dev/null || true)"
      if [[ "$process_command" == "$expected_executable"* ]]; then
        consecutive_matches=$((consecutive_matches + 1))
        if (( consecutive_matches >= 2 )); then
          return 0
        fi
        break
      fi
    done < <(pgrep -x "$APP_NAME" || true)
    sleep 0.5
  done
  echo "$APP_NAME did not remain alive from $bundle_path. Build log: $BUILD_LOG" >&2
  return 1
}

validate_signed_bundle "$EXTENSION_BUNDLE" "$EXTENSION_BUNDLE_ID"
validate_signed_bundle "$APP_BUNDLE" "$BUNDLE_ID"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    launch_and_verify_process "$APP_BUNDLE"
    ;;
  --install|install)
    shopt -s nullglob
    stale_previous_bundles=(/Users/isaacibm/Applications/.$APP_NAME.previous.*.app)
    shopt -u nullglob
    if (( ${#stale_previous_bundles[@]} > 0 )); then
      echo "A prior BetterMail installation backup still exists; refusing to overwrite it: ${stale_previous_bundles[0]}" >&2
      exit 1
    fi

    install_stage_root="$(mktemp -d /tmp/bettermail-install.XXXXXX)"
    staged_app_bundle="$install_stage_root/$APP_NAME.app"
    previous_app_bundle="/Users/isaacibm/Applications/.$APP_NAME.previous.$$.app"
    failed_app_bundle="$install_stage_root/$APP_NAME.failed.app"
    had_previous_bundle=false
    new_bundle_installed=false
    install_committed=false

    rollback_install() {
      local exit_status=$?
      trap - EXIT INT TERM HUP
      if [[ "$install_committed" != true ]]; then
        set +e
        pkill -x "$APP_NAME" >/dev/null 2>&1
        if [[ "$new_bundle_installed" == true && -e "$INSTALLED_APP_BUNDLE" ]]; then
          if ! mv "$INSTALLED_APP_BUNDLE" "$failed_app_bundle"; then
            echo "Could not move the failed installed bundle; prior bundle remains at $previous_app_bundle for manual recovery." >&2
            exit "$exit_status"
          fi
        fi
        if [[ "$had_previous_bundle" == true && -e "$previous_app_bundle" ]]; then
          if mv "$previous_app_bundle" "$INSTALLED_APP_BUNDLE"; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
              -f "$INSTALLED_APP_BUNDLE" >/dev/null 2>&1
            mdimport "$INSTALLED_APP_BUNDLE" >/dev/null 2>&1
            echo "Installation did not commit; the prior BetterMail bundle was restored." >&2
          else
            echo "Automatic restore failed; the prior bundle remains at $previous_app_bundle." >&2
          fi
        fi
        echo "Failed installation evidence remains at $install_stage_root." >&2
      fi
      exit "$exit_status"
    }
    trap rollback_install EXIT
    trap 'exit 130' INT TERM HUP

    ditto "$APP_BUNDLE" "$staged_app_bundle"
    validate_signed_bundle \
      "$staged_app_bundle/Contents/PlugIns/MailHelperExtension.appex" \
      "$EXTENSION_BUNDLE_ID"
    validate_signed_bundle "$staged_app_bundle" "$BUNDLE_ID"
    compare_signed_entitlements "$APP_BUNDLE" "$staged_app_bundle" "Staged app"
    compare_signed_entitlements "$EXTENSION_BUNDLE" \
      "$staged_app_bundle/Contents/PlugIns/MailHelperExtension.appex" \
      "Staged extension"
    verify_repository_signing_files_unchanged

    if [[ -e "$INSTALLED_APP_BUNDLE" ]]; then
      had_previous_bundle=true
      mv "$INSTALLED_APP_BUNDLE" "$previous_app_bundle"
    fi
    new_bundle_installed=true
    mv "$staged_app_bundle" "$INSTALLED_APP_BUNDLE"
    validate_signed_bundle \
      "$INSTALLED_APP_BUNDLE/Contents/PlugIns/MailHelperExtension.appex" \
      "$EXTENSION_BUNDLE_ID"
    validate_signed_bundle "$INSTALLED_APP_BUNDLE" "$BUNDLE_ID"
    compare_signed_entitlements "$APP_BUNDLE" "$INSTALLED_APP_BUNDLE" "Installed app"
    compare_signed_entitlements "$EXTENSION_BUNDLE" \
      "$INSTALLED_APP_BUNDLE/Contents/PlugIns/MailHelperExtension.appex" \
      "Installed extension"
    verify_repository_signing_files_unchanged
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "$INSTALLED_APP_BUNDLE"
    mdimport "$INSTALLED_APP_BUNDLE"
    launch_and_verify_process "$INSTALLED_APP_BUNDLE"
    install_committed=true
    trap - EXIT INT TERM HUP
    if [[ "$had_previous_bundle" == true ]]; then
      rm -rf "$previous_app_bundle"
    fi
    rm -rf "$install_stage_root"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install]" >&2
    exit 2
    ;;
esac
