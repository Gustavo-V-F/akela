#!/usr/bin/env bash
# Windows certificate custody tests (WI-2026-11-22-001): the current user's certificate store
# (software KSP, key not exportable) and a PKCS#11 token. Runs in Git Bash on a GitHub Actions
# Windows runner.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
choco install -y --no-progress softhsm >/dev/null
work=$(mktemp -d)
fx=$work/fixtures
"$here/make-fixtures.sh" "$fx"

# How the agent installs an A1: CNG software KSP, private key marked non-exportable.
for n in issuer removal; do
    MSYS_NO_PATHCONV=1 certutil -f -user -p test -csp "Microsoft Software Key Storage Provider" \
        -importpfx My "$(cygpath -w "$fx/$n.p12")" NoExport >/dev/null
done

mkdir "$work/tokens"
printf 'directories.tokendir = %s\nobjectstore.backend = file\n' "$(cygpath -m "$work/tokens")" >"$work/softhsm2.conf"
export SOFTHSM2_CONF=$(cygpath -w "$work/softhsm2.conf")
export PATH="/c/SoftHSM2/bin:$PATH"
module='C:\SoftHSM2\lib\softhsm2-x64.dll'
"$here/provision-pkcs11.sh" "$fx" "$module"

CUSTODY_FIXTURES=$(cygpath -w "$fx") \
CUSTODY_PKCS11_MODULE=$module CUSTODY_PKCS11_TOKEN=akela-test CUSTODY_PKCS11_PIN=1234 \
    cargo test --manifest-path "$here/Cargo.toml" --test cng --test pkcs11 --test harness
