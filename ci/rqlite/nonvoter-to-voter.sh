#!/bin/sh
# A non-voter becomes a voter at runtime (POST /promote) and then counts for the majority.
. "$(dirname "$0")/lib.sh"
start 1
wait_leader n1 1 >/dev/null || fail "n1 did not become Leader"
start 2 -join "127.0.0.1:$(raft_port 1)"
start 3 -join "127.0.0.1:$(raft_port 1)" -raft-non-voter
wait_leader n1 "1 2 3" >/dev/null || fail "cluster did not form"
field_is 1 n3 voter false || fail "n3 did not start as a non-voter"
[ "$(api 1 /promote -XPOST -d '{"id":"n3"}' -o /dev/null -w '%{http_code}')" = 200 ] || fail "promote n3 returned an error"
wait_true 10 field_is 1 n3 voter true || fail "n3 is still a non-voter"
# With voters n1, n2, n3, losing n1 leaves a majority only if n3 really votes.
kill9 1
new=$(wait_leader "*" "2 3" n1) || fail "no Leader after losing n1: promoted n3 does not vote"
pass "n3 promoted to voter at runtime; n2 and n3 elected $new after losing n1"
