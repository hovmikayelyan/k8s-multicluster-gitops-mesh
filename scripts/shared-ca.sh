#!/usr/bin/env bash
# Generate one root CA and an intermediate per cluster; install as istio-system/cacerts (plug-in CA).
set -euo pipefail
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/O=lab/CN=root" -keyout "$d/root-key.pem" -out "$d/root-cert.pem" 2>/dev/null
for c in east west; do
  openssl req -newkey rsa:4096 -nodes -subj "/O=lab/CN=$c-ca" -keyout "$d/$c-key.pem" -out "$d/$c.csr" 2>/dev/null
  printf "basicConstraints=CA:TRUE\nkeyUsage=keyCertSign,cRLSign\nsubjectAltName=DNS:istiod.istio-system.svc\n" > "$d/ext"
  openssl x509 -req -in "$d/$c.csr" -CA "$d/root-cert.pem" -CAkey "$d/root-key.pem" -CAcreateserial -days 3650 -extfile "$d/ext" -out "$d/$c-cert.pem" 2>/dev/null
  cat "$d/$c-cert.pem" "$d/root-cert.pem" > "$d/$c-chain.pem"
  kubectl --context "kind-$c" create ns istio-system --dry-run=client -o yaml | kubectl --context "kind-$c" apply -f -
  kubectl --context "kind-$c" -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$d/$c-cert.pem" --from-file=ca-key.pem="$d/$c-key.pem" \
    --from-file=root-cert.pem="$d/root-cert.pem" --from-file=cert-chain.pem="$d/$c-chain.pem" \
    --dry-run=client -o yaml | kubectl --context "kind-$c" apply -f -
done
