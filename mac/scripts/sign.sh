#!/bin/bash
# Usage: sign.sh PATH IDENTIFIER
# Signs an app bundle or a bare binary with the local signing certificate.
set -euo pipefail
umask 077
target="$1"
identifier="$2"
signing_dir="${LML_SIGNING_DIR:-$HOME/.config/live-meeting/signing}"
identity_name="LiveMeetingListener Local Signing"

# TCC keys the microphone, system audio, and Full Disk Access grants to the designated requirement.
# An ad hoc signature's requirement is its cdhash, which changes on every build; a fixed certificate's is not.
if [[ ! -f "$signing_dir/identity.p12" ]]; then
    mkdir -p "$signing_dir"; chmod 700 "$signing_dir"
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    printf '%s' "$(openssl rand -hex 24)" > "$scratch/pass"
    cat > "$scratch/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$identity_name
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$scratch/cert.cnf" -keyout "$scratch/key.pem" -out "$scratch/cert.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$scratch/key.pem" -in "$scratch/cert.pem" -name "$identity_name" -passout "file:$scratch/pass" -out "$scratch/identity.p12"
    mv "$scratch/pass" "$signing_dir/identity.pass"
    mv "$scratch/identity.p12" "$signing_dir/identity.p12"
    rm -rf "$scratch"; trap - EXIT
fi

searchlist=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [[ -n "$line" ]] && searchlist+=("$line")
done < <(security list-keychains -d user)
if [[ ${#searchlist[@]} -eq 0 ]]; then
    printf 'Could not read the keychain search list.\n' >&2
    exit 1
fi
keychain_dir="$(mktemp -d)"
keychain="$keychain_dir/lml-signing.keychain-db"
keychain_pass="$(openssl rand -hex 16)"
cleanup() {
    security delete-keychain "$keychain" 2>/dev/null || true
    security list-keychains -d user -s "${searchlist[@]}"
    rm -rf "$keychain_dir"
}
trap cleanup EXIT
security create-keychain -p "$keychain_pass" "$keychain"
security list-keychains -d user -s "${searchlist[@]}" "$keychain"
security unlock-keychain -p "$keychain_pass" "$keychain"
security set-keychain-settings "$keychain"
security import "$signing_dir/identity.p12" -k "$keychain" -P "$(cat "$signing_dir/identity.pass")" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_pass" "$keychain" >/dev/null
identity="$(security find-identity -p codesigning "$keychain" | awk -v name="\"$identity_name\"" 'index($0, name) { print $2; exit }')"
codesign --force --keychain "$keychain" --sign "$identity" --identifier "$identifier" "$target"
