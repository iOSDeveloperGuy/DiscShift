#!/bin/bash
# Runs only on a disposable GitHub-hosted Mac, after tests have passed.
set -euo pipefail
: "${RUNNER_TEMP:?GitHub runner required}"
: "${GITHUB_ENV:?GitHub runner required}"
KEYCHAIN="$RUNNER_TEMP/discshift-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
umask 077
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP'])
(root / 'discshift-signing.p12').write_bytes(base64.b64decode(os.environ['DEVELOPER_ID_P12_BASE64'], validate=True))
(root / 'discshift-notary.p8').write_text(os.environ['APPLE_API_KEY_P8'])
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$RUNNER_TEMP/discshift-signing.p12" -P "$DEVELOPER_ID_P12_PASSWORD" -t cert -f pkcs12 -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Application:.*(UJ27S8B847)\)"/\1/p')"
[[ -n "$IDENTITY" && "$(printf '%s\n' "$IDENTITY" | wc -l | tr -d ' ')" == 1 ]] || { printf 'Expected one Developer ID identity for the release team.\n' >&2; exit 1; }
{
    printf 'DISCSHIFT_SIGNING_IDENTITY=%s\n' "$IDENTITY"
    printf 'DISCSHIFT_NOTARY_KEY_PATH=%s/discshift-notary.p8\n' "$RUNNER_TEMP"
} >> "$GITHUB_ENV"
rm -f "$RUNNER_TEMP/discshift-signing.p12"
