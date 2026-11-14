#!/usr/bin/env bash
# A kind cluster for the opt-in real-cluster suite (KubeRealClusterTests):
# cluster "fake", context "kind-fake", its kubeconfig a file of its own —
# never ~/.kube/config, which kind writes into unless it is told
# otherwise, so every kind command here gets --kubeconfig.
#
#   Scripts/kube-test-cluster.sh create [dir]      # the cluster; prints the kubeconfig's path
#   Scripts/kube-test-cluster.sh kubeconfig [dir]  # the path, if the cluster is there
#   Scripts/kube-test-cluster.sh delete [dir]      # the cluster, its node container and the file
#
#   OVERTERM_KUBE_TESTS=1 OVERTERM_KUBE_TEST_KUBECONFIG="$(Scripts/kube-test-cluster.sh kubeconfig)" \
#     swift test --filter KubeRealClusterTests
#
# The folder is `dir`, else $TMPDIR/overterm-kind. The node container is
# made from kind's own node image with one label added (`overterm.test`,
# as Docker's tests label theirs) — kind can't label the container itself.
# kindest/node is pulled once; the labelled image is removed by delete.
set -euo pipefail

command="${1:-}"
dir="${2:-${TMPDIR:-/tmp}/overterm-kind}"
cluster="fake"
context="kind-fake"
# kind v0.33's node image (Kubernetes v1.37.0), by digest.
node_image="kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
labelled_image="overterm-kind-node:v1.37.0"

case "$command" in create | delete | kubeconfig) ;; *)
  echo "usage: $0 create|delete|kubeconfig [dir]" >&2
  exit 2
  ;;
esac

mkdir -p "$dir"
dir="$(cd "$dir" && pwd -P)"
kubeconfig="$dir/kubeconfig"

# Never the user's files: not under ~/.kube, not one KUBECONFIG names.
home_kube="$(cd "$HOME" && pwd -P)/.kube"
case "$kubeconfig/" in "$home_kube"/*)
  echo "error: $kubeconfig is under ~/.kube; give the script a folder of its own" >&2
  exit 1
  ;;
esac
if [[ -n "${KUBECONFIG:-}" ]]; then
  IFS=':' read -r -a listed <<<"$KUBECONFIG"
  for file in "${listed[@]}"; do
    [[ -z "$file" ]] && continue
    resolved="$file"
    [[ -e "$file" ]] && resolved="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
    if [[ "$resolved" == "$kubeconfig" ]]; then
      echo "error: KUBECONFIG names $kubeconfig, a file of yours; give the script another folder" >&2
      exit 1
    fi
  done
fi
# Whatever kubectl runs below reads this file and nothing else.
export KUBECONFIG="$kubeconfig"
unset KUBECTL_KUBERC
export KUBERC=off

exists() { kind get clusters 2>/dev/null | grep -qx "$cluster"; }

case "$command" in
kubeconfig)
  if ! exists || [[ ! -s "$kubeconfig" ]]; then
    echo "error: no kind cluster \"$cluster\" with its kubeconfig in $dir; run: $0 create" >&2
    exit 1
  fi
  echo "$kubeconfig"
  ;;
delete)
  if exists; then kind delete cluster --name "$cluster" --kubeconfig "$kubeconfig" >&2; fi
  # The node container, however kind left it (by its labels, never a pattern).
  leftover="$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$cluster" --filter "label=overterm.test")"
  if [[ -n "$leftover" ]]; then docker rm -f $leftover >/dev/null; fi
  docker image rm "$labelled_image" >/dev/null 2>&1 || true
  rm -f "$kubeconfig"
  rmdir "$dir" 2>/dev/null || true
  echo "==> deleted kind cluster \"$cluster\"" >&2
  ;;
create)
  if exists; then
    echo "==> kind cluster \"$cluster\" is there" >&2
  else
    if ! docker image inspect "$labelled_image" >/dev/null 2>&1; then
      docker pull "$node_image" >&2
      printf 'FROM %s\nLABEL overterm.test=1\n' "$node_image" | docker build -q -t "$labelled_image" - >/dev/null
    fi
    kind create cluster --name "$cluster" --image "$labelled_image" --kubeconfig "$kubeconfig" --wait 120s >&2
  fi
  # kind names the context kind-<cluster>; the file holds only it.
  kubectl --context "$context" get --raw /version >/dev/null
  chmod 600 "$kubeconfig"
  echo "$kubeconfig"
  ;;
esac
