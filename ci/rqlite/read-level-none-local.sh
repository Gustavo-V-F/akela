#!/bin/sh
# A read with level=none is served from the node's local copy, even with no Leader.
. "$(dirname "$0")/lib.sh"
cluster3
execute 1 '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"local\")"]'
wait_true 10 caught_up 3 1 || fail "n3 did not catch up"
kill9 1
kill9 2
[ "$(query 3 none 'SELECT v FROM t')" = local ] || fail "level=none read on n3 without a Leader failed"
pass "level=none read served locally by n3 with no Leader"
