#!/bin/sh
# A node removed for unreachability rejoins the same cluster (same generation) as a non-voter,
# keeping its old data directory, and catches up with what it missed.
. "$(dirname "$0")/lib.sh"
cluster3
execute 1 '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"before-removal\")"]'
kill9 3
wait_true 20 field_is 1 n3 reachable false || fail "n3 not reported unreachable"
[ "$(api 1 /remove -XDELETE -d '{"id":"n3"}' -o /dev/null -w '%{http_code}')" = 200 ] || fail "remove n3 failed"
wait_true 10 field_is 1 n3 reachable absent || fail "n3 is still a member"
execute 1 '["INSERT INTO t VALUES (\"while-removed\")"]'
start 3 -join "127.0.0.1:$(raft_port 1)" -raft-non-voter
wait_true 30 field_is 1 n3 reachable true || fail "n3 did not rejoin"
field_is 1 n3 voter false || fail "n3 rejoined as a voter"
wait_true 20 caught_up 3 1 || fail "n3 did not catch up"
[ "$(query 3 none "SELECT v FROM t WHERE v = 'while-removed'")" = while-removed ] || fail "n3 lacks the row written while it was removed"
pass "removed n3 rejoined as a non-voter with its old data and caught up"
