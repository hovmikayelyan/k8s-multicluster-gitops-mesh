#!/usr/bin/env bash
# Simulates regional failure of east (staging/primary) and shows traffic is still served by west.
# On real clouds the switch is DNS (Route 53 / Cloud DNS failover records with health checks on each cluster's
# ingress); on kind we hit each cluster's gateway directly.
set -euo pipefail
# NOTE: east has Argo auto-sync + selfHeal; pause it first or it will undo the scale-down:
#   kubectl --context kind-east -n argocd patch app podinfo-east --type merge -p '{"spec":{"syncPolicy":null}}'
port_e=18080; port_w=28080
kubectl --context kind-east -n istio-ingress port-forward svc/istio-ingress $port_e:80 >/dev/null & pe=$!
kubectl --context kind-west -n istio-ingress port-forward svc/istio-ingress $port_w:80 >/dev/null & pw=$!
trap 'kill $pe $pw 2>/dev/null' EXIT; sleep 3
try() { curl -fsS -m 3 "localhost:$1/" >/dev/null 2>&1; }
serve() { try $port_e && echo "east" || { try $port_w && echo "west (failover)" || echo "DOWN"; }; }
echo "before: served by $(serve)"
kubectl --context kind-east -n podinfo scale deploy --all --replicas=0 >/dev/null
sleep 10
echo "east scaled to 0: served by $(serve)"
kubectl --context kind-east -n podinfo scale deploy podinfo-v1 podinfo-v2 --replicas=1 >/dev/null
