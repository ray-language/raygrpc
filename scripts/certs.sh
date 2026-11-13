#!/usr/bin/env bash
# Throwaway TLS material for tests: a CA and a localhost leaf it signs (rustls refuses a
# self-signed CA certificate used as the server's own), written to DIR (default ./out/certs).
# Never real secrets: generated on each run, ignored by git.
set -euo pipefail
DIR=${1:-out/certs}
mkdir -p "$DIR"
cd "$DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key.pem -out ca.pem \
    -days 2 -subj "/CN=raygrpc throwaway test CA" 2>/dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout leaf.key.pem -out leaf.csr \
    -subj "/CN=localhost" 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > leaf.ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key.pem -CAcreateserial -out leaf.pem -days 2 \
    -extfile leaf.ext 2>/dev/null
rm -f leaf.csr leaf.ext ca.srl
