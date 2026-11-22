#!/usr/bin/env bash
# Creates the SoftHSM2 token "akela-test" (user PIN 1234) holding the issuer key, imported as
# sensitive and non-extractable, and its certificate, both labelled "issuer".
# Usage: provision-pkcs11.sh FIXTURES MODULE   (SOFTHSM2_CONF must name a config with a tokendir)
set -euo pipefail
fx=$1 module=$2
softhsm2-util --init-token --free --label akela-test --pin 1234 --so-pin 5678 >/dev/null
softhsm2-util --import "$fx/issuer.key.pem" --token akela-test --label issuer --id 01 --pin 1234 >/dev/null
cargo run -q --manifest-path "$(dirname "$0")/Cargo.toml" --bin p11-put-cert -- \
    "$module" akela-test 1234 issuer "$fx/issuer.crt.der"
