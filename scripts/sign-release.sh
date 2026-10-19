#!/bin/bash
#
# Sign a release's SHA256SUMS with the Boson release key, then check the
# signature the way a consumer checks it.
#
#   scripts/sign-release.sh <SHA256SUMS> <release-key-fingerprint> <key-file>
#
# The same procedure as super-node-deployment/scripts/dev/make-release.sh --sign:
#
#   - gpg signs with exactly the PRIMARY key ("<fingerprint>!"), never a signing
#     subkey gpg might prefer. This key signs the Maven artifacts too, and Maven
#     Central verifies only primary-key signatures, so it has one signing key.
#   - gpgv then verifies against a keyring holding only the key COMMITTED at
#     <key-file> (read from HEAD, not the working tree), so a signature by the
#     wrong key is caught here rather than by whoever checks the release.
#
# The private key never leaves your keyring; gpg may ask for its passphrase.
# On any failure the .asc is removed, so nothing unverified is left to upload.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $(basename "$0") <SHA256SUMS> <release-key-fingerprint> <key-file>" >&2
    exit 2
fi

sums=$1
key=$2
keyfile=$3
asc="$sums.asc"

rm -f "$asc"

check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT

# Before signing, so a missing key fails without asking for a passphrase.
if ! git show "HEAD:$keyfile" > "$check/release.asc" 2>/dev/null; then
    echo "Refusing: $keyfile is not committed. The signature is checked against" >&2
    echo "the committed key; commit it first." >&2
    exit 1
fi
gpg --dearmor < "$check/release.asc" > "$check/release.gpg"

gpg --local-user "$key!" --armor --detach-sign --output "$asc" "$sums"

status=$(GNUPGHOME="$check" LC_ALL=C gpgv --status-fd 1 --keyring "$check/release.gpg" \
         "$asc" "$sums" 2>/dev/null) || status=
# Both fingerprints in VALIDSIG - the signing key and its primary - and GOODSIG,
# which gpgv replaces with REVKEYSIG while still exiting 0.
signers=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print $3, $NF }')
if ! printf '%s\n' "$status" | grep -q '^\[GNUPG:\] GOODSIG ' \
        || [ "$signers" != "$key $key" ]; then
    rm -f "$asc"
    echo "Refusing: the signature does not verify against the committed release key" >&2
    echo "$key. Removed $(basename "$asc"); nothing is fit to upload." >&2
    exit 1
fi

echo "Signed and verified: $(basename "$asc") by $key"
