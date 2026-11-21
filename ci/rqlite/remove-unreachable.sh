#!/bin/sh
# How Akela removes unreachable nodes while sparing the Cloud Node: the Leader's /nodes view
# reports reachability per node, and DELETE /remove takes out only the nodes the policy picks.
# n4 plays the Cloud Node (a non-voter here).
. "$(dirname "$0")/lib.sh"
cluster3
start 4 -join "127.0.0.1:$(raft_port 1)" -raft-non-voter
wait_true 20 field_is 1 n4 reachable true || fail "n4 did not join"
kill9 3
kill9 4
wait_true 20 field_is 1 n3 reachable false || fail "n3 not reported unreachable"
wait_true 20 field_is 1 n4 reachable false || fail "n4 not reported unreachable"
for id in $(nodes_json 1 | jq -r '.nodes[] | select(.reachable == false) | .id'); do
    [ "$id" != n4 ] || continue
    [ "$(api 1 /remove -XDELETE -d "{\"id\":\"$id\"}" -o /dev/null -w '%{http_code}')" = 200 ] || fail "remove $id failed"
done
wait_true 10 field_is 1 n3 reachable absent || fail "n3 is still a member"
field_is 1 n4 reachable false || fail "the Cloud Node n4 should still be a member"
execute 1 '["CREATE TABLE t (v TEXT)"]'
pass "unreachable n3 removed through the API; the Cloud Node n4 kept"
