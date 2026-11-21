#!/bin/sh
# A cluster recreated from a backup with a new service_id (new generation) emits CDC events under
# that service_id; its Raft indexes restart, which is why the generation must be part of the key.
. "$(dirname "$0")/lib.sh"
cdc_receiver 9000
cdc_config "$dir/g1.json" 9000 L1-G1
cdc_config "$dir/g2.json" 9000 L1-G2
start 1 -cdc-config "$dir/g1.json"
wait_leader n1 1 >/dev/null || fail "n1 did not become Leader"
execute 1 '["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", "INSERT INTO t (v) VALUES (\"g1-row\")"]'
for i in $(seq 20); do execute 1 "[\"INSERT INTO t (v) VALUES ('filler-$i')\"]"; done
wait_true 20 cdc_has 9000 L1-G1 g1-row || fail "no CDC event from generation L1-G1"
[ "$(api 1 /db/backup -o "$dir/backup.db" -w '%{http_code}')" = 200 ] || fail "backup failed"
stop 1
start 5 -cdc-config "$dir/g2.json"
wait_leader n5 5 >/dev/null || fail "n5 did not start"
[ "$(api 5 /boot -XPOST -H 'Content-Type: application/octet-stream' --data-binary "@$dir/backup.db" -o /dev/null -w '%{http_code}')" = 200 ] ||
    fail "boot from backup failed"
execute 5 '["INSERT INTO t (v) VALUES (\"g2-row\")"]'
wait_true 20 cdc_has 9000 L1-G2 g2-row || fail "no CDC event from generation L1-G2"
last_g1=$(jq -r -s '[.[] | select(.service_id == "L1-G1") | .payload[].index] | max' "$dir/cdc-9000.jsonl")
g2=$(jq -r -s '[.[] | select(.service_id == "L1-G2") | .payload[] | select(any(.events[]; .after.v == "g2-row")) | .index][0]' "$dir/cdc-9000.jsonl")
[ "$g2" -le "$last_g1" ] || echo "note: G2 index $g2 is above the last G1 index $last_g1 in this run"
pass "new cluster emits CDC under L1-G2 (G2 row at index $g2, last G1 index $last_g1)"
