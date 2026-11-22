#!/usr/bin/env bash
# macOS certificate custody tests (WI-2026-11-22-001): a keychain with non-extractable keys and
# a PKCS#11 token. Runs on a GitHub Actions macOS runner.
set -euo pipefail
# GitHub shows annotations publicly; job logs need a token.
[ -z "${GITHUB_ACTIONS:-}" ] || trap 'rc=$?; echo "::error file=ci/cert-custody/${0##*/},line=$LINENO::exit $rc from: $BASH_COMMAND"' ERR
here=$(cd "$(dirname "$0")" && pwd)
HOMEBREW_NO_AUTO_UPDATE=1 brew install -q softhsm openssl@3 >/dev/null
export PATH="$(brew --prefix openssl@3)/bin:$PATH"
work=$(mktemp -d)
# Runs the tests; on GitHub, failing assertions also become annotations.
annotate_tests() {
    "$@" 2>&1 | tee "$work/test.log" && return 0
    [ -z "${GITHUB_ACTIONS:-}" ] || grep -E "panicked|FAILED|Error|error" "$work/test.log" | head -20 | sed 's/^/::error::/'
    return 1
}

fx=$work/fixtures
"$here/make-fixtures.sh" "$fx"

kc=$work/custody.keychain-db
pw=test
security create-keychain -p "$pw" "$kc"
security set-keychain-settings "$kc" # no auto-lock during the run
security unlock-keychain -p "$pw" "$kc"
# -x: private keys non-extractable; -A plus the partition list: no access prompt on a headless runner.
for n in issuer removal; do security import "$fx/$n.p12" -k "$kc" -P test -x -A >/dev/null; done
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k "$pw" "$kc" >/dev/null

mkdir "$work/tokens"
printf 'directories.tokendir = %s\nobjectstore.backend = file\n' "$work/tokens" >"$work/softhsm2.conf"
export SOFTHSM2_CONF=$work/softhsm2.conf
module="$(brew --prefix softhsm)/lib/softhsm/libsofthsm2.so"
"$here/provision-pkcs11.sh" "$fx" "$module"

CUSTODY_FIXTURES=$fx CUSTODY_KEYCHAIN=$kc CUSTODY_KEYCHAIN_PASSWORD=$pw \
CUSTODY_PKCS11_MODULE=$module CUSTODY_PKCS11_TOKEN=akela-test CUSTODY_PKCS11_PIN=1234 \
    annotate_tests cargo test --manifest-path "$here/Cargo.toml" --test keychain --test pkcs11 --test harness
