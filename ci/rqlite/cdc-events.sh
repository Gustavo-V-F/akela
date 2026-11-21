#!/bin/sh
# The Leader emits CDC events (with service_id, Raft index and row values) to an HTTP endpoint.
. "$(dirname "$0")/lib.sh"
cdc_receiver 9000
cdc_config "$dir/cdc.json" 9000 L1-G1
start 1 -cdc-config "$dir/cdc.json"
wait_leader n1 1 >/dev/null || fail "n1 did not become Leader"
start 2 -cdc-config "$dir/cdc.json" -join "127.0.0.1:$(raft_port 1)"
start 3 -cdc-config "$dir/cdc.json" -join "127.0.0.1:$(raft_port 1)"
wait_leader n1 "1 2 3" >/dev/null || fail "cluster did not form"
execute 2 '["CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", "INSERT INTO t (v) VALUES (\"cdc-row\")"]'
wait_true 20 cdc_has 9000 L1-G1 cdc-row || fail "no CDC INSERT event for cdc-row from L1-G1"
idx=$(jq -r -s '[.[] | .payload[] | select(any(.events[]; .after.v == "cdc-row")) | .index][0]' "$dir/cdc-9000.jsonl")
pass "CDC INSERT event received from service L1-G1 at Raft index $idx"
