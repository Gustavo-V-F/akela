#!/usr/bin/env bash
# Creates the SoftHSM2 token "akela-test" (user PIN 1234) holding the issuer key, imported as
# sensitive and non-extractable, and its certificate, both labelled "issuer".
# Usage: provision-pkcs11.sh FIXTURES MODULE   (SOFTHSM2_CONF must name a config with a tokendir)
set -euo pipefail
# GitHub shows annotations publicly; job logs need a token.
[ -z "${GITHUB_ACTIONS:-}" ] || trap 'rc=$?; echo "::error file=ci/cert-custody/${0##*/},line=$LINENO::exit $rc from: $BASH_COMMAND"' ERR
fx=$1 module=$2
# Runs a tool quietly; on failure its output goes to stderr and, on GitHub, into an annotation.
run() {
    local out
    out=$("$@" 2>&1) && return 0
    echo "$out" >&2
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error::$1: $(echo "$out" | tr '\n' ' ')"
    return 1
}
run softhsm2-util --init-token --free --label akela-test --pin 1234 --so-pin 5678
run softhsm2-util --import "$fx/issuer.key.pem" --token akela-test --label issuer --id 01 --pin 1234
cargo run -q --manifest-path "$(dirname "$0")/Cargo.toml" --bin p11-put-cert -- \
    "$module" akela-test 1234 issuer "$fx/issuer.crt.der"
