#!/bin/sh
# Blocking a machine: remove it from membership, drop its certificate from the list and run the
# restart round; every node then refuses it on HTTP and Raft.
. "$(dirname "$0")/lib.sh"
tls_cluster3
approve "1 2 3 4"
rolling_restart "1 2 3" 1
ldr=$(wait_leader "*" "1 2 3") || fail "no Leader after approving n4"
install_trust 4
start 4 -join "127.0.0.1:$(raft_port "${ldr#n}")" -raft-non-voter
wait_true 30 field_is "${ldr#n}" n4 reachable true || fail "n4 did not join"
[ "$(api "${ldr#n}" /remove -XDELETE -d '{"id":"n4"}' -o /dev/null -w '%{http_code}')" = 200 ] || fail "remove n4 failed"
approve "1 2 3"
rolling_restart "1 2 3" "${ldr#n}"
for i in 1 2 3; do
    refuses "$(http_port "$i")" 4 || fail "n$i HTTP API still accepts blocked n4"
    refuses "$(raft_port "$i")" 4 || fail "n$i Raft port still accepts blocked n4"
done
wait_leader "*" "1 2 3" >/dev/null || fail "no Leader after the block round"
pass "after the block round every node refuses n4 on HTTP and Raft"
