#!/usr/bin/env bash
# Regenerates the protoc-made fixtures the tests compare against (protoc is the oracle).
set -euo pipefail
F=tests/fixtures
protoc -Iproto --descriptor_set_out=$F/demo.pb proto/demo.proto
protoc -Iproto --include_imports --descriptor_set_out=$F/all.pb proto/demo.proto proto/grpc/reflection/v1/reflection.proto
protoc -Iproto --encode=raygrpc.demo.Everything proto/demo.proto < $F/everything.txt > $F/everything.bin
protoc --decode_raw < $F/everything.bin > $F/everything.raw
protoc --decode_raw < $F/all.pb > $F/all.raw
echo "fixtures regenerated with $(protoc --version)"
