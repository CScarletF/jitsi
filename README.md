# Jitsi Meet on Kubernetes

Hospital-grade Jitsi Meet deployment on a 2-node Kubernetes cluster.
**Status: Fully operational. External access live. Multi-party SFU calls functional. Jibri recording working.**

## Cluster

| Host            | IP             | Role          | RAM   |
|-----------------|----------------|---------------|-------|
| srv-deploy-eng  | 192.168.20.180 | control-plane | 8 GB  |
| jenkins         | 192.168.20.177 | worker        | 12 GB |

- CNI: Flannel (`10.244.0.0/16` pod CIDR)
- Storage: Longhorn (distributed block storage, 2 replicas across both nodes)
- LoadBalancer: MetalLB L2 mode, single VIP `192.168.20.190`
- LoadBalancer IP shared by: ingress-nginx (TCP 80/443), JVB-1 (UDP 31829), JVB-2 (UDP 31830), coturn (UDP 3478)

## Public Network

| Resource  | Value                           | Status |
|-----------|---------------------------------|--------|
| Public IP | 157.15.164.236                  | ✅ Active, routable |
| Domain    | vidcall3-prod.transmedika.co.id | ✅ DNS live → 157.15.164.236 |
| NAT       | 157.15.164.236 → 192.168.20.190 | ✅ Configured on Mikrotik |

### Port Forward Status (Mikrotik → 192.168.20.190)

| Port  | Protocol | Purpose               | Status |
|-------|----------|-----------------------|--------|
| 80    | TCP      | Let's Encrypt HTTP-01 | ✅ Open |
| 443   | TCP      | HTTPS + WSS           | ✅ Open |
| 31829 | UDP      | JVB-1 media           | ✅ Verified |
| 31830 | UDP      | JVB-2 media           | ✅ Forwarded |
| 3478  | UDP      | TURN                  | ✅ Forwarded |

## Access

The deployment is externally reachable at `https://vidcall3-prod.transmedika.co.id`.

TLS is managed by cert-manager via Let's Encrypt (HTTP-01, `letsencrypt-prod` issuer). The certificate auto-renews.

### Local /etc/hosts fallback

If DNS is temporarily unavailable or you need to reach the stack from a machine that can't resolve the public domain:

```bash
bash scripts/04-create-hosts.sh
```

This adds `192.168.20.190 vidcall3-prod.transmedika.co.id` to `/etc/hosts` automatically.

---

## Configuration

**All deployment-specific values live in a single file: `config.env` at the repo root.**

This includes IPs, domain, ports, credentials, storage sizes, node names, and feature flags. No values are hardcoded in manifests or scripts — everything is rendered at apply time via `envsubst`.

### Editing config

Open `config.env` and update any value. The file is well-commented and segmented by category. Then apply the relevant component:

```bash
./apply.sh jitsi       # Helm upgrade only
./apply.sh manifests   # All raw manifests
./apply.sh all         # Full deploy/upgrade
```

### ⚠️ Before go-live

Rotate all credentials marked `[ROTATE]` in `config.env`. These are RnD placeholders only.

---

## Architecture

### Infrastructure

- **MetalLB** — L2 mode, single VIP `.190`, ARP answered by whichever node is MetalLB speaker
- **ingress-nginx** — TCP 80/443, LoadBalancer on `.190`
- **cert-manager** — Let's Encrypt HTTP-01, `letsencrypt-prod` issuer active, certificate live and auto-renewing
- **Longhorn** — distributed block storage, 2 replicas (one per node), used for Jibri recordings
- **Prometheus + KEDA** — metrics collection and JVB-2 autoscaling

### Jitsi Components (`jitsi` namespace)

| Component | Managed by   | Replicas  | Notes |
|-----------|--------------|-----------|-------|
| web       | Helm         | 1         | Stateless, scalable |
| prosody   | Helm         | 1 (fixed) | Persistent storage, SPOF |
| jicofo    | Helm         | 1 (fixed) | SPOF, acceptable for RnD |
| coturn    | Helm         | 1         | STUN/TURN UDP/3478 |
| jvb-1     | Helm         | 1         | Primary bridge, always running, pinned to stable-10888 |
| jvb-2     | Raw manifest | 0-1       | Standby bridge, KEDA scales 0→1 on JVB-1 CPU ≥ 60% |
| jibri     | Helm         | 2         | Recording, pinned to jenkins, Longhorn-backed |

### Media Path (How a Call Works)

1. Client loads the web UI and connects to prosody via XMPP WebSocket (`wss://.../xmpp-websocket`)
2. Client sends a conference allocation IQ to jicofo (`focus.meet.jitsi`)
3. Jicofo selects a JVB and returns bridge info
4. Client opens a Colibri WebSocket to JVB (`wss://.../colibri-ws`) for signalling
5. Client sends/receives RTP media directly to JVB via UDP (port 31829/31830)
6. If UDP is blocked, coturn relays media via TURN (UDP 3478)
7. TURN credentials are delivered per-session by prosody's `mod_external_services`

### Recording Path (How Jibri Works)

1. Moderator clicks "Start Recording" in the UI
2. Jicofo selects an idle Jibri instance from `jibribrewery@internal-muc.meet.jitsi`
3. Jibri launches Chrome headlessly, joins the call as `recorder@hidden.meet.jitsi`
4. ffmpeg captures the X display and writes `.mp4` to `/data/recordings/<session-id>/`
5. The PVC `jibri-recordings-pvc` is backed by Longhorn (StorageClass `longhorn-jibri`)
6. In `singleUseMode`, Jibri exits after each recording; Kubernetes restarts it ready for the next
7. Two Jibri replicas allow two concurrent recordings

### JVB Image Pinning

JVB is pinned to `stable-10888` (appVersion matching chart 2.16.0). Do not allow `helm repo update` to pull a newer JVB image without testing first — `stable-11031` has a Jetty API breaking change that breaks Colibri WebSocket. The pin is set via `JITSI_IMAGE_TAG` in `config.env`.

### TURN Credential Pipeline

Credentials are delivered dynamically per-session via XMPP using prosody's `mod_external_services`. Coturn authenticates using HMAC shared secret. `turnHost` in `config.env` is the single source of truth for this pipeline.

### Colibri WebSocket Ingress

`templates/jitsi-colibri-ws.yaml.tpl` routes `/colibri-ws` to JVB's port 9090. The `configuration-snippet` sets `Upgrade`, `Connection`, and `X-Forwarded-Proto` headers manually. **Do not add `proxy_http_version 1.1;` to the snippet** — the annotation `nginx.ingress.kubernetes.io/proxy-http-version: "1.1"` already sets it, and a duplicate causes nginx to crash.

---

## Storage (Longhorn)

Jibri recordings are stored on a Longhorn-backed PVC (`jibri-recordings-pvc`, StorageClass `longhorn-jibri`, 20Gi, `reclaimPolicy: Retain`).

Longhorn maintains 2 replicas — one on each node. Writes are synchronous (both replicas must confirm before the write is acknowledged), so there is no sync window unlike file-based replication tools.

**Resilience:**
- One node down → volume continues serving from the surviving replica
- Node recovers → Longhorn resyncs automatically in the background
- Both nodes down → volume unavailable until at least one node recovers

### Accessing the Longhorn UI

```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8888:80
```

Then open `http://localhost:8888` in your browser. From the UI you can inspect volumes, create snapshots, configure backups to S3, and monitor replica health.

### Extracting recordings

Copy recordings out of the Jibri pod directly:

```bash
# List recordings
kubectl exec -n jitsi <jibri-pod> -- ls -lh /data/recordings/

# Copy all recordings to local machine
kubectl cp jitsi/<jibri-pod>:/data/recordings/ ./recordings-export/
```

---

## Repository Structure

```
jitsi-helm/
├── config.env                          ← single source of truth for all values
├── apply.sh                            ← deployment orchestrator (replaces direct helm/kubectl)
├── README.md
├── assets/
│   └── watermark.svg
├── backup/                             ← pre-refactor snapshots (not deployed)
├── templates/                          ← envsubst templates rendered at apply time
│   ├── jitsi-values.yaml.tpl
│   ├── jibri-pvc.yaml.tpl             ← Longhorn PVC (replaces NFS jibri-pv.yaml)
│   ├── jitsi-colibri-ws.yaml.tpl
│   ├── cert-manager-issuer.yaml.tpl
│   ├── cert-manager-values.yaml.tpl
│   ├── prometheus-values.yaml.tpl
│   ├── keda-values.yaml.tpl
│   ├── metallb-pool.yaml.tpl
│   └── jvb-2.yaml.tpl
├── manifests/                          ← static manifests (no variables)
│   ├── namespace.yaml
│   ├── metallb-l2.yaml
│   └── jvb-2.yaml                     ← (rendered from template, do not edit directly)
├── jitsi-meet/                         ← vendored Helm chart (jitsi/jitsi-meet v2.16.0)
├── recordings/                         ← local NFS mount (legacy, to be removed)
└── scripts/
    ├── 01-install-deps.sh              ← Flannel, MetalLB, local-path-provisioner
    ├── 02-install-jitsi.sh             ← full install (ingress-nginx, cert-manager, Longhorn, Jitsi)
    ├── 03-create-user.sh               ← prosodyctl register wrapper
    ├── 04-create-hosts.sh              ← adds /etc/hosts entry for local access
    └── update-watermark.sh             ← applies watermark.svg as ConfigMap
```

---

## Fresh Install (in order)

### Prerequisites

- Kubernetes 1.35+ with kubeadm, both nodes joined and Ready
- Helm v4+
- `envsubst` available (`apt install gettext-base`)
- `open-iscsi` and `nfs-common` installed on both nodes (required for Longhorn)
- `iscsi_tcp` kernel module loaded on both nodes

### Node preparation (both nodes)

```bash
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable iscsid --now
sudo modprobe iscsi_tcp
echo "iscsi_tcp" | sudo tee /etc/modules-load.d/iscsi.conf
sudo systemctl stop multipathd && sudo systemctl disable multipathd
```

Verify Longhorn prerequisites:
```bash
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.7.0/scripts/environment_check.sh | bash
```

### Install

```bash
# 1. Edit config.env — set your domain, IPs, passwords
nano config.env

# 2. Bootstrap cluster dependencies
cd scripts/
bash 01-install-deps.sh

# 3. Full Jitsi install
bash 02-install-jitsi.sh

# 4. Add /etc/hosts entry on each client machine (if needed)
bash 04-create-hosts.sh
```

### Upgrade existing deployment

```bash
./apply.sh jitsi        # Helm values only
./apply.sh manifests    # Raw manifests only
./apply.sh all          # Everything
```

---

## Helm Releases

| Release       | Namespace     | Chart | Version |
|---------------|---------------|-------|---------|
| ingress-nginx | ingress-nginx | ingress-nginx/ingress-nginx | latest |
| cert-manager  | cert-manager  | jetstack/cert-manager | latest |
| longhorn      | longhorn-system | longhorn/longhorn | 1.7.0 |
| prometheus    | monitoring    | prometheus-community/kube-prometheus-stack | latest |
| keda          | keda          | kedacore/keda | latest |
| jitsi         | jitsi         | jitsi/jitsi-meet | 2.16.0 (appVersion stable-10888) |

---

## Authentication Modes

### Current: Open (anyone can create rooms)

`ENABLE_AUTH=false` + `ENABLE_GUESTS=true` in `config.env` — anyone who reaches the URL can create and join rooms.

### Auth required to create rooms

Set `ENABLE_AUTH=true` in `config.env` then run `./apply.sh jitsi`. With auth enabled, a prosody user must join first to create the room.

### Managing Prosody Users (when auth is enabled)

```bash
bash scripts/03-create-user.sh username password
```

---

## Operational Notes

**After any Helm upgrade touching prosody or jicofo config**, restart both:
```bash
kubectl rollout restart deployment/jitsi-jitsi-meet-jicofo -n jitsi
kubectl rollout restart statefulset/jitsi-jitsi-meet-prosody -n jitsi
```

**Jibri recorder password drift** — on every Helm upgrade the Helm-managed secret may drift from prosody's registered password. If recording fails immediately after an upgrade, re-sync:
```bash
kubectl exec -n jitsi jitsi-jitsi-meet-prosody-0 -- \
  prosodyctl --config /config/prosody.cfg.lua \
  register recorder hidden.meet.jitsi "jibrirecorderpass123"
```
The password is set by `JIBRI_RECORDER_PASSWORD` in `config.env`.

**Jicofo XMPP conflict loop** — if jicofo enters a `conflict: Replaced by new connection` loop after prosody restart:
```bash
kubectl rollout restart deployment/jitsi-jitsi-meet-jicofo -n jitsi
```

**Colibri WebSocket "bridge channel is down"** — caused by a duplicate `Host` header or duplicate `proxy_http_version` directive. Do not add either to the Colibri WS ingress `configuration-snippet`.

**nginx CrashLoopBackOff** — if nginx crashes with `proxy_http_version directive is duplicate`, an ingress object has both the annotation and the snippet setting this. Delete the offending ingress and reapply the corrected template.

**JVB image upgrade** — do not upgrade JVB beyond `stable-10888` without testing. `stable-11031` has a Jetty breaking change that breaks Colibri WebSocket. Pin is set via `JITSI_IMAGE_TAG` in `config.env`.

**Checking TLS certificate status:**
```bash
kubectl describe certificate jitsi-tls -n jitsi
```

**TURN not delivering candidates** — check that `TURN_SECRET` and `PUBLIC_IP` are set correctly in `config.env`. Verify the ConfigMap:
```bash
kubectl describe configmap jitsi-jitsi-meet-prosody-coturn -n jitsi
```

**AV1 Dependency Descriptor warnings in JVB logs** — harmless. Known issue with certain Chrome/Android versions.

---

## Secrets

All credentials are set in `config.env`. The following are RnD placeholders — rotate before go-live:

| Credential | config.env key |
|------------|---------------|
| Jicofo XMPP password | `JICOFO_PASSWORD` |
| JVB XMPP password | `JVB_PASSWORD` |
| Jibri XMPP password | `JIBRI_XMPP_PASSWORD` |
| Jibri recorder password | `JIBRI_RECORDER_PASSWORD` |
| TURN/coturn secret | `TURN_SECRET` |
| Grafana admin password | `GRAFANA_PASSWORD` |

---

## Known Limitations (RnD)

- Prosody and jicofo are single-replica SPOFs — acceptable for RnD, revisit for production HA
- All passwords in `config.env` are placeholders — rotate before go-live
- TURNS (TURN over TLS/443) disabled — enable `coturn.turns.enabled: true` when ready
- JVB-2 Colibri WS ingress routes to JVB-1's service only — clients assigned to JVB-2 won't have a working Colibri WS path if JVB-2 is active
- Longhorn uses `ReadWriteOnce` for the Jibri PVC — both Jibri replicas must run on the same node (`jenkins`)
- NFS fstab mount on `srv-deploy-eng` and `/etc/exports` on `jenkins` are legacy and should be cleaned up before production

---

## Git Branches

| Branch          | Purpose |
|-----------------|---------|
| `main`          | Stable baseline — updated after each verified milestone |
| `feature/jibri` | Current — Jibri recording working, Longhorn storage, config.env refactor |

Tags: `v1.0.0` → `v2.0.0-pending` track major milestones.