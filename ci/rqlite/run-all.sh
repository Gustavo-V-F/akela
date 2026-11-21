#!/bin/sh
# Runs every rqlite capability test (roadmap 2.1) and prints one result line per test.
# Each test gets its own processes and directory; a test is limited to 300 s.
here=$(dirname "$0")
failed=0
for t in "$here"/*.sh; do
    name=$(basename "$t" .sh)
    case "$name" in lib | run-all) continue ;; esac
    out=$(timeout 300 sh "$t" 2>&1)
    code=$?
    if [ "$code" -eq 0 ]; then
        echo "ok   $name: $(echo "$out" | sed -n 's/^PASS: //p' | tail -1)"
    else
        failed=$((failed + 1))
        echo "FAIL $name (exit $code)"
        echo "$out" | sed 's/^/     | /' | tail -40
    fi
done
[ "$failed" -eq 0 ] || { echo "$failed test(s) failed"; exit 1; }
echo "all rqlite capability tests passed"
