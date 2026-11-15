#!/usr/bin/env bash
# Argo CD's and Flux's CRDs, pinned and SHA-checked, into
# Tests/OvertermTests/Fixtures/gitops-crds (checked in): what the fake's
# printer columns (FakeKubeAPI+GitOps) and the summaries' fields
# (KubeGitOpsWire, the [verify] fields of docs/design/kubernetes/gitops.md)
# are checked against by KubeGitOpsCRDTests, and what the opt-in
# real-cluster suite applies to kind-fake (KubeRealClusterTests,
# OVERTERM_KUBE_TESTS=1). Nothing is downloaded at test time. Run again
# only to change a version: bump it here with each file's new sha256.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Tests/OvertermTests/Fixtures/gitops-crds"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARGO_CD="v3.6.1"
# Flux v2.10.0's controllers (flux2's manifests/bases pin these).
SOURCE_CONTROLLER="v1.10.1"
KUSTOMIZE_CONTROLLER="v1.10.1"
HELM_CONTROLLER="v1.7.1"

# file|url|sha256
FILES=(
  "argocd-application.yaml|https://raw.githubusercontent.com/argoproj/argo-cd/$ARGO_CD/manifests/crds/application-crd.yaml|9fd0da3e7097ad6d1af614fabd5c960bc7ddb00d768c3ef485a2fda6e9460df8"
  "argocd-applicationset.yaml|https://raw.githubusercontent.com/argoproj/argo-cd/$ARGO_CD/manifests/crds/applicationset-crd.yaml|980128848a8d2152b946aec6a11cdd1174b38b04587f4fba94537c040fd84202"
  "flux-source-controller.yaml|https://github.com/fluxcd/source-controller/releases/download/$SOURCE_CONTROLLER/source-controller.crds.yaml|8a57b8050b58366b356df9a9c941ba94f905e1ee500e6816f8cda3556df22c55"
  "flux-kustomize-controller.yaml|https://github.com/fluxcd/kustomize-controller/releases/download/$KUSTOMIZE_CONTROLLER/kustomize-controller.crds.yaml|3023a4dd21ff4892bc694e30dacf7a260c6cbeec1c947d807194b195e7856ad9"
  "flux-helm-controller.yaml|https://github.com/fluxcd/helm-controller/releases/download/$HELM_CONTROLLER/helm-controller.crds.yaml|74c56f8855e1537e9c694cc2a3453eba4291b1ff3acb18b0e62ab007aeda5022"
)

for entry in "${FILES[@]}"; do
  IFS='|' read -r name url sha <<<"$entry"
  curl -sfL "$url" -o "$WORK/$name"
  actual="$(shasum -a 256 "$WORK/$name" | cut -c1-64)"
  if [[ "$actual" != "$sha" ]]; then
    echo "error: $name: sha256 $actual, expected $sha" >&2
    exit 1
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT"
for entry in "${FILES[@]}"; do
  IFS='|' read -r name _ _ <<<"$entry"
  cp "$WORK/$name" "$OUT/$name"
done
cat >"$OUT/VERSIONS" <<EOF
argo-cd $ARGO_CD
source-controller $SOURCE_CONTROLLER
kustomize-controller $KUSTOMIZE_CONTROLLER
helm-controller $HELM_CONTROLLER
EOF
echo "==> $OUT"
du -sh "$OUT"
