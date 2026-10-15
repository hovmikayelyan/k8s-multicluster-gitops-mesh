# Multi-cluster GitOps with service mesh, Pod Security Standards and NetworkPolicies

Two local clusters (kind): **east** = hub + staging, **west** = prod. Argo CD on east manages both from this repo.

```
                      git (this repo) ──► Argo CD (east, hub)
                                          │  app-of-apps → 3 ApplicationSets (cluster generator, label env=…)
              ┌───────────────────────────┴───────────────────────────┐
         east (env=staging, auto-sync)                         west (env=prod, manual sync)
   Calico · Istio(base,cni,istiod,gateway)              Calico · Istio(base,cni,istiod,gateway)
   ns podinfo: PSS restricted, default-deny,            ns podinfo: PSS restricted, default-deny,
   STRICT mTLS, v1/v2 canary 50/50                      STRICT mTLS, v1/v2 canary 90/10
                      └── shared root CA (plug-in cacerts) → workloads trust each other ──┘
```

## Layout
| Path | What |
|---|---|
| `clusters/` | kind configs (default CNI disabled; Calico so NetworkPolicies are enforced) |
| `scripts/bootstrap.sh`, `shared-ca.sh` | create clusters, Argo CD, register clusters with `env` labels, shared Istio root CA, apply root app |
| `gitops/bootstrap/root-app.yaml` | the only manually applied object (app-of-apps) |
| `gitops/appsets/platform-istio.yaml` | Istio on every cluster (clusters × charts matrix) |
| `gitops/appsets/platform-policies.yaml` | namespaces with PSS labels + NetworkPolicies on every cluster |
| `gitops/appsets/apps.yaml` | workload per cluster, overlay chosen by cluster `env` label; sync strategy differs by env |
| `gitops/platform/policies/` | Namespaces (PSS), default-deny + minimal-allow NetworkPolicies |
| `gitops/apps/podinfo/{base,overlays}` | app, Istio security + traffic resources, per-env promotion overlays |
| `scripts/verify.sh`, `failover-demo.sh` | acceptance checks and failover simulation |

## How each requirement is met
- **Multi-cluster GitOps**: one Argo CD, `ApplicationSet` cluster generators fan the same platform + app out to every registered cluster; adding a cluster = register it with an `env` label.
- **Sync strategies / promotion**: staging `automated(prune, selfHeal)`; prod manual. Promote by PR editing `overlays/prod` (image tags, canary weight, replicas), then approve the sync in Argo.
- **Service mesh (Istio)**: sidecar injection in `podinfo`; `DestinationRule` subsets + `VirtualService` weighted canary, retries, timeout, outlier detection; ingress through an Istio gateway.
- **Zero-trust**: `PeerAuthentication` STRICT mTLS, deny-all `AuthorizationPolicy` + allow only the gateway and own service account identities.
- **Pod Security Standards**: `podinfo` enforces **restricted** (pods are non-root, drop ALL, read-only rootfs, seccomp RuntimeDefault). Istio-CNI replaces the privileged `istio-init` container so injected pods still satisfy *restricted*. `istio-ingress` enforces *baseline* and warns/audits *restricted*.
- **Network Policies**: default-deny ingress+egress, then allow only DNS, istiod (15012), gateway → app, and intra-namespace traffic. Defence in depth with mesh AuthZ.
- **Multi-cluster / failover**: both clusters serve the app independently with a shared trust root, so workloads can federate identities; failover is at the ingress/DNS layer (health-checked DNS records per cluster on real clouds; `scripts/failover-demo.sh` simulates it). Cross-cluster service discovery (`istioctl create-remote-secret`, east-west gateway) is the next step and is deliberately not enabled to keep the blast radius per cluster small.

## Run
```bash
# 1. push this folder to your git repo; replace YOUR_ORG/k8s-multicluster-gitops-mesh in gitops/**/*.yaml
# 2. prerequisites: docker, kind, kubectl, helm, argocd CLI, openssl
scripts/bootstrap.sh
scripts/verify.sh            # PSS reject, NetworkPolicy block, mTLS, sidecars, Argo apps
scripts/failover-demo.sh
# prod promotion: edit gitops/apps/podinfo/overlays/prod/kustomization.yaml in a PR, merge, then:
argocd app sync podinfo-west
```

## Credentials and secrets
No credentials are stored in this repo. Replace the `YOUR_ORG/k8s-multicluster-gitops-mesh` placeholder with your repo URL (use a deploy key or
Argo CD repo credential configured in the cluster if the repo is private). `scripts/shared-ca.sh` generates the Istio root/intermediate CAs
at run time and applies them directly to the clusters; the keys are never written into the repo.
