#!/usr/bin/env bash
# Windows certificate custody tests (WI-2026-11-22-001): the current user's certificate store
# (software KSP, key not exportable) and a PKCS#11 token. Runs in Git Bash on a GitHub Actions
# Windows runner.
set -euo pipefail
# GitHub shows annotations publicly; job logs need a token.
[ -z "${GITHUB_ACTIONS:-}" ] || trap 'rc=$?; echo "::error file=ci/cert-custody/${0##*/},line=$LINENO::exit $rc from: $BASH_COMMAND"' ERR
here=$(cd "$(dirname "$0")" && pwd)
choco install -y --no-progress softhsm >/dev/null
work=$(mktemp -d)
# Runs the tests; on GitHub, failing assertions also become annotations.
annotate_tests() {
    "$@" 2>&1 | tee "$work/test.log" && return 0
    [ -z "${GITHUB_ACTIONS:-}" ] || grep -E "panicked|FAILED|Error|error" "$work/test.log" | head -20 | sed 's/^/::error::/'
    return 1
}

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
# The Chocolatey package's layout is not documented; find the tool and the 64-bit module.
util=$(find /c/SoftHSM2 "/c/Program Files/SoftHSM2" -iname softhsm2-util.exe 2>/dev/null | head -1 || true)
dll=$(find /c/SoftHSM2 "/c/Program Files/SoftHSM2" -iname 'softhsm2-x64.dll' 2>/dev/null | head -1 || true)
[ -n "$util" ] && [ -n "$dll" ] || { echo "::error::SoftHSM2 not found: util='$util' dll='$dll'"; exit 1; }
export PATH="$(dirname "$util"):$PATH"
module=$(cygpath -w "$dll")
"$here/provision-pkcs11.sh" "$fx" "$module"

CUSTODY_FIXTURES=$(cygpath -w "$fx") \
CUSTODY_PKCS11_MODULE=$module CUSTODY_PKCS11_TOKEN=akela-test CUSTODY_PKCS11_PIN=1234 \
    annotate_tests cargo test --manifest-path "$here/Cargo.toml" --test cng --test pkcs11 --test harness
