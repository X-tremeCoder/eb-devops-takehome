#!/usr/bin/env bash
# Creates (or reuses) kind cluster "demo", installs ingress-nginx, builds and
# loads the service image, and installs the chart as release "demo" in
# namespace "demo". Safe to run more than once.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=demo
NAMESPACE=demo
RELEASE=demo
CTX="kind-${CLUSTER}"
# Last release before ingress-nginx was retired (March 2026).
INGRESS_NGINX_VERSION=controller-v1.15.1

log() { printf '\n==> %s\n' "$*"; }

for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done

log "kind cluster '${CLUSTER}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "already exists, reusing it"
else
  # KIND_NODE_IMAGE lets you pin a node image; default is whatever your kind version ships.
  kind create cluster --name "${CLUSTER}" --config kind-config.yaml ${KIND_NODE_IMAGE:+--image "$KIND_NODE_IMAGE"}
fi

log "ingress-nginx ${INGRESS_NGINX_VERSION}"
kubectl --context "$CTX" apply -f \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
kubectl --context "$CTX" -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

# The admission webhook can lag a few seconds behind the controller being
# Ready, and then creating our Ingress fails. A server-side dry run goes
# through the webhook, so wait until one passes.
echo "waiting for the ingress-nginx admission webhook"
for i in $(seq 1 30); do
  if kubectl --context "$CTX" create ingress webhook-check --class=nginx \
      --rule="check.local/*=check:80" --dry-run=server -o name >/dev/null 2>&1; then
    break
  fi
  [ "$i" -eq 30 ] && { echo "admission webhook never became ready" >&2; exit 1; }
  sleep 2
done

log "build and load the service image"
# Take the image name from the rendered chart so values.yaml stays the only source.
IMAGE=$(helm template "$RELEASE" chart --show-only templates/deployment.yaml \
  | awk '/image:/ { gsub(/"/, "", $2); print $2; exit }')
docker build -t "$IMAGE" service/
kind load docker-image "$IMAGE" --name "$CLUSTER"

log "helm release '${RELEASE}' in namespace '${NAMESPACE}'"
# Helm 4 upgrades with server-side apply. If the ConfigMap was edited with
# kubectl patch, kubectl now owns those fields and a plain upgrade fails on a
# conflict. The chart should win, so force it. Helm 3 doesn't have the flag.
FORCE_CONFLICTS=""
helm version --template '{{.Version}}' | grep -q '^v3\.' || FORCE_CONFLICTS="--force-conflicts"

# shellcheck disable=SC2086
helm upgrade --install "$RELEASE" chart \
  --kube-context "$CTX" --namespace "$NAMESPACE" --create-namespace \
  --wait --timeout 3m $FORCE_CONFLICTS

log "done"
cat <<MSG
Check it:
  kubectl --context $CTX -n $NAMESPACE get pods,svc,ingress
  curl -H 'Host: demo.local' http://localhost/
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: demo.local' http://localhost/healthz
MSG
