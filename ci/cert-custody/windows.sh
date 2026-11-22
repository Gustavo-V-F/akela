#!/usr/bin/env bash
# Windows certificate custody tests (WI-2026-11-22-001): the current user's certificate store
# (software KSP, key not exportable) and a PKCS#11 token. Runs in Git Bash on a GitHub Actions
# Windows runner.
set -euo pipefail
# GitHub shows annotations publicly; job logs need a token.
[ -z "${GITHUB_ACTIONS:-}" ] || trap 'rc=$?; echo "::error file=ci/cert-custody/${0##*/},line=$LINENO::exit $rc from: $BASH_COMMAND"' ERR
here=$(cd "$(dirname "$0")" && pwd)
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
# SoftHSM2 portable build for Windows (the Chocolatey "softhsm" package installs nothing).
curl -sSL -o "$work/softhsm.zip" https://github.com/disig/SoftHSM2-for-Windows/releases/download/v2.5.0/SoftHSM2-2.5.0-portable.zip
unzip -q "$work/softhsm.zip" -d "$work"
export PATH="$work/SoftHSM2/bin:$PATH"
module=$(cygpath -w "$work/SoftHSM2/lib/softhsm2-x64.dll")
# softhsm2-util.exe is 32-bit and loads the 32-bit module; both use the same token directory.
export SOFTHSM_UTIL_MODULE=$(cygpath -w "$work/SoftHSM2/lib/softhsm2.dll")
"$here/provision-pkcs11.sh" "$fx" "$module"

CUSTODY_FIXTURES=$(cygpath -w "$fx") \
CUSTODY_PKCS11_MODULE=$module CUSTODY_PKCS11_TOKEN=akela-test CUSTODY_PKCS11_PIN=1234 \
    annotate_tests cargo test --manifest-path "$here/Cargo.toml" --test cng --test pkcs11 --test harness
