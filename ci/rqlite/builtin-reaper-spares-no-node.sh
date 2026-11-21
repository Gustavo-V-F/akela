#!/bin/sh
# Limit: rqlite's own reaper (-raft-reap-node-timeout, -raft-reap-read-only-node-timeout) has one
# timeout for all voters and one for all non-voters, with no per-node exclusion, so it also
# removes the Cloud Node. Akela must keep it off and remove nodes itself (remove-unreachable.sh).
. "$(dirname "$0")/lib.sh"
reap="-raft-reap-node-timeout=3s -raft-reap-read-only-node-timeout=3s"
# shellcheck disable=SC2086
start 1 $reap
wait_leader n1 1 >/dev/null || fail "n1 did not become Leader"
# shellcheck disable=SC2086
start 2 $reap -join "127.0.0.1:$(raft_port 1)"
# shellcheck disable=SC2086
start 3 $reap -join "127.0.0.1:$(raft_port 1)"
# shellcheck disable=SC2086
start 4 $reap -join "127.0.0.1:$(raft_port 1)" -raft-non-voter
wait_leader n1 "1 2 3 4" >/dev/null || fail "cluster did not form"
kill9 4
wait_true 30 field_is 1 n4 reachable absent || fail "built-in reaper did not remove n4 (behaviour changed: re-check this limit)"
pass "built-in reaper removed the Cloud Node n4 too; it must stay off in Akela"
