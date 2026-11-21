#!/bin/sh
# Approving a machine: add its certificate to the list, restart rqlited one node at a time with the
# new trust file (Leader last, after transferring leadership); the machine is then accepted.
. "$(dirname "$0")/lib.sh"
tls_cluster3
execute 1 '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"before\")"]'
approve "1 2 3 4"
rolling_restart "1 2 3" 1
ldr=$(wait_leader "*" "1 2 3") || fail "no Leader after the restart round"
accepts 1 4 && accepts 2 4 && accepts 3 4 || fail "a restarted node still refuses n4"
install_trust 4
start 4 -join "127.0.0.1:$(raft_port "${ldr#n}")"
wait_true 30 field_is "${ldr#n}" n4 reachable true || fail "approved n4 did not join"
wait_true 20 caught_up 4 "${ldr#n}" || fail "n4 did not catch up"
[ "$(query 4 none 'SELECT v FROM t')" = before ] || fail "n4 lacks data committed before the round"
pass "after one rolling restart round (Leader last) the approved n4 joined and replicated"
