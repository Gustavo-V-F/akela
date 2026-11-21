#!/bin/sh
# Leadership moves to a chosen node (POST /leader with the target ID).
. "$(dirname "$0")/lib.sh"
cluster3
[ "$(api 1 '/leader?wait' -XPOST -d '{"id":"n3"}' -o /dev/null -w '%{http_code}')" = 200 ] || fail "transfer to n3 returned an error"
wait_leader n3 "1 2 3" >/dev/null || fail "n3 did not become Leader"
execute 3 '["CREATE TABLE t (v TEXT)"]'
pass "leadership transferred from n1 to the chosen node n3"
