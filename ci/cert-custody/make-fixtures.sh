#!/usr/bin/env bash
# Writes the custody test certificates into DIR: a test CA, a TLS server certificate for
# 127.0.0.1, and two issuer certificates ("issuer", "removal") as A1-like PKCS#12 files
# (3DES, SHA-1 MAC, password "test", the format ICP-Brasil A1 files use) plus their PEM key and DER.
# Usage: make-fixtures.sh DIR
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows must not rewrite "/CN=..." as a path
mkdir -p "$1"
cd "$1"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout ca.key.pem -out ca.pem -subj "/CN=Akela custody test CA" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2>/dev/null
leaf() { # NAME EKU [SAN]
    printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\n%s\n' "$2" "${3:-}" >"$1.ext"
    openssl req -newkey rsa:2048 -nodes -keyout "$1.key.pem" -out "$1.csr" -subj "/CN=akela-custody-$1" 2>/dev/null
    openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key.pem -CAcreateserial -days 30 -extfile "$1.ext" -out "$1.crt.pem" 2>/dev/null
    openssl x509 -in "$1.crt.pem" -outform der -out "$1.crt.der"
}
leaf server serverAuth subjectAltName=IP:127.0.0.1
for n in issuer removal; do
    leaf "$n" clientAuth
    openssl pkcs12 -export -inkey "$n.key.pem" -in "$n.crt.pem" -name "akela-custody-$n" -passout pass:test \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -out "$n.p12"
done
