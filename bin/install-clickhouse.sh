#!/usr/bin/env bash
set -euo pipefail

# Service paths
GLOBAL_OVERRIDES_DIR="/etc/genestack/helm-configs/global_overrides"
SERVICE_CONFIG_DIR="/etc/genestack/helm-configs/clickhouse-helm-overrides.yaml"
BASE_OVERRIDES="/opt/genestack/base-helm-configs/clickhouse/clickhouse-helm-overrides.yaml"
KUSTOMIZE_DIR="/etc/genestack/kustomize/clickhouse/overlay"
VERSIONS_FILE="/etc/genestack/helm-chart-versions.yaml"

NS="clickhouse"
OP_RELEASE="altinity-operator"

need() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
need helm
need kubectl
need awk
need sha256sum
need openssl
need envsubst

echo "==> Ensuring namespace '${NS}' exists"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

# --- Create/reuse DB password secret ---
echo "==> Ensuring DB password secret exists in namespace '${NS}'"
if ! kubectl -n "${NS}" get secret clickhouse-db-passwords >/dev/null 2>&1; then
  WRITER_PLAIN="$(openssl rand -hex 16)"
  READER_PLAIN="$(openssl rand -hex 16)"
  WRITER_SHA256="$(printf "%s" "${WRITER_PLAIN}" | sha256sum | awk "{print \$1}")"
  READER_SHA256="$(printf "%s" "${READER_PLAIN}" | sha256sum | awk "{print \$1}")"
  kubectl -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: clickhouse-db-passwords
type: Opaque
stringData:
  writer_password_sha256: "${WRITER_SHA256}"
  reader_password_sha256: "${READER_SHA256}"
  writer_password_plain: "${WRITER_PLAIN}"
  reader_password_plain: "${READER_PLAIN}"
EOF
else
  echo "    Secret 'clickhouse-db-passwords' already exists; reusing."
fi

# --- Read versions from YAML without yq ---
# Simple awk-based extractor: get "key: value" lines.
get_yaml_val() {
  local key="$1"
  awk -v k="$key" '
    $1 ~ k ":" {
      # value may have quotes
      sub(/^[^:]+:[[:space:]]*/,"")
      gsub(/"/,"")
      print
      exit
    }' "${VERSIONS_FILE}"
}

OP_CHART="altinity/altinity-clickhouse-operator"
OP_VERSION="$(get_yaml_val "clickhouse-operator")"
CH_SERVER_IMAGE="altinity/clickhouse-server:$(get_yaml_val "clickhouse-server")"
CH_KEEPER_IMAGE="altinity/clickhouse-keeper:$(get_yaml_val "clickhouse-keeper")"

if [[ -z "${OP_VERSION}" || -z "${CH_SERVER_IMAGE}" || -z "${CH_KEEPER_IMAGE}" ]]; then
  echo "Failed to parse ${VERSIONS_FILE}. Please verify keys." >&2
  exit 1
fi

echo "==> Helm repo add/update for operator chart: ${OP_CHART} @ ${OP_VERSION}"
helm repo add altinity https://helm.altinity.com >/dev/null
helm repo update >/dev/null

echo "==> Installing/Upgrading ClickHouse Operator release '${OP_RELEASE}'"
HELM_CMD="helm upgrade --install ${OP_RELEASE} ${OP_CHART} \
  --version ${OP_VERSION} \
  -n ${NS}"

HELM_CMD+=" -f ${BASE_OVERRIDES}"

for dir in "$GLOBAL_OVERRIDES_DIR" "$SERVICE_CONFIG_DIR"; do
    if compgen -G "${dir}/*.yaml" > /dev/null; then
        for yaml_file in "${dir}"/*.yaml; do
            HELM_CMD+=" -f ${yaml_file}"
        done
    fi
done

HELM_CMD+=" $@"

echo "==> Executing Helm command:"
echo "${HELM_CMD}"
eval "${HELM_CMD}"

echo "==> Waiting for operator to be ready"
kubectl -n "${NS}" rollout status deploy/altinity-operator-altinity-clickhouse-operator --timeout=300s

# --- Apply Kustomize with envsubsted images from versions file ---
export CLICKHOUSE_SERVER_IMAGE="${CH_SERVER_IMAGE}"
export CLICKHOUSE_KEEPER_IMAGE="${CH_KEEPER_IMAGE}"

echo "==> Applying ClickHouse Keeper + Cluster (kustomize + envsubst)"
# We envsubst only image placeholders present in manifests.
kubectl kustomize "${KUSTOMIZE_DIR}" | envsubst '${CLICKHOUSE_SERVER_IMAGE} ${CLICKHOUSE_KEEPER_IMAGE}' | kubectl apply -n "${NS}" -f -

echo "==> Waiting for ClickHouse cluster pods (CHI=ch) to be Ready"
sleep 5  # wait a few seconds for stateful set to be created
kubectl wait -n clickhouse --for=jsonpath='{.status.readyReplicas}'=1 statefulset/chi-ch-main-0-0 --timeout=10m

echo "==> Service endpoint (HTTP 8123)"
kubectl -n "${NS}" get svc clickhouse-http -o wide

# Print connection hints using stored plaintext (if present)
WRITER_PLAIN="$(kubectl -n "${NS}" get secret clickhouse-db-passwords -o jsonpath='{.data.writer_password_plain}' 2>/dev/null | base64 -d || true)"
READER_PLAIN="$(kubectl -n "${NS}" get secret clickhouse-db-passwords -o jsonpath='{.data.reader_password_plain}' 2>/dev/null | base64 -d || true)"

# Print out the in-cluster endpoint, and various service info
cat <<EOF

ClickHouse installed.

In-cluster HTTP endpoint:
  http://clickhouse-http.${NS}.svc.cluster.local:8123

Example queries:
  kubectl -n ${NS} port-forward svc/clickhouse-http 8123:8123 &
  curl -s "http://localhost:8123/?user=reader&password=${READER_PLAIN}&query=SELECT%201"

Users (from Secret clickhouse-db-passwords):
  reader / ${READER_PLAIN}
  writer / ${WRITER_PLAIN}

To rotate passwords: update the Secret and bump taskID in chi-cluster.yaml (or patch):
  kubectl -n ${NS} patch chi ch --type=merge -p '{"spec":{"taskID":"2"}}'

EOF
