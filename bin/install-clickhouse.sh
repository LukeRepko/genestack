#!/usr/bin/env bash
# Description: Fetches the version for SERVICE_NAME from the specified
# YAML file and executes a helm upgrade/install command with dynamic values files.

# Disable SC2124 (unused array), SC2145 (array expansion issue), SC2294 (eval)
# SC2016 (intentionallay not expanding)
# shellcheck disable=SC2124,SC2145,SC2294,SC2016
set -euo pipefail

# Service
SERVICE_NAME="clickhouse"
SERVICE_NAMESPACE="clickhouse"

# Helm
HELM_REPO_NAME="altinity"
HELM_REPO_URL="https://helm.altinity.com"

# Base directories provided by the environment
GENESTACK_BASE_DIR="${GENESTACK_BASE_DIR:-/opt/genestack}"
GENESTACK_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR:-/etc/genestack}"

# Define service-specific override directories based on the framework
SERVICE_BASE_OVERRIDES="${GENESTACK_BASE_DIR}/base-helm-configs/${SERVICE_NAME}"
SERVICE_CUSTOM_OVERRIDES="${GENESTACK_OVERRIDES_DIR}/helm-configs/${SERVICE_NAME}"
GLOBAL_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR}/helm-configs/global_overrides"

# Read the desired chart version from VERSION_FILE
VERSION_FILE="${GENESTACK_OVERRIDES_DIR}/helm-chart-versions.yaml"
KUSTOMIZE_DIR="/etc/genestack/kustomize/clickhouse/overlay"
OP_RELEASE="altinity-operator"

need() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
need helm
need kubectl
need awk
need sha256sum
need openssl
need envsubst

echo "==> Ensuring namespace '${SERVICE_NAMESPACE}' exists"
kubectl get ns "${SERVICE_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${SERVICE_NAMESPACE}"

# --- Create/reuse DB password secret ---
echo "==> Ensuring DB password secret exists in namespace '${SERVICE_NAMESPACE}'"
if ! kubectl -n "${SERVICE_NAMESPACE}" get secret clickhouse-db-passwords >/dev/null 2>&1; then
  WRITER_PLAIN="$(openssl rand -hex 16)"
  READER_PLAIN="$(openssl rand -hex 16)"
  WRITER_SHA256="$(printf "%s" "${WRITER_PLAIN}" | sha256sum | awk "{print \$1}")"
  READER_SHA256="$(printf "%s" "${READER_PLAIN}" | sha256sum | awk "{print \$1}")"
  kubectl -n "${SERVICE_NAMESPACE}" apply -f - <<EOF
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
    }' "${VERSION_FILE}"
}

OP_CHART="altinity/altinity-clickhouse-operator"
OP_VERSION="$(get_yaml_val "clickhouse-operator")"
CH_SERVER_IMAGE="altinity/clickhouse-server:$(get_yaml_val "clickhouse-server")"
CH_KEEPER_IMAGE="altinity/clickhouse-keeper:$(get_yaml_val "clickhouse-keeper")"

if [[ -z "${OP_VERSION}" || -z "${CH_SERVER_IMAGE}" || -z "${CH_KEEPER_IMAGE}" ]]; then
  echo "Failed to parse ${VERSION_FILE}. Please verify clickhouse-operator, clickhouse-server, and clickhouse-keeper keys exist." >&2
  exit 1
fi

# Prepare an array to collect -f arguments
overrides_args=()

# Include all YAML files from the BASE configuration directory
if [[ -d "$SERVICE_BASE_OVERRIDES" ]]; then
    echo "Including base overrides from directory: $SERVICE_BASE_OVERRIDES"
    for file in "$SERVICE_BASE_OVERRIDES"/*.yaml; do
        # Check that there is at least one match
        if [[ -e "$file" ]]; then
            echo " - $file"
            overrides_args+=("-f" "$file")
        fi
    done
else
    echo "Warning: Base override directory not found: $SERVICE_BASE_OVERRIDES"
fi

# Include all YAML files from the GLOBAL configuration directory
if [[ -d "$GLOBAL_OVERRIDES_DIR" ]]; then
    echo "Including overrides from global config directory:"
    for file in "$GLOBAL_OVERRIDES_DIR"/*.yaml; do
        if [[ -e "$file" ]]; then
            echo " - $file"
            overrides_args+=("-f" "$file")
        fi
    done
else
    echo "Warning: Global config directory not found: $GLOBAL_OVERRIDES_DIR"
fi

# Include all YAML files from the custom SERVICE configuration directory
if [[ -d "$SERVICE_CUSTOM_OVERRIDES" ]]; then
    echo "Including overrides from service config directory:"
    for file in "$SERVICE_CUSTOM_OVERRIDES"/*.yaml; do
        if [[ -e "$file" ]]; then
            echo " - $file"
            overrides_args+=("-f" "$file")
        fi
    done
else
    echo "Warning: Service config directory not found: $SERVICE_CUSTOM_OVERRIDES"
fi

echo

echo "==> Helm repo add/update for operator chart: ${OP_CHART} @ ${OP_VERSION}"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL"
helm repo update

# Collect all --set arguments, executing commands and quoting safely
set_args=()

helm_command=(
    helm upgrade --install "$OP_RELEASE" "$OP_CHART"
    --version "$OP_VERSION"
    --namespace="$SERVICE_NAMESPACE"
    --timeout 120m

    "${overrides_args[@]}"
    "${set_args[@]}"

    "$@"
)

echo "==> Executing Helm command (arguments are quoted safely):"
printf '%q ' "${helm_command[@]}"
echo

# Execute the command directly from the array
"${helm_command[@]}"

echo "==> Waiting for operator to be ready"
kubectl -n "${SERVICE_NAMESPACE}" rollout status deploy/altinity-operator-altinity-clickhouse-operator --timeout=300s

# --- Apply Kustomize with envsubsted images from versions file ---
export CLICKHOUSE_SERVER_IMAGE="${CH_SERVER_IMAGE}"
export CLICKHOUSE_KEEPER_IMAGE="${CH_KEEPER_IMAGE}"

echo "==> Applying ClickHouse Keeper + Cluster (kustomize + envsubst)"
# We envsubst only image placeholders present in manifests.
kubectl kustomize "${KUSTOMIZE_DIR}" | envsubst '${CLICKHOUSE_SERVER_IMAGE} ${CLICKHOUSE_KEEPER_IMAGE}' | kubectl apply -n "${SERVICE_NAMESPACE}" -f -

echo "==> Waiting for ClickHouse cluster pods (CHI=ch) to be Ready"
sleep 5  # wait a few seconds for stateful set to be created
kubectl wait -n clickhouse --for=jsonpath='{.status.readyReplicas}'=1 statefulset/chi-ch-main-0-0 --timeout=10m

echo "==> Service endpoint (HTTP 8123)"
kubectl -n "${SERVICE_NAMESPACE}" get svc clickhouse-http -o wide

# Print connection hints using stored plaintext (if present)
WRITER_PLAIN="$(kubectl -n "${SERVICE_NAMESPACE}" get secret clickhouse-db-passwords -o jsonpath='{.data.writer_password_plain}' 2>/dev/null | base64 -d || true)"
READER_PLAIN="$(kubectl -n "${SERVICE_NAMESPACE}" get secret clickhouse-db-passwords -o jsonpath='{.data.reader_password_plain}' 2>/dev/null | base64 -d || true)"

# Print out the in-cluster endpoint, and various service info
cat <<EOF

ClickHouse installed.

In-cluster HTTP endpoint:
  http://clickhouse-http.${SERVICE_NAMESPACE}.svc.cluster.local:8123

Example queries:
  kubectl -n ${SERVICE_NAMESPACE} port-forward svc/clickhouse-http 8123:8123 &
  curl -s "http://localhost:8123/?user=reader&password=${READER_PLAIN}&query=SELECT%201"

Users (from Secret clickhouse-db-passwords):
  reader / ${READER_PLAIN}
  writer / ${WRITER_PLAIN}

To rotate passwords: update the Secret and bump taskID in chi-cluster.yaml (or patch):
  kubectl -n ${SERVICE_NAMESPACE} patch chi ch --type=merge -p '{"spec":{"taskID":"2"}}'

EOF
