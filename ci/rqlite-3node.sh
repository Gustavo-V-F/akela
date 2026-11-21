#!/bin/sh
# 3-node rqlite cluster on loopback: kill the Leader, expect the two survivors to elect
# a new Leader that still has the data committed before the kill.
# Needs rqlited, curl and jq (run inside the rqlite/rqlite image with curl and jq added).
set -eu

dir=$(mktemp -d)
pids=""
trap 'for p in $pids; do kill -9 "$p" 2>/dev/null || true; done' EXIT

fail() {
    echo "FAIL: $*"
    for f in "$dir"/*.log; do echo "--- $f"; cat "$f"; done
    exit 1
}

http_port() { echo $((3999 + 2 * $1)); }
raft_port() { echo $((4000 + 2 * $1)); }

# Leader node ID as seen by node $1 (empty if none or unreachable).
leader_seen_by() {
    curl -sf "http://127.0.0.1:$(http_port "$1")/status" | jq -r '.store.leader.node_id // empty' 2>/dev/null || true
}

# Waits until every node in "$2" sees node ID $1 as Leader ($1 may be "*" for any agreed
# Leader other than the optional node ID $3).
wait_leader() {
    want=$1 nodes=$2 exclude=${3:-}
    for _ in $(seq 60); do
        agreed=""
        for n in $nodes; do
            l=$(leader_seen_by "$n")
            [ -n "$l" ] || { agreed=""; break; }
            [ -z "$agreed" ] || [ "$agreed" = "$l" ] || { agreed=""; break; }
            agreed=$l
        done
        [ "$agreed" != "$exclude" ] || agreed=""
        if [ -n "$agreed" ] && { [ "$want" = "*" ] || [ "$want" = "$agreed" ]; }; then
            echo "$agreed"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

start() {
    n=$1
    join=""
    [ "$n" -eq 1 ] || join="-join 127.0.0.1:$(raft_port 1)"
    # shellcheck disable=SC2086
    rqlited -node-id "n$n" -http-addr "127.0.0.1:$(http_port "$n")" \
        -raft-addr "127.0.0.1:$(raft_port "$n")" $join "$dir/n$n" >"$dir/n$n.log" 2>&1 &
    pids="$pids $!"
    eval "pid$n=$!"
}

start 1
wait_leader n1 1 >/dev/null || fail "node n1 did not become Leader"
start 2
start 3
wait_leader n1 "1 2 3" >/dev/null || fail "nodes n2 and n3 did not join under Leader n1"
echo "3-node cluster up, Leader n1"

res=$(curl -sf -XPOST "http://127.0.0.1:$(http_port 1)/db/execute" -H 'Content-Type: application/json' \
    -d '["CREATE TABLE t (v TEXT)", "INSERT INTO t VALUES (\"before-kill\")"]') || fail "write failed"
echo "$res" | jq -e '[.results[] | select(.error)] | length == 0' >/dev/null || fail "write error: $res"

# shellcheck disable=SC2154
kill -9 "$pid1"
echo "killed Leader n1"

new=$(wait_leader "*" "2 3" n1) || fail "no new Leader after killing n1"
echo "new Leader: $new"

new_port=$(http_port "${new#n}")
val=$(curl -sf -G "http://127.0.0.1:$new_port/db/query" --data-urlencode 'level=strong' \
    --data-urlencode 'q=SELECT v FROM t' | jq -r '.results[0].values[0][0]') || fail "read failed on $new"
[ "$val" = before-kill ] || fail "committed row missing on new Leader (got: $val)"

echo "PASS: new Leader $new elected and has the committed row"
