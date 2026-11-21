#!/bin/sh
# Single voter: applying an approval restarts the only voter; writes pause during the restart and
# resume after it, with no data lost.
. "$(dirname "$0")/lib.sh"
TLS=1
for i in 1 2; do make_cert "$i"; done
approve 1
install_trust 1
start 1
wait_leader n1 1 >/dev/null || fail "n1 did not become Leader"
execute 1 '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"before\")"]'
approve "1 2"
t0=$(date +%s)
stop 1
install_trust 1
start 1
wait_leader n1 1 >/dev/null || fail "n1 did not come back as Leader"
wait_true 30 execute 1 '["INSERT INTO t VALUES (\"after\")"]' || fail "writes did not resume"
pause=$(($(date +%s) - t0))
[ "$(query 1 strong 'SELECT count(*) FROM t')" = 2 ] || fail "rows lost across the restart"
accepts 1 2 || fail "restarted n1 refuses the newly approved n2"
pass "single voter restarted with the new list; writes paused about ${pause}s; no data lost"
