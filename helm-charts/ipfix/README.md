# IPFIX Collector Helm Chart

IPFIX flow collection and aggregation for bandwidth telemetry. Collects flows from OVS bridges and aggregates them into ClickHouse for billing and analytics.

## Components

| Component | Type | Description |
|-----------|------|-------------|
| `ipfix-collector` | DaemonSet | Receives IPFIX flows (nfcapd) and rolls up to ClickHouse |
| `ipfix-ovs-exporter` | DaemonSet | Configures OVS bridges to export IPFIX flows |
| `ipfix-clickhouse-schema-init` | Job | Initializes ClickHouse database and tables (runs on install/upgrade) |

## Prerequisites

- ClickHouse must be installed and running
- The `clickhouse-db-passwords` secret must exist in the `clickhouse` namespace
- Nodes must have the `openstack-network-node: enabled` label

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Node (per node)                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐      UDP 4739      ┌─────────────────────────┐ │
│  │   OVS       │ ─────────────────► │   ipfix-collector pod   │ │
│  │   br-ex     │                    │  ┌─────────┐ ┌────────┐ │ │
│  │             │                    │  │ nfcapd  │ │ rollup │ │ │
│  └─────────────┘                    │  └────┬────┘ └───┬────┘ │ │
│        ▲                            │       │          │      │ │
│        │                            │       ▼          │      │ │
│  ┌─────┴───────┐                    │  /var/lib/ipfix  │      │ │
│  │ ovs-exporter│                    │       │          │      │ │
│  │    pod      │                    └───────┼──────────┼──────┘ │
│  └─────────────┘                            │          │        │
│                                             │          ▼        │
└─────────────────────────────────────────────┼───────────────────┘
                                              │     ClickHouse
                                              │     (cluster)
                                              └────────►
```

## Troubleshooting

### Kubernetes Level

```bash
# Check pod status
kubectl -n ipfix get pods -o wide

# Check collector logs
kubectl -n ipfix logs -l app=ipfix-collector -c nfcapd --tail=100
kubectl -n ipfix logs -l app=ipfix-collector -c rollup --tail=100 -f

# Check OVS exporter logs
kubectl -n ipfix logs -l app=ipfix-ovs-exporter --tail=100

# Describe pods for events
kubectl -n ipfix describe pod -l app=ipfix-collector
kubectl -n ipfix describe pod -l app=ipfix-ovs-exporter
```

### Host Level - OVS Exporter

SSH to a node with `openstack-network-node=enabled` label.

```bash
# Verify OVS bridge exists
ovs-vsctl list-br

# Check IPFIX configuration on bridge
ovs-vsctl list IPFIX

# Expected output shows:
#   targets: ["127.0.0.1:4739"]
#   obs_domain_id: 1001
#   obs_point_id: <unique per node>
#   cache_active_timeout: 60
#   cache_max_flows: 4096

# Check which bridge has IPFIX configured
ovs-vsctl get Bridge br-ex ipfix

# View IPFIX statistics (if available)
ovs-ofctl dump-ipfix-bridge br-ex
ovs-ofctl dump-ipfix-flow br-ex

# Manually clear IPFIX config (if needed for debugging)
# WARNING: This stops flow export until pod reconfigures
ovs-vsctl clear Bridge br-ex ipfix

# Check OVS logs for IPFIX errors
journalctl -u ovs-vswitchd --since "1 hour ago" | grep -i ipfix
```

### Host Level - Collector

SSH to a node with `openstack-network-node=enabled` label.

```bash
# Check flow files directory
ls -la /var/lib/ipfix/

# Expected files:
#   nfcapd.current.<pid>  - Currently being written (active)
#   nfcapd.YYYYMMDDHHmm   - Rotated files (ready for processing)

# Check processed files
ls -la /var/lib/ipfix/processed/

# View flow file contents (requires nfdump)
nfdump -r /var/lib/ipfix/nfcapd.202602251430 | head -20

# Check disk usage
du -sh /var/lib/ipfix/
du -sh /var/lib/ipfix/processed/

# Verify nfcapd is listening
ss -ulnp | grep 4739

# Check for UDP packet drops (kernel level)
cat /proc/net/udp | head -5
netstat -su | grep -A5 "Udp:"

# Check socket buffer settings
sysctl net.core.rmem_max
sysctl net.core.rmem_default
```

### Verifying Flow Export

```bash
# On the node, capture IPFIX traffic to verify flows are being sent
tcpdump -i lo -n udp port 4739 -c 10

# Expected: UDP packets from 127.0.0.1 to 127.0.0.1:4739

# If no packets, check OVS IPFIX config and bridge traffic
ovs-vsctl list IPFIX
ovs-ofctl dump-flows br-ex | head -10
```

### ClickHouse Schema Issues

If the `ipfix` database or tables don't exist:

```bash
# Check if schema init job ran successfully
kubectl -n ipfix get jobs
kubectl -n ipfix logs job/ipfix-clickhouse-schema-init

# Re-run schema init by deleting and re-installing
kubectl -n ipfix delete job ipfix-clickhouse-schema-init
# Then re-run: bin/install-ipfix.sh

# Or manually verify tables exist
kubectl -n clickhouse exec -it chi-server-ipfix-0-0-0 -- \
  clickhouse-client --query "SHOW TABLES FROM ipfix"
```

### ClickHouse Verification

```bash
# Port-forward to ClickHouse
kubectl -n clickhouse port-forward svc/clickhouse-http 8123:8123 &

# Get credentials
READER_PASS=$(kubectl -n clickhouse get secret clickhouse-db-passwords \
  -o jsonpath='{.data.reader_password_plain}' | base64 -d)

# Check if data is arriving
curl -s "http://localhost:8123/?user=reader&password=${READER_PASS}" \
  --data "SELECT count() FROM ipfix.vip_hourly_node"

# Check recent data by node
curl -s "http://localhost:8123/?user=reader&password=${READER_PASS}" \
  --data "SELECT node, count(), sum(bytes) FROM ipfix.vip_hourly_node 
          WHERE hour_ts > now() - INTERVAL 1 HOUR 
          GROUP BY node ORDER BY sum(bytes) DESC"

# Check data freshness
curl -s "http://localhost:8123/?user=reader&password=${READER_PASS}" \
  --data "SELECT node, max(hour_ts) as latest FROM ipfix.vip_hourly_node GROUP BY node"
```

## Common Issues

### No flow files appearing in /var/lib/ipfix/

1. Check OVS IPFIX is configured: `ovs-vsctl list IPFIX`
2. Check nfcapd is running: `ss -ulnp | grep 4739`
3. Check there's actual traffic on the bridge: `ovs-ofctl dump-flows br-ex`
4. Verify OVS exporter pod is running: `kubectl -n ipfix get pods -l app=ipfix-ovs-exporter`

### Flow files not being processed (piling up)

1. Check rollup container logs: `kubectl -n ipfix logs -l app=ipfix-collector -c rollup`
2. Verify ClickHouse connectivity from the node
3. Check ClickHouse credentials secret exists: `kubectl -n ipfix get secret ipfix-clickhouse-creds`
4. Files younger than 60 seconds are skipped (still being written)

### OVS exporter fails to configure

1. Check bridge exists: `ovs-vsctl br-exists br-ex`
2. Check pod has privileged access
3. Check `/var/run/openvswitch` is mounted
4. Review pod logs for specific error

### High memory usage in rollup container

1. Large flow files can consume memory during parsing
2. Consider reducing `rotateSeconds` to create smaller files
3. Check for backlog of unprocessed files

## File Locations

| Path | Description |
|------|-------------|
| `/var/lib/ipfix/` | Flow files directory (hostPath) |
| `/var/lib/ipfix/nfcapd.current.*` | Active file being written |
| `/var/lib/ipfix/nfcapd.YYYYMMDDHHmm` | Rotated files awaiting processing |
| `/var/lib/ipfix/processed/` | Successfully uploaded files |
| `/var/run/openvswitch/` | OVS socket directory |
| `/scripts/` | Mounted ConfigMap scripts |

## Configuration Reference

See `values.yaml` for all configuration options. Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `ipfix.listenPort` | 4739 | UDP port for IPFIX collection |
| `ipfix.rotateSeconds` | 300 | Flow file rotation interval |
| `ipfix.rollupEverySeconds` | 300 | How often to process and upload |
| `ipfix.ovs.providerBridge` | br-ex | OVS bridge to export from |
| `ipfix.ovs.cacheActiveTimeout` | 60 | Export active flows every N seconds |
| `ipfix.ovs.samplingRate` | 1 | 1 = all packets, N = 1 in N |
