#!/usr/bin/env bash
# calls/s of the demo Greeter/SayHello over h2c: native and VM servers (both engines) against
# native and VM clients (net/grpc_conn and raygrpc's own client), C fibers for D seconds each.
#
# Usage: scripts/bench.sh [C] [D]     (expects ./raygrpc: `make build` first)
# Servers listen on ephemeral ports and are stopped by their own PID ($!).
set -uo pipefail

C=${1:-8}
D=${2:-3}
RAYGRPC=${RAYGRPC:-./raygrpc}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/raygrpc-bench.XXXXXX")
PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}"; do
        if [ -n "$p" ]; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; fi
    done
    rm -rf "$OUT"
}
trap cleanup EXIT

vm() { ray run src/main.ray "$@"; }

start() {
    local name=$1
    shift
    local pf="$OUT/$name.port"
    "$@" -port 0 -port-file "$pf" -for 600 -quiet >"$OUT/$name.log" 2>&1 &
    PIDS+=("$!")
    PORT=""
    for _ in $(seq 1 200); do
        if [ -s "$pf" ]; then PORT=$(tr -d '\n' <"$pf"); break; fi
        sleep 0.05
    done
    [ -n "$PORT" ] || { echo "server $name did not start"; cat "$OUT/$name.log"; exit 1; }
}

row() {
    local label=$1
    shift
    local rate
    rate=$("$@" 2>&1 | awk '/^rate/ {print $2} /^latency/ {print "p50=" $3 "us p99=" $9 "us"}' | xargs)
    printf '%-58s %s\n' "$label" "$rate"
}

echo "Greeter/SayHello, h2c, $C fibers × 1 connection, ${D}s per row (calls/s, latency)"
start native-raygrpc "$RAYGRPC" serve
P1=$PORT
start native-net "$RAYGRPC" serve -engine net
P2=$PORT
start vm-raygrpc vm serve
P3=$PORT
start vm-net vm serve -engine net
P4=$PORT
for srv in "native server, raygrpc engine:$P1" "native server, net/grpc_server:$P2" "VM server, raygrpc engine:$P3" "VM server, net/grpc_server:$P4"; do
    name=${srv%%:*}
    port=${srv##*:}
    A="127.0.0.1:$port"
    row "$name ← native client (net/grpc_conn)" "$RAYGRPC" bench -plaintext -c "$C" -duration "$D" "$A"
    row "$name ← native client (raygrpc)" "$RAYGRPC" bench -plaintext -client raygrpc -c "$C" -duration "$D" "$A"
    row "$name ← VM client (net/grpc_conn)" vm bench -plaintext -c "$C" -duration "$D" "$A"
done
