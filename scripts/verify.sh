#!/usr/bin/env bash
# Acceptance checks, run against both clusters. Each check prints PASS/FAIL.
set -uo pipefail
pass() { echo "PASS  $1"; }; fail() { echo "FAIL  $1"; rc=1; }; rc=0

for c in east west; do
  k="kubectl --context kind-$c"
  echo "== cluster $c"

  # 1. Pod Security Standards: a privileged pod must be rejected by the restricted namespace
  if $k -n podinfo run priv --image=busybox --privileged --restart=Never --dry-run=server 2>&1 | grep -qi "violate\|forbidden"; then
    pass "PSS rejects privileged pod"; else fail "PSS rejects privileged pod"; fi

  # 2. NetworkPolicy: a pod in another namespace cannot reach podinfo
  $k create ns np-test --dry-run=client -o yaml | $k apply -f - >/dev/null
  if $k -n np-test run curl --image=curlimages/curl --restart=Never --rm -i --quiet --command -- \
      curl -sS -m 5 http://podinfo.podinfo:9898/healthz >/dev/null 2>&1; then
    fail "cross-namespace traffic is blocked"; else pass "cross-namespace traffic is blocked"; fi
  $k delete ns np-test --wait=false >/dev/null

  # 3. Istio STRICT mTLS: plaintext from a non-mesh pod is refused (also blocked by NetworkPolicy)
  $k -n podinfo get peerauthentication default -o jsonpath='{.spec.mtls.mode}' | grep -qx STRICT \
    && pass "PeerAuthentication STRICT" || fail "PeerAuthentication STRICT"

  # 4. Sidecars injected & workloads ready
  $k -n podinfo wait --for=condition=available deploy --all --timeout=120s >/dev/null 2>&1 \
    && pass "deployments available" || fail "deployments available"
  $k -n podinfo get pods -o jsonpath='{range .items[*]}{.spec.containers[*].name}{"\n"}{end}' | grep -q istio-proxy \
    && pass "istio-proxy sidecar injected" || fail "istio-proxy sidecar injected"
done

# 5. GitOps state
kubectl --context kind-east -n argocd get applications.argoproj.io
exit $rc
