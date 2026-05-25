# Jitsi Meet on Kubernetes

Hospital-grade Jitsi Meet deployment on a 2-node Kubernetes cluster.
**Status: Fully operational. External access live. Multi-party SFU calls functional.**

## Cluster

| Host            | IP             | Role          | RAM   |
|-----------------|----------------|---------------|-------|
| srv-deploy-eng  | 192.168.20.180 | control-plane | 8 GB  |
| jenkins         | 192.168.20.177 | worker        | 12 GB |

- CNI: Flannel (`10.244.0.0/16` pod CIDR)
- Storage: local-path-provisioner (node-local, default StorageClass)
- LoadBalancer: MetalLB L2 mode, single VIP `192.168.20.190`
- LoadBalancer IP shared by: ingress-nginx (TCP 80/443), JVB-1 (UDP 31829), JVB-2 (UDP 31830), coturn (UDP 3478)

## Public Network

| Resource  | Value                           | Status |
|-----------|---------------------------------|--------|
| Public IP | 157.15.164.236                  | ✅ Active, routable |
| Public IP | 157.15.164.66                   | ✅ Active (shared, used by other services) |
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

> UDP ports will always show as "open|filtered" on port scanners — this is correct behavior.
> True UDP connectivity can only be verified with an active WebRTC call or `nc -u`.

## Access

The deployment is externally reachable at `https://vidcall3-prod.transmedika.co.id`.

TLS is managed by cert-manager via Let's Encrypt (HTTP-01, `letsencrypt-prod` issuer). The certificate auto-renews.

### Local /etc/hosts fallback

If DNS is temporarily unavailable or you need to access the stack from a machine that can't resolve the public domain (e.g. during network changes), add this to `/etc/hosts`:
```
192.168.20.190  vidcall3-prod.transmedika.co.id
```

Run `scripts/04-create-hosts.sh` on any such machine to add this automatically (requires sudo). Remove the entry once DNS resolves correctly from that machine.

### Switching to external DNS (already done — for reference)

The following steps were taken to activate external access:
1. DNS A record pointed `vidcall3-prod.transmedika.co.id` → `157.15.164.236`
2. Mikrotik NAT configured: ports 80, 443, 31829, 31830, 3478 forwarded to `192.168.20.190`
3. Self-signed TLS secret deleted — cert-manager issued a Let's Encrypt certificate automatically
4. No changes to `jitsi-values.yaml` were required — `publicURL`, `turnHost`, and JVB advertised IPs were already set to the correct public values

## Architecture

### Infrastructure

- **MetalLB** — L2 mode, single VIP `.190`, ARP answered by whichever node is MetalLB speaker
- **ingress-nginx** — TCP 80/443, LoadBalancer on `.190`
- **cert-manager** — Let's Encrypt HTTP-01, `letsencrypt-prod` issuer active, certificate live and auto-renewing
- **Prometheus + Grafana + Alertmanager** — `monitoring` namespace, kube-prometheus-stack
- **KEDA** — event-driven autoscaling for JVB-2

### Jitsi Components (`jitsi` namespace)

| Component | Managed by          | Replicas | Notes |
|-----------|---------------------|----------|-------|
| web       | Helm                | 1        | Stateless, scalable |
| prosody   | Helm                | 1 (fixed)| Persistent storage, SPOF |
| jicofo    | Helm                | 1 (fixed)| SPOF, acceptable for RnD |
| coturn    | Helm                | 1        | STUN/TURN UDP/3478 |
| jvb-1     | Helm                | 1        | Primary bridge, never scaled down |
| jvb-2     | Raw manifest + KEDA | 0→1      | Scales up when JVB-1 CPU ≥ 60% |

### Media Path (How a Call Works)

1. Client loads the web UI and connects to prosody via XMPP WebSocket (`wss://.../xmpp-websocket`)
2. Client sends a conference allocation IQ to jicofo (`focus.meet.jitsi`)
3. Jicofo selects a JVB and returns bridge info
4. Client opens a Colibri WebSocket to JVB (`wss://.../colibri-ws`) for signalling
5. Client sends/receives RTP media directly to JVB via UDP (port 31829/31830)
6. If UDP is blocked, coturn relays media via TURN (UDP 3478)
7. TURN credentials are delivered per-session by prosody's `mod_external_services` — not hardcoded in `config.js`

### TURN Credential Pipeline

Credentials are **not** injected into `config.js`. They are delivered dynamically to each client via XMPP when they join a room, using prosody's `mod_external_services`. Coturn authenticates using HMAC shared secret (`turnpass123`). The `jitsi-jitsi-meet-prosody-coturn` ConfigMap carries `TURN_HOST`, `TURN_PORT`, `TURN_TRANSPORT`, and `STUN_HOST` into the prosody pod as environment variables.

`turnHost` in `jitsi-values.yaml` is the single source of truth for this entire pipeline. If it is unset or wrong, coturn has no realm, prosody has no TURN host to advertise, and clients receive no TURN candidates — all silently.

### Colibri WebSocket Ingress

The `manifests/jitsi-colibri-ws.yaml` ingress routes `/colibri-ws` to JVB's port 9090. The `configuration-snippet` sets `Upgrade`, `Connection`, and `X-Forwarded-Proto` headers manually — **do not add `proxy_set_header Host`** as nginx-ingress already sets it and a duplicate Host header causes Jetty (JVB's HTTP server) to reject the WebSocket upgrade, breaking the bridge channel for all participants.

### JVB Scaling Logic (KEDA)

- JVB-1 is always running — never scaled to zero
- JVB-2 scales **up** when JVB-1 CPU ≥ 60%
- JVB-2 scales **down** only when JVB-1 CPU < 60% **AND** JVB-2 active conferences = 0
- AND logic implemented via KEDA `scalingModifiers` formula: `jvb1_cpu >= 60 ? 100 : jvb2_conferences * 100`
- When JVB-2 is at 0 replicas, absent Prometheus metric is treated as 0 (`ignoreNullValues: true`)
- Scale-down stabilization window: 300s (prevents flapping)

### Coturn Peer IP Policy

The Helm chart hardcodes `denied-peer-ip=10.0.0.0-10.255.255.255` before rendering `allowed-peer-ip` from `allowedPeerIPs`. Coturn evaluates `allowed-peer-ip` as an override to `denied-peer-ip`, so the `allowedPeerIPs: ["10.244.0.0-10.244.255.255"]` entry in `jitsi-values.yaml` correctly permits relay to JVB pods despite the broad deny. JVB pods run in `10.244.0.0/16` (Flannel CIDR).

### Node Placement

- All components prefer `srv-deploy-eng` via `preferredDuringSchedulingIgnoredDuringExecution`
- JVB-2 has additional pod anti-affinity to spread away from JVB-1 when possible
- `externalTrafficPolicy: Cluster` on all JVB and coturn services (required for KEDA compatibility)

## Running Services

```
NAMESPACE     NAME                          TYPE          EXTERNAL-IP     PORT(S)
ingress-nginx ingress-nginx-controller      LoadBalancer  192.168.20.190  80/TCP, 443/TCP
jitsi         jitsi-jitsi-meet-jvb         LoadBalancer  192.168.20.190  31829/UDP, 9090/TCP
jitsi         jvb-2-udp                    LoadBalancer  192.168.20.190  31830/UDP
jitsi         jitsi-jitsi-meet-coturn      LoadBalancer  192.168.20.190  3478/UDP
jitsi         jvb-2-internal               ClusterIP     -               9090/TCP, 8080/TCP, 9888/TCP
```

## Authentication Modes

### Current: Open (anyone can create rooms)

`enableAuth: false` + `enableGuests: true` — anyone who reaches the URL can create and join rooms. No moderator concept. Revisit this before broader rollout.

### Auth required to create rooms

Set `enableAuth: true` in `jitsi-values.yaml`, then upgrade:
```bash
helm upgrade jitsi jitsi/jitsi-meet -n jitsi -f values/jitsi-values.yaml
```

With auth enabled, a prosody user must join first to create the room. Guests connecting without credentials are held until a moderator arrives.

### Managing Prosody Users (when auth is enabled)

```bash
bash scripts/03-create-user.sh username password
```

## Prerequisites

- Kubernetes 1.35+ with kubeadm
- Helm v4+
- Both nodes joined and Ready

## Helm Releases

| Release       | Namespace     | Chart |
|---------------|---------------|-------|
| ingress-nginx | ingress-nginx | ingress-nginx/ingress-nginx |
| jitsi         | jitsi         | jitsi/jitsi-meet v2.16.0 (appVersion stable-10888) |
| cert-manager  | cert-manager  | jetstack/cert-manager |
| prometheus    | monitoring    | prometheus-community/kube-prometheus-stack |
| keda          | keda          | kedacore/keda |

## Fresh Install (in order)

```bash
# 1. Cluster dependencies (Flannel, MetalLB, local-path)
cd scripts/
bash 01-install-deps.sh

# 2. Add Helm repos
helm repo add jitsi https://jitsi-contrib.github.io/jitsi-helm/
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# 3. cert-manager
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  -f values/cert-manager-values.yaml

# 4. Prometheus stack
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f values/prometheus-values.yaml

# 5. KEDA
helm install keda kedacore/keda \
  -n keda --create-namespace \
  -f values/keda-values.yaml

# 6. Jitsi
bash 02-install-jitsi.sh

# 7. Apply Colibri WebSocket ingress
kubectl apply -f manifests/jitsi-colibri-ws.yaml

# 8. Apply JVB-2 + KEDA ScaledObject
kubectl apply -f manifests/jvb-2.yaml

# 9. Add /etc/hosts entry on each client machine (local mode only)
bash 04-create-hosts.sh

# 10. Create first moderator user (only if enableAuth: true)
bash 03-create-user.sh admin yourpassword
```

> **Note:** `02-install-jitsi.sh` references `manifests/jitsi-hpa.yaml` which does not exist in this repo.
> That step will fail silently. The HPA was superseded by the KEDA ScaledObject in `jvb-2.yaml`.
> Remove or update that reference in the script if doing a clean install.

## Upgrading Jitsi Config

```bash
helm upgrade jitsi jitsi/jitsi-meet \
  -n jitsi \
  -f values/jitsi-values.yaml
```

After any upgrade that touches jicofo or prosody config, restart both to avoid XMPP session conflicts:
```bash
kubectl rollout restart deployment/jitsi-jitsi-meet-jicofo -n jitsi
kubectl rollout restart statefulset/jitsi-jitsi-meet-prosody -n jitsi
```

## Accessing Grafana

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open http://localhost:3000 — admin / grafana123
```

## Secrets

| Secret | Location | Notes |
|--------|----------|-------|
| TLS cert | `jitsi-tls` secret, managed by cert-manager | Let's Encrypt cert active, auto-renews |
| JVB credentials | `jitsi-jitsi-meet-jvb-secret` | Managed by Helm |
| Jicofo credentials | `jitsi-jitsi-meet-jicofo-secret` | Managed by Helm |
| Grafana password | `grafana123` | **Rotate before go-live** |
| TURN secret | `turnpass123` | **Rotate before go-live** |
| Jicofo XMPP password | `focuspass` | **Rotate before go-live** |
| JVB XMPP password | `jvbpass123` | **Rotate before go-live** |

Never commit the `secrets/` directory contents to Git.

## Snapshots

Before any major change, snapshot the active config:

```bash
mkdir -p ~/jitsi-snapshots/jitsi-k8s-<description>-$(date +%Y-%m-%d)
cp -r ~/jitsi-helm-local/* ~/jitsi-snapshots/jitsi-k8s-<description>-$(date +%Y-%m-%d)/
```

## Operational Notes

**Jicofo XMPP conflict loop** — if jicofo loses its prosody connection and enters a `conflict: Replaced by new connection` loop, a rollout restart resolves it:
```bash
kubectl rollout restart deployment/jitsi-jitsi-meet-jicofo -n jitsi
```
This can happen when prosody is restarted independently while jicofo keeps running. Always restart jicofo after restarting prosody.

**AV1 Dependency Descriptor warnings in JVB logs** — clients sending AV1 video may produce a flood of `Could not parse AV1 Dependency Descriptor` warnings. This is a known JVB issue with certain Chrome/Android versions and does not affect call quality. Codec preference order is `av1,vp9,vp8,h264` — AV1 can be demoted if the noise is excessive.

**Colibri WebSocket "bridge channel is down"** — caused by a duplicate `Host` header being sent to JVB's Jetty server. Do not add `proxy_set_header Host` to the Colibri WS ingress `configuration-snippet`; nginx-ingress sets it automatically.

**TURN not delivering candidates** — if clients fail to receive relay-type ICE candidates, check that `turnHost` is set in `jitsi-values.yaml` and matches the IP coturn is reachable on. Verify with `kubectl describe configmap jitsi-jitsi-meet-prosody-coturn -n jitsi`. A missing `turnHost` silently breaks coturn realm, prosody TURN advertisement, and client ICE candidate generation simultaneously.

## Repository Structure

```
jitsi-helm/
├── .gitignore
├── README.md
├── assets/
│   └── watermark.svg                       (custom Jitsi watermark — applied via ConfigMap)
├── backup/
│   ├── helm-values-working.yaml            (pre-external-access baseline, NodePort era)
│   ├── jitsi-all-working.yaml              (full kubectl get all snapshot)
│   └── jitsi-tls-secret.yaml              (TLS secret backup)
├── manifests/
│   ├── namespace.yaml
│   ├── metallb-pool.yaml                   (IPAddressPool: 192.168.20.190/32)
│   ├── metallb-l2.yaml                     (L2Advertisement)
│   ├── cert-manager-issuer.yaml            (letsencrypt-staging + letsencrypt-prod ClusterIssuers)
│   ├── jitsi-colibri-ws.yaml               (Colibri WebSocket ingress — apply separately after Helm install)
│   └── jvb-2.yaml                          (JVB-2 Deployment + Services + KEDA ScaledObject)
├── values/
│   ├── jitsi-values.yaml
│   ├── cert-manager-values.yaml
│   ├── prometheus-values.yaml
│   └── keda-values.yaml
├── secrets/
│   └── .gitignore
└── scripts/
    ├── 01-install-deps.sh                  (Flannel, MetalLB, local-path-provisioner)
    ├── 02-install-jitsi.sh                 (ingress-nginx, self-signed TLS, Jitsi Helm install)
    ├── 03-create-user.sh                   (prosodyctl register wrapper)
    ├── 04-create-hosts.sh                  (adds /etc/hosts entry for local-mode access)
    └── update-watermark.sh                 (applies watermark.svg as a ConfigMap)
```

## Known Limitations (RnD)

- Prosody and jicofo are single-replica SPOFs — acceptable for RnD, revisit for production HA
- All passwords in values files are placeholders — production team must rotate all credentials before go-live
- TURNS (TURN over TLS/443) disabled — enable `coturn.turns.enabled: true` in `jitsi-values.yaml` when ready; confirm TCP 443 does not conflict with ingress-nginx
- Grafana ingress disabled — access via port-forward only
- `jenkins` kernel is significantly older (5.15.0-60) than `srv-deploy-eng` (5.15.0-174) — update before production
- JVB-2 Colibri WS ingress routes only to JVB-1's service — if JVB-2 is actively handling a conference when KEDA scales it up, clients assigned to JVB-2 will not have a working Colibri WS path. Acceptable while call volume is low enough that JVB-2 rarely activates.
- `02-install-jitsi.sh` references `manifests/jitsi-hpa.yaml` (stale, removed) — clean this up before using the script for a fresh install.

## Git Branches

| Branch               | Purpose |
|----------------------|---------|
| `main`               | Stable local-mode baseline (NodePort era, internal hostname) |
| `external-availability` | Current — MetalLB LoadBalancer, public IP/domain config, KEDA, full external-ready stack |

Tags: `v1.0.0` → `v2.0.0-pending-dns` track major milestones on the external-availability branch.