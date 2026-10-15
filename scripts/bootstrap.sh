#!/usr/bin/env bash
# Creates two kind clusters (east = staging, west = prod), installs Calico + Argo CD on the hub (east),
# registers west as a managed cluster, shares one Istio root CA, then hands everything to GitOps.
# Requires: docker, kind, kubectl, helm, argocd CLI, istioctl (only for cross-cluster secrets), openssl.
# First: push this folder to your own git repo and replace YOUR_ORG/k8s-multicluster-gitops-mesh in gitops/**/*.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."

for c in east west; do
  kind get clusters | grep -qx "$c" || kind create cluster --config "clusters/$c.yaml"
  kubectl --context "kind-$c" apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
done

# --- Argo CD on the hub ---
kubectl --context kind-east create ns argocd --dry-run=client -o yaml | kubectl --context kind-east apply -f -
kubectl --context kind-east apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.3/manifests/install.yaml
kubectl --context kind-east -n argocd rollout status deploy/argocd-server --timeout=300s

# --- Register clusters with labels the ApplicationSets select on ---
# hub (east) = staging, registered as the in-cluster destination
kubectl --context kind-east apply -n argocd -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-east
  labels: {argocd.argoproj.io/secret-type: cluster, env: staging}
stringData:
  name: east
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML
# west = prod, reachable over the shared docker network
west_ip=$(docker inspect west-control-plane -f '{{ .NetworkSettings.Networks.kind.IPAddress }}')
kubectl config view --raw --minify --context kind-west | sed "s#server: .*#server: https://${west_ip}:6443#" > /tmp/west.kubeconfig
kubectl --context kind-east config set-context --current --namespace=argocd >/dev/null
argocd login --core
argocd cluster add kind-west --kubeconfig /tmp/west.kubeconfig --name west --label env=prod --yes

# --- Shared root CA so sidecars in both clusters trust each other (mTLS across clusters) ---
scripts/shared-ca.sh

# --- Hand over to GitOps (app-of-apps) ---
kubectl --context kind-east apply -n argocd -f gitops/bootstrap/root-app.yaml
echo "Argo CD UI:  kubectl --context kind-east -n argocd port-forward svc/argocd-server 8080:443"
echo "Password:    kubectl --context kind-east -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
