#!/bin/sh
# Backup from a running node (GET /db/backup) restores into a new single-node cluster (POST /boot).
. "$(dirname "$0")/lib.sh"
cluster3
execute 1 '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"backed-up\")"]'
[ "$(api 1 /db/backup -o "$dir/backup.db" -w '%{http_code}')" = 200 ] || fail "backup failed"
head -c 15 "$dir/backup.db" | grep -q 'SQLite format 3' || fail "backup is not a SQLite file"
start 5
wait_leader n5 5 >/dev/null || fail "n5 did not start as a single-node cluster"
[ "$(api 5 /boot -XPOST -H 'Content-Type: application/octet-stream' --data-binary "@$dir/backup.db" -o /dev/null -w '%{http_code}')" = 200 ] ||
    fail "boot of n5 from the backup failed"
[ "$(query 5 strong 'SELECT v FROM t')" = backed-up ] || fail "restored cluster lacks the row"
execute 5 '["INSERT INTO t VALUES (\"after-restore\")"]'
pass "backup taken from a running node and restored with /boot into a new cluster"
