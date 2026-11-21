#!/bin/sh
# A machine that was off during an approval fetches the current list from an approved node
# before starting rqlited (here: from the list stored in the Location Cluster), then rejoins and
# accepts the newly approved machine.
. "$(dirname "$0")/lib.sh"
tls_cluster3
store_cert() { jq -n --arg id "n$1" --arg c "$(cat "$dir/n$1.crt")" '[["INSERT INTO approved_machine (id, cert) VALUES (?, ?)", $id, $c]]'; }
execute 1 '["CREATE TABLE approved_machine (id TEXT PRIMARY KEY, cert TEXT NOT NULL)"]'
for i in 1 2 3; do execute 1 "$(store_cert "$i")"; done
# n4 is a replica (e.g. a laptop): approved first, then it goes off.
approve "1 2 3 4"
rolling_restart "1 2 3" 1
ldr=$(wait_leader "*" "1 2 3") || fail "no Leader"
execute "${ldr#n}" "$(store_cert 4)"
install_trust 4
start 4 -join "127.0.0.1:$(raft_port "${ldr#n}")" -raft-non-voter
wait_true 30 field_is "${ldr#n}" n4 reachable true || fail "n4 did not join"
stop 4
# While n4 is off, n5 is approved.
execute "${ldr#n}" "$(store_cert 5)"
approve "1 2 3 4 5"
rolling_restart "1 2 3" "${ldr#n}"
ldr=$(wait_leader "*" "1 2 3") || fail "no Leader after approving n5"
install_trust 5
start 5 -join "127.0.0.1:$(raft_port "${ldr#n}")" -raft-non-voter
wait_true 30 field_is "${ldr#n}" n5 reachable true || fail "n5 did not join"
# n4 comes back: it fetches the current list from an approved node with its own certificate.
AS=4 api 1 /db/query -G --data-urlencode level=strong --data-urlencode 'q=SELECT cert FROM approved_machine ORDER BY id' |
    jq -r '.results[0].values[][0]' >"$dir/trust-n4.pem" || fail "n4 could not fetch the list"
grep -c 'BEGIN CERTIFICATE' "$dir/trust-n4.pem" | grep -qx 5 || fail "fetched list does not have 5 certificates"
start 4
wait_true 30 field_is "${ldr#n}" n4 reachable true || fail "n4 did not rejoin"
wait_true 20 caught_up 4 "${ldr#n}" || fail "n4 did not catch up"
accepts 4 5 || fail "n4 refuses n5, approved while n4 was off"
pass "n4, off during the approval of n5, fetched the current list, rejoined and accepts n5"
