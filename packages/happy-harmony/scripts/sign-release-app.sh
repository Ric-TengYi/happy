#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_DIR="$ROOT_DIR/signing"
JAVA_HOME="${JAVA_HOME:-/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home}"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
JAVA_BIN="$JAVA_HOME/bin/java"
HVIGORW="${HVIGORW:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"
SIGN_TOOL="${SIGN_TOOL:-$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar}"

UNSIGNED_APP="$ROOT_DIR/build/outputs/default/happy-harmony-default-unsigned.app"
SIGNED_APP="$ROOT_DIR/build/outputs/default/happy-harmony-default-signed.app"
CERT_CHAIN_OUT="$ROOT_DIR/build/outputs/default/happy-harmony-default-signed-certchain.cer"
PROFILE_OUT="$ROOT_DIR/build/outputs/default/happy-harmony-default-signed-profile.p7b"

STORE_FILE="$SIGNING_DIR/release.p12"
STORE_PASS_FILE="$SIGNING_DIR/release-store.pass"
APP_CERT_FILE="$SIGNING_DIR/Happy.cer"
PROFILE_FILE="$SIGNING_DIR/Happy Release ProfileRelease.p7b"
KEY_ALIAS="${KEY_ALIAS:-happy-release}"
SIGN_ALG="${SIGN_ALG:-SHA256withECDSA}"

require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Missing required file: $file" >&2
    exit 1
  fi
}

require_file "$JAVA_BIN"
require_file "$HVIGORW"
require_file "$SIGN_TOOL"
require_file "$STORE_FILE"
require_file "$STORE_PASS_FILE"
require_file "$APP_CERT_FILE"
require_file "$PROFILE_FILE"

STORE_PASS="$(tr -d '\r\n' < "$STORE_PASS_FILE")"

cd "$ROOT_DIR"
JAVA_HOME="$JAVA_HOME" DEVECO_SDK_HOME="$DEVECO_SDK_HOME" "$HVIGORW" assembleApp --no-daemon

require_file "$UNSIGNED_APP"
rm -f "$SIGNED_APP" "$CERT_CHAIN_OUT" "$PROFILE_OUT"

"$JAVA_BIN" -jar "$SIGN_TOOL" sign-app \
  -mode localSign \
  -keyAlias "$KEY_ALIAS" \
  -keyPwd "$STORE_PASS" \
  -appCertFile "$APP_CERT_FILE" \
  -profileFile "$PROFILE_FILE" \
  -inFile "$UNSIGNED_APP" \
  -signAlg "$SIGN_ALG" \
  -keystoreFile "$STORE_FILE" \
  -keystorePwd "$STORE_PASS" \
  -outFile "$SIGNED_APP" \
  -inForm zip

"$JAVA_BIN" -jar "$SIGN_TOOL" verify-app \
  -inFile "$SIGNED_APP" \
  -outCertChain "$CERT_CHAIN_OUT" \
  -outProfile "$PROFILE_OUT" \
  -inForm zip

echo "Signed HarmonyOS app: $SIGNED_APP"
