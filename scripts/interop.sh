#!/usr/bin/env bash
# raygrpc against its oracles: grpcurl (a real grpc-go client) calls raygrpc's server over
# h2c and TLS, with reflection and with .proto files; protoc checks the bytes (descriptors,
# --encode/--decode/--decode_raw); raygrpc's client checks raygrpc's server. There is no
# third-party gRPC SERVER here, so raygrpc's client is only checked against its own server
# and protoc's bytes.
#
# Usage: scripts/interop.sh            (expects ./raygrpc: `make build` first)
# Servers listen on ephemeral ports (-port 0) and are stopped by their own PID ($!), never
# by name or port.
set -uo pipefail

RAYGRPC=${RAYGRPC:-./raygrpc}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/raygrpc-interop.XXXXXX")
PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}"; do
        if [ -n "$p" ]; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; fi
    done
    rm -rf "$OUT"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { echo "ok    $*"; PASS=$((PASS + 1)); }
ko() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
check() {
    local name=$1
    shift
    if "$@" >"$OUT/last.log" 2>&1; then ok "$name"; else ko "$name"; sed 's/^/        /' "$OUT/last.log" | head -6; fi
}
same() {
    if [ "$2" = "$3" ]; then ok "$1"; else ko "$1"; diff <(echo "$2") <(echo "$3") | head -10 | sed 's/^/        /'; fi
}
# Canonical JSON (sorted keys, no whitespace): protojson adds random spaces on purpose.
canon() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")))'; }

# start_server NAME ARGS... → sets PORT (the server writes its ephemeral port to a file)
start_server() {
    local name=$1
    shift
    local pf="$OUT/$name.port"
    "$RAYGRPC" serve -port 0 -port-file "$pf" -for 120 -quiet "$@" >"$OUT/$name.log" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    PORT=""
    for _ in $(seq 1 100); do
        if [ -s "$pf" ]; then PORT=$(tr -d '\n' <"$pf"); break; fi
        sleep 0.05
    done
    if [ -z "$PORT" ]; then
        echo "server $name did not start:"; cat "$OUT/$name.log"; exit 1
    fi
}

G() { grpcurl -max-time 5 "$@"; }

echo "== protoc: bytes"
protoc -Iproto --include_imports --descriptor_set_out="$OUT/protoc.pb" proto/demo.proto proto/grpc/reflection/v1/reflection.proto
"$RAYGRPC" protoset -import-path proto -proto proto/demo.proto -proto proto/grpc/reflection/v1/reflection.proto -include-imports -o "$OUT/raygrpc.pb"
check "descriptor set identical to protoc --descriptor_set_out" cmp "$OUT/protoc.pb" "$OUT/raygrpc.pb"
protoc -Iproto --encode=raygrpc.demo.Everything proto/demo.proto <tests/fixtures/everything.txt >"$OUT/p.bin"
"$RAYGRPC" encode raygrpc.demo.Everything <tests/fixtures/everything.json >"$OUT/r.bin"
check "encode: JSON gives protoc --encode's bytes" cmp "$OUT/p.bin" "$OUT/r.bin"
same "decode-raw: same text as protoc --decode_raw" "$(protoc --decode_raw <"$OUT/p.bin")" "$("$RAYGRPC" decode-raw <"$OUT/p.bin")"
same "protoc --decode reads raygrpc's bytes" "$(protoc -Iproto --decode=raygrpc.demo.Everything proto/demo.proto <"$OUT/r.bin")" \
    "$(protoc -Iproto --decode=raygrpc.demo.Everything proto/demo.proto <"$OUT/p.bin")"
printf 'f_sint32: -1\npacked_sints: [-9223372036854775808, 9223372036854775807]\nf_float: 3.4028235e38\nf_double: -1e-300\n' >"$OUT/edge.txt"
protoc -Iproto --encode=raygrpc.demo.Everything proto/demo.proto <"$OUT/edge.txt" >"$OUT/edge.bin"
"$RAYGRPC" decode raygrpc.demo.Everything <"$OUT/edge.bin" | "$RAYGRPC" encode raygrpc.demo.Everything >"$OUT/edge2.bin"
check "decode → encode keeps protoc's edge values" cmp "$OUT/edge.bin" "$OUT/edge2.bin"

echo "== grpcurl → raygrpc serve (h2c, reflection)"
start_server h2c
P=$PORT
A="127.0.0.1:$P"
same "list" "$(G -plaintext "$A" list)" "$(printf 'grpc.reflection.v1.ServerReflection\nraygrpc.demo.Echo\nraygrpc.demo.Greeter\nraygrpc.demo.KeyValue')"
same "list a service" "$(G -plaintext "$A" list raygrpc.demo.KeyValue | tr '\n' ' ')" \
    "$("$RAYGRPC" list -plaintext "$A" raygrpc.demo.KeyValue | tr '\n' ' ')"
for sym in raygrpc.demo.Echo raygrpc.demo.Everything raygrpc.demo.EchoReply raygrpc.common.Level \
    raygrpc.demo.KeyValue.Get grpc.reflection.v1.ServerReflection; do
    same "describe $sym: raygrpc prints what grpcurl prints" "$(G -plaintext "$A" describe "$sym")" \
        "$("$RAYGRPC" describe -plaintext "$A" "$sym")"
done
# grpcurl writes what reflection gave it; compare each file with protoc's bytes.
G -plaintext -protoset-out "$OUT/reflected.pb" "$A" describe raygrpc.demo.Echo >/dev/null
G -plaintext -protoset-out "$OUT/reflected2.pb" "$A" describe grpc.reflection.v1.ServerReflection >/dev/null
for f in common.proto demo.proto; do
    same "reflection serves $f byte-identical to protoc" \
        "$(python3 "$(dirname "$0")/fdset.py" "$OUT/reflected.pb" "$f")" "$(python3 "$(dirname "$0")/fdset.py" "$OUT/protoc.pb" "$f")"
done
f=grpc/reflection/v1/reflection.proto
same "reflection serves $f byte-identical to protoc" \
    "$(python3 "$(dirname "$0")/fdset.py" "$OUT/reflected2.pb" "$f")" "$(python3 "$(dirname "$0")/fdset.py" "$OUT/protoc.pb" "$f")"
same "unary call by reflection" "$(G -plaintext -d '{"name":"grpcurl"}' "$A" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, grpcurl!"}'
same "unary call with -proto" "$(G -plaintext -import-path proto -proto demo.proto -d '{"name":"p"}' "$A" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, p!"}'
same "Roundtrip of every type: grpcurl's JSON = raygrpc's JSON" \
    "$(G -plaintext -d @ "$A" raygrpc.demo.Echo/Roundtrip <tests/fixtures/everything.json | canon)" \
    "$("$RAYGRPC" call -plaintext -d @tests/fixtures/everything.json "$A" raygrpc.demo.Echo/Roundtrip | canon)"
same "grpcurl's JSON = raygrpc decode of protoc's bytes" \
    "$(G -plaintext -d @ "$A" raygrpc.demo.Echo/Roundtrip <tests/fixtures/everything.json | canon)" \
    "$("$RAYGRPC" decode raygrpc.demo.Everything <"$OUT/p.bin" | canon)"
same "-emit-defaults: same fields as grpcurl" "$(G -plaintext -emit-defaults -d '{}' "$A" raygrpc.demo.Echo/Roundtrip | canon)" \
    "$("$RAYGRPC" call -plaintext -emit-defaults -d '{}' "$A" raygrpc.demo.Echo/Roundtrip | canon)"
G -plaintext -d '{"code":5,"message":"no such thing: ñ 100%"}' "$A" raygrpc.demo.Echo/Echo >"$OUT/err.out" 2>&1
RC=$?
same "error status: exit code 64+5" "$RC" "69"
same "error status: code and decoded message" "$(grep -E 'Code|Message' "$OUT/err.out" | xargs)" "Code: NotFound Message: no such thing: ñ 100%"
same "-format-error JSON (on stderr)" "$(G -plaintext -format-error -d '{"code":7}' "$A" raygrpc.demo.Echo/Echo 2>&1 | canon)" \
    "$("$RAYGRPC" call -plaintext -format-error -d '{"code":7}' "$A" raygrpc.demo.Echo/Echo 2>&1 | canon)"
same "raygrpc call exit code matches grpcurl's" "$("$RAYGRPC" call -plaintext -d '{"code":5}' "$A" raygrpc.demo.Echo/Echo 2>/dev/null; echo $?)" "69"
START=$(python3 -c 'import time; print(time.time())')
G -plaintext -max-time 0.3 -d '{"delayMs":3000}' "$A" raygrpc.demo.Echo/Echo >"$OUT/dl.out" 2>&1
RC=$?
ELAPSED=$(python3 -c "import time; print(int((time.time() - $START) * 1000))")
same "deadline: -max-time 0.3 → DeadlineExceeded (exit 68)" "$RC" "68"
check "deadline: grpcurl gave up in < 1.5 s ($ELAPSED ms)" test "$ELAPSED" -lt 1500
same "grpc-timeout reaches the handler" "$(G -plaintext -max-time 2 -d '{}' "$A" raygrpc.demo.Echo/Echo | canon | python3 -c 'import json,sys; d=json.load(sys.stdin); print(0 < int(d["deadlineMs"]) <= 2000)')" "True"
G -plaintext -v -H 'x-request-id: 42' -H 'echo-color: blue' -d '{"message":"md"}' "$A" raygrpc.demo.Echo/Echo >"$OUT/v.out" 2>&1
check "metadata: -H reaches the handler" grep -q '"x-request-id": "42"' "$OUT/v.out"
check "metadata: response header x-raygrpc-server" grep -q 'x-raygrpc-server: 0.1' "$OUT/v.out"
check "metadata: echo-* comes back as a trailer" sh -c "sed -n '/Response trailers received/,\$p' '$OUT/v.out' | grep -q 'echo-color: blue'"
same "KeyValue: put, get, list, delete, get" \
    "$(G -plaintext -d '{"key":"a/1","value":"aGk="}' "$A" raygrpc.demo.KeyValue/Put | canon) $(G -plaintext -d '{"key":"a/1"}' "$A" raygrpc.demo.KeyValue/Get | canon) $(G -plaintext -d '{"prefix":"a/"}' "$A" raygrpc.demo.KeyValue/List | canon) $(G -plaintext -d '{"key":"a/1"}' "$A" raygrpc.demo.KeyValue/Delete | canon) $(G -plaintext -d '{"key":"a/1"}' "$A" raygrpc.demo.KeyValue/Get 2>&1 | grep Code | xargs)" \
    '{"created":true} {"value":"aGk="} {"keys":["a/1"]} {"created":true} Code: NotFound'
same "unknown method: Unimplemented" "$(G -plaintext -import-path proto -proto demo.proto -d '{}' "$A" raygrpc.demo.Echo/Missing 2>&1 | head -1)" \
    "Error invoking method \"raygrpc.demo.Echo/Missing\": service \"raygrpc.demo.Echo\" does not include a method named \"Missing\""
G -plaintext -protoset "$OUT/raygrpc.pb" -d '{"name":"set"}' "$A" raygrpc.demo.Greeter/SayHello >"$OUT/ps.out" 2>&1
check "grpcurl reads raygrpc's protoset" grep -q 'Hello, set!' "$OUT/ps.out"

echo "== raygrpc client → raygrpc serve (h2c)"
same "raygrpc list" "$("$RAYGRPC" list -plaintext "$A")" "$(G -plaintext "$A" list)"
same "raygrpc call via net/grpc_conn" "$("$RAYGRPC" call -plaintext -d '{"name":"net"}' "$A" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, net!"}'
same "raygrpc call via its own client" "$("$RAYGRPC" call -plaintext -client raygrpc -d '{"name":"own"}' "$A" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, own!"}'
same "raygrpc call with -protoset from protoc" "$("$RAYGRPC" call -plaintext -protoset "$OUT/protoc.pb" -d '{"name":"ps"}' "$A" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, ps!"}'
same "raygrpc deadline: exit 68" "$("$RAYGRPC" call -plaintext -max-time 0.3 -d '{"delayMs":3000}' "$A" raygrpc.demo.Echo/Echo >/dev/null 2>&1; echo $?)" "68"

echo "== net/grpc_server engine (h2c)"
start_server net -engine net
N="127.0.0.1:$PORT"
same "grpcurl -proto call on net/grpc_server" "$(G -plaintext -import-path proto -proto demo.proto -d '{"name":"net"}' "$N" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, net!"}'
same "grpcurl Roundtrip on net/grpc_server" "$(G -plaintext -import-path proto -proto demo.proto -d @ "$N" raygrpc.demo.Echo/Roundtrip <tests/fixtures/everything.json | canon)" \
    "$("$RAYGRPC" decode raygrpc.demo.Everything <"$OUT/p.bin" | canon)"
same "net/grpc_server: deadline → exit 68" "$(G -plaintext -max-time 0.3 -import-path proto -proto demo.proto -d '{"delayMs":3000}' "$N" raygrpc.demo.Echo/Echo >/dev/null 2>&1; echo $?)" "68"
START=$(python3 -c 'import time; print(time.time())')
grpcurl -max-time 2 -plaintext "$N" list >"$OUT/netlist.out" 2>&1
ELAPSED=$(python3 -c "import time; print(int((time.time() - $START) * 1000))")
check "known gap: reflection on net/grpc_server hangs until the client deadline ($ELAPSED ms)" grep -q 'DeadlineExceeded' "$OUT/netlist.out"

echo "== TLS (throwaway CA from scripts/certs.sh)"
"$(dirname "$0")/certs.sh" "$OUT/certs"
C="$OUT/certs"
start_server tls -tls-cert "$C/leaf.pem" -tls-key "$C/leaf.key.pem"
T="localhost:$PORT"
check "known gap: grpc-go refuses raylang's TLS server (no ALPN)" sh -c "grpcurl -max-time 5 -cacert '$C/ca.pem' '$T' list 2>&1 | grep -q 'missing selected ALPN'"
same "grpcurl -cacert list (GRPC_ENFORCE_ALPN_ENABLED=false)" "$(GRPC_ENFORCE_ALPN_ENABLED=false G -cacert "$C/ca.pem" "$T" list | wc -l | xargs)" "4"
same "grpcurl -cacert call" "$(GRPC_ENFORCE_ALPN_ENABLED=false G -cacert "$C/ca.pem" -d '{"name":"tls"}' "$T" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, tls!"}'
same "grpcurl -insecure call" "$(GRPC_ENFORCE_ALPN_ENABLED=false G -insecure -d '{"name":"tls"}' "127.0.0.1:$PORT" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, tls!"}'
same "raygrpc -cacert -no-alpn call" "$("$RAYGRPC" call -cacert "$C/ca.pem" -no-alpn -d '{"name":"tls"}' "$T" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, tls!"}'
same "raygrpc -insecure describe" "$("$RAYGRPC" describe -insecure "$T" raygrpc.demo.Greeter)" "$(GRPC_ENFORCE_ALPN_ENABLED=false G -insecure "$T" describe raygrpc.demo.Greeter)"
check "raygrpc refuses an unknown CA" sh -c "'$RAYGRPC' call -no-alpn -d '{}' '$T' raygrpc.demo.Greeter/SayHello 2>&1 | grep -q UnknownIssuer"
check "known gap: net/grpc_conn (ALPN h2) cannot reach raylang's TLS server" sh -c \
    "'$RAYGRPC' call -cacert '$C/ca.pem' -protoset '$OUT/protoc.pb' -d '{\"name\":\"x\"}' '$T' raygrpc.demo.Greeter/SayHello 2>&1 | grep -q ALPN"
check "known gap: net/grpc_client (-oneshot) cannot reach it either" sh -c \
    "'$RAYGRPC' call -oneshot -cacert '$C/ca.pem' -protoset '$OUT/protoc.pb' -d '{\"name\":\"x\"}' '$T' raygrpc.demo.Greeter/SayHello 2>&1 | grep -q ALPN"
start_server nettls -engine net -tls-cert "$C/leaf.pem" -tls-key "$C/leaf.key.pem"
same "net/grpc_server.serve_conn over our TLS accept" "$(GRPC_ENFORCE_ALPN_ENABLED=false G -cacert "$C/ca.pem" -import-path proto -proto demo.proto -d '{"name":"nt"}' "localhost:$PORT" raygrpc.demo.Greeter/SayHello | canon)" '{"message":"Hello, nt!"}'

echo
echo "interop: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
