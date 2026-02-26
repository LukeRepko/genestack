#!/usr/bin/env bash
# Description: Install IPFIX collector DaemonSet for bandwidth telemetry

# shellcheck disable=SC2124,SC2145,SC2294
set -euo pipefail

# Service
SERVICE_NAME="ipfix"
SERVICE_NAMESPACE="ipfix"

# Helm - using local chart
HELM_CHART_PATH="./helm-charts/ipfix"

# Base directories provided by the environment
GENESTACK_BASE_DIR="${GENESTACK_BASE_DIR:-/opt/genestack}"
GENESTACK_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR:-/etc/genestack}"

# Define service-specific override directories
SERVICE_BASE_OVERRIDES="${GENESTACK_BASE_DIR}/base-helm-configs/${SERVICE_NAME}"
SERVICE_CUSTOM_OVERRIDES="${GENESTACK_OVERRIDES_DIR}/helm-configs/${SERVICE_NAME}"
GLOBAL_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR}/helm-configs/global_overrides"

# Read the desired image versions from VERSION_FILE
VERSION_FILE="${GENESTACK_OVERRIDES_DIR}/helm-chart-versions.yaml"

need() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
need helm
need kubectl
need openssl
need yq

echo "==> Ensuring namespace '${SERVICE_NAMESPACE}' exists"
kubectl get ns "${SERVICE_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${SERVICE_NAMESPACE}"

# --- Read image versions from YAML ---
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: helm-chart-versions.yaml not found at $VERSION_FILE" >&2
    exit 1
fi

# Extract IPFIX image versions
IPFIX_COLLECTOR_IMAGE=$(yq eval '.charts.ipfix.images.collector // ""' "$VERSION_FILE")
IPFIX_S3_IMAGE=$(yq eval '.charts.ipfix.images.s3 // "docker.io/amazon/aws-cli:latest"' "$VERSION_FILE")
IPFIX_OVS_EXPORTER_IMAGE=$(yq eval '.charts.ipfix.images.ovsExporter // "docker.io/openvswitch/ovs:3.4.1"' "$VERSION_FILE")

if [ -z "$IPFIX_COLLECTOR_IMAGE" ]; then
    echo "Error: Could not extract IPFIX collector image from $VERSION_FILE" >&2
    echo "Please ensure charts.ipfix.images.collector is defined" >&2
    exit 1
fi

echo "Found IPFIX collector image: $IPFIX_COLLECTOR_IMAGE"
echo "Found S3 image: $IPFIX_S3_IMAGE"
echo "Found OVS exporter image: $IPFIX_OVS_EXPORTER_IMAGE"

# --- Copy ClickHouse credentials to ipfix namespace ---
echo "==> Setting up ClickHouse credentials in namespace '${SERVICE_NAMESPACE}'"
if ! kubectl -n clickhouse get secret clickhouse-db-passwords >/dev/null 2>&1; then
  echo "Error: clickhouse-db-passwords secret not found in clickhouse namespace" >&2
  echo "Please install ClickHouse first: ./bin/install-clickhouse.sh" >&2
  exit 1
fi

WRITER_PASS="$(kubectl -n clickhouse get secret clickhouse-db-passwords -o jsonpath='{.data.writer_password_plain}' | base64 -d)"
kubectl -n "${SERVICE_NAMESPACE}" create secret generic ipfix-clickhouse-creds \
  --from-literal=password="${WRITER_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    Synced clickhouse credentials to ${SERVICE_NAMESPACE}/ipfix-clickhouse-creds"

# Prepare an array to collect -f arguments
overrides_args=()

# Include all YAML files from the BASE configuration directory
if [[ -d "$SERVICE_BASE_OVERRIDES" ]]; then
    echo "Including base overrides from directory: $SERVICE_BASE_OVERRIDES"
    for file in "$SERVICE_BASE_OVERRIDES"/*.yaml; do
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

# Collect all --set arguments for image overrides
set_args=(
    --set "ipfix.images.collector=${IPFIX_COLLECTOR_IMAGE}"
    --set "ipfix.images.s3=${IPFIX_S3_IMAGE}"
    --set "ipfix.images.ovsExporter=${IPFIX_OVS_EXPORTER_IMAGE}"
)

helm_command=(
    helm upgrade --install "$SERVICE_NAME" "$HELM_CHART_PATH"
    --namespace="$SERVICE_NAMESPACE"
    --timeout 120m
    --create-namespace

    "${overrides_args[@]}"
    "${set_args[@]}"

    # Post-renderer configuration
    --post-renderer "$GENESTACK_OVERRIDES_DIR/kustomize/kustomize.sh"
    --post-renderer-args "$SERVICE_NAME/overlay"

    "$@"
)

echo "==> Executing Helm command (arguments are quoted safely):"
printf '%q ' "${helm_command[@]}"
echo

# Execute the command directly from the array
"${helm_command[@]}"

echo "==> Waiting for IPFIX collector DaemonSet to be ready"
kubectl -n "${SERVICE_NAMESPACE}" rollout status daemonset/ipfix-collector --timeout=300s || true

echo
cat <<EOF

IPFIX collector installed.

DaemonSet: ipfix-collector (runs on nodes with openstack-network-node=enabled)
  - nfcapd container: Listens on UDP port 4739 (host network)
  - rollup container: Processes flows every 5 minutes, aggregates to ClickHouse
Flow storage: /var/lib/ipfix on each node (hostPath, survives reboots)

ClickHouse target:
  Database: ipfix
  Table: vip_hourly_node
  Endpoint: clickhouse-http.clickhouse.svc.cluster.local:8123

Images:
  Collector: ${IPFIX_COLLECTOR_IMAGE}
  OVS Exporter: ${IPFIX_OVS_EXPORTER_IMAGE}
  S3: ${IPFIX_S3_IMAGE}

Components:
  - ipfix-collector DaemonSet: nfcapd + rollup containers
  - ipfix-ovs-exporter DaemonSet: configures OVS bridge IPFIX export

To view collector pods:
  kubectl -n ${SERVICE_NAMESPACE} get pods -l app=ipfix-collector -o wide

To view OVS exporter pods:
  kubectl -n ${SERVICE_NAMESPACE} get pods -l app=ipfix-ovs-exporter -o wide

To check logs:
  kubectl -n ${SERVICE_NAMESPACE} logs -l app=ipfix-collector -c nfcapd --tail=50
  kubectl -n ${SERVICE_NAMESPACE} logs -l app=ipfix-collector -c rollup --tail=100 -f

Configure OVN/network devices to export IPFIX to:
  <node-ip>:4739

EOF
