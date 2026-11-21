# Shared helpers for the rqlite capability tests (roadmap 2.1). Source it from a test script.
# Each test runs its own nodes on loopback in a fresh directory: node N listens on HTTP port
# 3999+2N and Raft port 4000+2N, with node ID "nN". Needs rqlited, curl and jq (plus openssl
# for the TLS tests).
set -eu

dir=$(mktemp -d)
TLS=""
trap 'for f in "$dir"/*.pid; do [ -e "$f" ] && kill -9 "$(cat "$f")" 2>/dev/null; done; true' EXIT

http_port() { echo $((3999 + 2 * $1)); }
raft_port() { echo $((4000 + 2 * $1)); }

fail() {
    echo "FAIL: $*"
    for f in "$dir"/*.log; do [ -e "$f" ] && { echo "--- $f"; tail -20 "$f"; }; done
    exit 1
}

pass() { echo "PASS: $*"; exit 0; }

# start N [rqlited flags...]: starts node N in the background with its own data directory.
# With TLS=1 the node uses its own certificate and trusts $dir/trust-nN.pem on both ports.
start() {
    local n=$1 tls_flags
    shift
    tls_flags=""
    if [ -n "$TLS" ]; then
        tls_flags="-node-cert $dir/n$n.crt -node-key $dir/n$n.key -node-ca-cert $dir/trust-n$n.pem -node-verify-client
            -http-cert $dir/n$n.crt -http-key $dir/n$n.key -http-ca-cert $dir/trust-n$n.pem -http-verify-client"
    fi
    # shellcheck disable=SC2086
    rqlited -node-id "n$n" -http-addr "127.0.0.1:$(http_port "$n")" -raft-addr "127.0.0.1:$(raft_port "$n")" \
        $tls_flags "$@" "$dir/data-n$n" >>"$dir/n$n.log" 2>&1 &
    echo $! >"$dir/n$n.pid"
}

# stop N: graceful shutdown (SIGTERM), waiting for the process to exit.
stop() {
    local pid
    pid=$(cat "$dir/n$1.pid")
    kill "$pid"
    for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || { rm -f "$dir/n$1.pid"; return 0; }; sleep 0.1; done
    fail "node n$1 did not stop"
}

# kill9 N: abrupt loss of node N.
kill9() { kill -9 "$(cat "$dir/n$1.pid")"; rm -f "$dir/n$1.pid"; }

# api N PATH [curl args...]: HTTP call to node N; with TLS=1 it presents the certificate of
# node $AS (default N) and trusts $dir/trust.pem.
api() {
    local n=$1 path=$2 as
    shift 2
    if [ -n "$TLS" ]; then
        as=${AS:-$n}
        curl -s --max-time 10 --cacert "$dir/trust.pem" --cert "$dir/n$as.crt" --key "$dir/n$as.key" \
            "https://127.0.0.1:$(http_port "$n")$path" "$@"
    else
        curl -s --max-time 10 "http://127.0.0.1:$(http_port "$n")$path" "$@"
    fi
}

# execute N JSON: write through node N; fails the test on any error.
execute() {
    local res
    res=$(api "$1" /db/execute -XPOST -H 'Content-Type: application/json' -d "$2") || fail "write via n$1 failed"
    echo "$res" | jq -e '[.results[] | select(.error)] | length == 0' >/dev/null || fail "write via n$1: $res"
}

# query N LEVEL SQL: prints the first value of the first row (empty if none).
query() {
    api "$1" /db/query -G --data-urlencode "level=$2" --data-urlencode "q=$3" | jq -r '.results[0].values[0][0] // empty'
}

leader_seen_by() { api "$1" /status 2>/dev/null | jq -r '.store.leader.node_id // empty' 2>/dev/null || true; }

# wait_leader WANT "NODES" [EXCLUDE]: waits until every node in NODES agrees on one Leader,
# which must be WANT ("*" for any) and not EXCLUDE. Prints the Leader's node ID.
wait_leader() {
    local want=$1 nodes=$2 exclude=${3:-} agreed l n
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

# nodes_json N: membership as seen by node N's Leader, including non-voters.
nodes_json() { api "$1" '/nodes?ver=2&nonvoters'; }

# node_field N ID FIELD: a field of node ID in N's membership view ("absent" if not a member).
node_field() {
    nodes_json "$1" | jq -r --arg id "$2" --arg f "$3" \
        '[.nodes[] | select(.id == $id)] | if length == 0 then "absent" else (.[0][$f] | tostring) end'
}

# field_is N ID FIELD VALUE: node ID's FIELD in N's membership view equals VALUE.
field_is() { [ "$(node_field "$1" "$2" "$3")" = "$4" ]; }

# wait_true SECONDS COMMAND...: retries COMMAND every 0.5 s until it succeeds.
wait_true() {
    local t=$1
    shift
    for _ in $(seq $((t * 2))); do "$@" && return 0; sleep 0.5; done
    return 1
}

# cluster3: n1 bootstraps, n2 and n3 join as voters; returns once all agree n1 is Leader.
cluster3() {
    start 1
    wait_leader n1 1 >/dev/null || fail "n1 did not become Leader"
    start 2 -join "127.0.0.1:$(raft_port 1)"
    start 3 -join "127.0.0.1:$(raft_port 1)"
    wait_leader n1 "1 2 3" >/dev/null || fail "n2 and n3 did not join under Leader n1"
}

# caught_up N LEADER: node N has applied everything the Leader has committed.
caught_up() {
    local c a
    c=$(api "$2" /status | jq -r '.store.raft.commit_index // empty')
    a=$(api "$1" /status | jq -r '.store.raft.applied_index // empty')
    [ -n "$c" ] && [ -n "$a" ] && [ "$a" -ge "$c" ]
}

# --- approved-list trust (self-signed certificates) ---

# make_cert N: self-signed certificate for node N, valid for server and client use on 127.0.0.1.
make_cert() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
        -keyout "$dir/n$1.key" -out "$dir/n$1.crt" -subj "/CN=n$1" \
        -addext subjectAltName=IP:127.0.0.1 -addext keyUsage=digitalSignature \
        -addext extendedKeyUsage=serverAuth,clientAuth 2>/dev/null || fail "openssl failed for n$1"
}

# approve "IDS": writes the approved list ($dir/trust.pem) with the certificates of IDS.
approve() {
    : >"$dir/trust.pem"
    for i in $1; do cat "$dir/n$i.crt" >>"$dir/trust.pem"; done
}

# install_trust N: node N's trust file becomes the current approved list (read only at start).
install_trust() { cp "$dir/trust.pem" "$dir/trust-n$1.pem"; }

# rolling_restart "NODES" LEADER: restarts NODES one at a time with the current approved list,
# each only after the previous one caught up; the Leader goes last, after handing leadership
# to the first restarted node.
rolling_restart() {
    local nodes=$1 ldr=$2 first="" n
    for n in $nodes; do
        [ "$n" != "$ldr" ] || continue
        [ -n "$first" ] || first=$n
        stop "$n"
        install_trust "$n"
        start "$n"
        wait_true 30 caught_up "$n" "$ldr" || fail "n$n did not catch up after restart"
    done
    if [ -n "$first" ]; then
        api "$ldr" '/leader?wait' -XPOST -d "{\"id\":\"n$first\"}" -o /dev/null -w '%{http_code}' | grep -q 200 ||
            fail "leadership transfer from n$ldr to n$first failed"
        wait_leader "n$first" "$nodes" >/dev/null || fail "n$first did not become Leader"
    fi
    stop "$ldr"
    install_trust "$ldr"
    start "$ldr"
    if [ -n "$first" ]; then
        wait_true 30 caught_up "$ldr" "$first" || fail "n$ldr did not catch up after restart"
    fi
}

# refuses PORT AS: the TLS listener on PORT rejects the certificate of node AS as not approved.
refuses() {
    curl -sS --max-time 5 --cacert "$dir/trust.pem" --cert "$dir/n$2.crt" --key "$dir/n$2.key" \
        "https://127.0.0.1:$1/" -o /dev/null 2>&1 | grep -q 'unknown ca'
}

# accepts N AS: node N's HTTP API answers a request made with the certificate of node AS.
accepts() { [ "$(AS=$2 api "$1" /status -o /dev/null -w '%{http_code}')" = 200 ]; }

# --- CDC ---

# cdc_receiver PORT: minimal HTTP endpoint (BusyBox nc) that appends each request body as one
# line to $dir/cdc-PORT.jsonl and answers 200.
cdc_receiver() {
    cat >"$dir/cdc-handler.sh" <<'H'
#!/bin/sh
len=0
while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r')
    [ -n "$line" ] || break
    case "$line" in [Cc]ontent-[Ll]ength:*) len=${line#*: } ;; esac
done
{ head -c "$len"; echo; } >>"$CDC_OUT"
printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
H
    chmod +x "$dir/cdc-handler.sh"
    : >"$dir/cdc-$1.jsonl"
    CDC_OUT="$dir/cdc-$1.jsonl" nc -lk -p "$1" -e "$dir/cdc-handler.sh" &
    echo $! >"$dir/cdc-$1.pid"
}

# cdc_config FILE PORT SERVICE_ID: CDC configuration pointing at the local receiver.
cdc_config() { printf '{"endpoint":"http://127.0.0.1:%s/cdc","service_id":"%s"}\n' "$2" "$3" >"$1"; }

# cdc_has PORT SERVICE_ID VALUE: the receiver got an INSERT carrying VALUE from SERVICE_ID.
cdc_has() {
    jq -e -s --arg s "$2" --arg v "$3" \
        'any(.[] | select(.service_id == $s) | .payload[].events[]; .op == "INSERT" and (.after | tostring | contains($v)))' \
        "$dir/cdc-$1.jsonl" >/dev/null 2>&1
}

# tls_cluster3: n1..n3 with self-signed certificates, all three approved, cluster formed.
# Certificates for n4 and n5 exist but are not approved.
tls_cluster3() {
    TLS=1
    for i in 1 2 3 4 5; do make_cert "$i"; done
    approve "1 2 3"
    for i in 1 2 3 4 5; do install_trust "$i"; done
    cluster3
}
