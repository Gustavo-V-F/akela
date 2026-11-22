#!/usr/bin/env bash
# Linux certificate custody tests (WI-2026-11-22-001): the agent's file store and a PKCS#11
# token. Runs as root in a Debian Rust image (OneDev job "cert-custody-linux").
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq softhsm2 >/dev/null
work=$(mktemp -d)
chmod 755 "$work"
fx=$work/fixtures
"$here/make-fixtures.sh" "$fx"

id akela-agent >/dev/null 2>&1 || useradd --system akela-agent
id other >/dev/null 2>&1 || useradd other
store=$work/agent-store
install -d -o akela-agent -m 700 "$store"
for n in issuer removal; do install -o akela-agent -m 600 "$fx/$n.p12" "$store/"; done

mkdir "$work/tokens"
printf 'directories.tokendir = %s\nobjectstore.backend = file\n' "$work/tokens" >"$work/softhsm2.conf"
export SOFTHSM2_CONF=$work/softhsm2.conf
module=$(dpkg -L softhsm2-common libsofthsm2 2>/dev/null | grep -m1 '/libsofthsm2\.so$')
"$here/provision-pkcs11.sh" "$fx" "$module"

CUSTODY_FIXTURES=$fx CUSTODY_FILE_STORE=$store CUSTODY_FILE_OWNER=akela-agent CUSTODY_OTHER_USER=other \
CUSTODY_PKCS11_MODULE=$module CUSTODY_PKCS11_TOKEN=akela-test CUSTODY_PKCS11_PIN=1234 \
    cargo test --manifest-path "$here/Cargo.toml" --test file_store --test pkcs11 --test harness
