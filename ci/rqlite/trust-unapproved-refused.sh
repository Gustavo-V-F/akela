#!/bin/sh
# Approved-list trust: a machine whose self-signed certificate is not in the list is refused on
# the HTTP API and on the Raft port, and cannot join.
. "$(dirname "$0")/lib.sh"
tls_cluster3
accepts 1 2 || fail "approved n2 was refused by n1"
refuses "$(http_port 1)" 4 || fail "n1 HTTP API accepted unapproved n4"
refuses "$(raft_port 1)" 4 || fail "n1 Raft port accepted unapproved n4"
start 4 -join "127.0.0.1:$(raft_port 1)"
sleep 5
field_is 1 n4 reachable absent || fail "unapproved n4 joined the cluster"
pass "unapproved n4 refused on HTTP and Raft and could not join"
