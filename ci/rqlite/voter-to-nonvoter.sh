#!/bin/sh
# A voter becomes a non-voter at runtime (POST /demote) and keeps receiving the data as a replica.
. "$(dirname "$0")/lib.sh"
cluster3
field_is 1 n3 voter true || fail "n3 did not start as a voter"
[ "$(api 1 /demote -XPOST -d '{"id":"n3"}' -o /dev/null -w '%{http_code}')" = 200 ] || fail "demote n3 returned an error"
wait_true 10 field_is 1 n3 voter false || fail "n3 is still a voter"
execute 1 '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"after-demote\")"]'
wait_true 10 caught_up 3 1 || fail "non-voter n3 did not catch up"
[ "$(query 3 none 'SELECT v FROM t')" = after-demote ] || fail "non-voter n3 lacks the new row"
pass "n3 demoted to non-voter at runtime and still replicates"
