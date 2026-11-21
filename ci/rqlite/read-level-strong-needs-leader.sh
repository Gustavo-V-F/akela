#!/bin/sh
# A read with level=strong goes through the Leader, so it fails when there is none.
. "$(dirname "$0")/lib.sh"
cluster3
execute 1 '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"x\")"]'
[ "$(query 3 strong 'SELECT v FROM t')" = x ] || fail "level=strong read on n3 failed with a Leader"
kill9 1
kill9 2
code=$(api 3 /db/query -G --data-urlencode level=strong --data-urlencode 'q=SELECT v FROM t' -o "$dir/r.json" -w '%{http_code}' || true)
# rqlite may answer HTTP 200 with an "error" field instead of rows, so a client must check both.
err=$(jq -r '.error // empty' "$dir/r.json" 2>/dev/null || true)
[ "$code" != 200 ] || [ -n "$err" ] || fail "level=strong read succeeded without a Leader"
! jq -e '.results[0].values' "$dir/r.json" >/dev/null 2>&1 || fail "level=strong read returned rows without a Leader"
pass "level=strong read refused by n3 without a Leader (HTTP $code, error: ${err:-none})"
