#!/bin/sh
# A write sent to a follower is forwarded to the Leader and committed.
. "$(dirname "$0")/lib.sh"
cluster3
served=$(api 3 /db/execute -XPOST -H 'Content-Type: application/json' -D - -o /dev/null \
    -d '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"via-follower\")"]' |
    tr -d '\r' | sed -n 's/^[Xx]-[Rr]qlite-[Ss]erved-[Bb]y: //p')
[ "$served" = "127.0.0.1:$(raft_port 1)" ] || fail "write via n3 was served by '$served', not the Leader n1"
[ "$(query 1 strong 'SELECT v FROM t')" = via-follower ] || fail "row missing on the Leader"
pass "write sent to follower n3 was forwarded to and served by Leader n1"
