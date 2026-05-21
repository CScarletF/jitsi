# Jitsi Meet on Kubernetes

Hospital-grade Jitsi Meet deployment on a 2-node Kubernetes cluster.
**Status: Locally operational. External access infrastructure confirmed ready — pending DNS propagation.**

## Cluster

| Host            | IP             | Role          | RAM   |
|-----------------|----------------|---------------|-------|
| srv-deploy-eng  | 192.168.20.180 | control-plane | 8 GB  |
| jenkins         | 192.168.20.177 | worker        | 12 GB |

- CNI: Flannel (`10.244.0.0/16` pod CIDR)
- Storage: local-path-provisioner (node-local, default StorageClass)
- LoadBalancer: MetalLB L2 mode, single VIP `192.168.20.190`
- LoadBalancer IP shared by: ingress-nginx (TCP 80/443), JVB-1 (UDP 31829), JVB-2 (UDP 31830), coturn (UDP 3478)
- Local access: `https://vidcall3-prod.transmedika.co.id` via `/etc/hosts → 192.168.20.190`
- Auth: internal Prosody users only

## Public Network

| Resource  | Value                           | Status             |
|-----------|---------------------------------|--------------------|
| Public IP | 157.15.164.236                  | ✅ Active, routable |
| Public IP | 157.15.164.66                   | ✅ Active (shared, used by other services) |
| Domain    | vidcall3-prod.transmedika.co.id | ⏳ DNS pending — must point to 157.15.164.236 |
| NAT       | 157.15.164.236 → 192.168.20.190 | ✅ Configured on Mikrotik |

### Port Forward Status (Mikrotik → 192.168.20.190)

| Port  | Protocol | Purpose               | Status               |
|-------|----------|-----------------------|----------------------|
| 80    | TCP      | Let's Encrypt HTTP-01 | ✅ Open              |
| 443   | TCP      | HTTPS + WSS           | ✅ Open              |
| 31829 | UDP      | JVB-1 media           | ✅ Open\|filtered (correct for UDP) |
| 31830 | UDP      | JVB-2 media           | ⏳ Rule exists, not yet verified |
| 3478  | UDP      | TURN                  | ⏳ Rule exists, not yet verified |

> **Note:** UDP ports will always show as "open|filtered" on port scanners — this is correct behavior.
> True UDP connectivity can only be verified with an active WebRTC call or `nc -u`.

## Architecture

### Infrastructure
- **MetalLB** — L2 mode, single VIP `.190`, ARP answered by whichever node is MetalLB speaker
- **ingress-nginx** — TCP 80/443, LoadBalancer on `.190`
- **cert-manager** — Let's Encrypt HTTP-01 issuer configured, **not yet applied** (waiting on DNS)
- **Prometheus + Grafana + Alertmanager** — `monitoring` namespace, kube-prometheus-stack
- **KEDA** — event-driven autoscaling for JVB-2

### Jitsi Components (`jitsi` namespace)

| Component | Managed by          | Replicas | Notes                              |
|-----------|---------------------|----------|------------------------------------|
| web       | Helm                | 1        | Stateless, scalable                |
| prosody   | Helm                | 1 (fixed)| Persistent storage, SPOF           |
| jicofo    | Helm                | 1 (fixed)| SPOF, acceptable for RnD           |
| coturn    | Helm                | 1        | STUN/TURN UDP/3478                 |
| jvb-1     | Helm                | 1        | Primary bridge, never scaled down  |
| jvb-2     | Raw manifest + KEDA | 0→1      | Scales up when JVB-1 CPU ≥ 60%    |

### JVB Scaling Logic (KEDA)
- JVB-1 is always running — never scaled to zero
- JVB-2 scales **up** when JVB-1 CPU ≥ 60%
- JVB-2 scales **down** only when JVB-1 CPU < 60% **AND** JVB-2 active conferences = 0
- AND logic implemented via KEDA `scalingModifiers` formula
- When JVB-2 is at 0 replicas, absent Prometheus metric is treated as 0 (`ignoreNullValues: true`)
- Scale-down stabilization window: 300s (prevents flapping)

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

## Prerequisites

- Kubernetes 1.35+ with kubeadm
- Helm v4+
- Both nodes joined and Ready

## Helm Releases

| Release       | Namespace     | Chart                                        |
|---------------|---------------|----------------------------------------------|
| ingress-nginx | ingress-nginx | ingress-nginx/ingress-nginx                  |
| jitsi         | jitsi         | jitsi/jitsi-meet v2.16.0                    |
| cert-manager  | cert-manager  | jetstack/cert-manager                        |
| prometheus    | monitoring    | prometheus-community/kube-prometheus-stack   |
| keda          | keda          | kedacore/keda                                |

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

# 7. Create first moderator user
bash 03-create-user.sh admin yourpassword

# 8. Add local /etc/hosts entry (until DNS is live)
bash 04-create-hosts.sh
```

## Adding Moderator Users

```bash
bash scripts/03-create-user.sh username password
```

## Upgrading Jitsi Config

```bash
helm upgrade jitsi jitsi/jitsi-meet \
  -n jitsi \
  -f values/jitsi-values.yaml
```

## Accessing Grafana (local, no DNS)

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open http://localhost:3000 — admin / grafana123
```

## Enabling External Access (DNS + cert-manager cutover)

> Prerequisites confirmed: TCP 80/443 open, UDP 31829 open|filtered, NAT `.236 → .190` active.
> Only remaining blocker is DNS propagation.

1. Confirm public DNS resolves correctly:
   ```bash
   dig vidcall3-prod.transmedika.co.id @8.8.8.8
   # Must return 157.15.164.236
   ```

2. Confirm HTTP-01 challenge path is reachable:
   ```bash
   curl http://vidcall3-prod.transmedika.co.id
   # Must reach ingress-nginx (any response is fine, including 404)
   ```

3. Apply cert-manager issuers (staging first):
   ```bash
   kubectl apply -f manifests/cert-manager-issuer.yaml
   ```

4. Verify staging certificate issues (allow 2–5 minutes):
   ```bash
   kubectl describe certificate jitsi-tls -n jitsi
   kubectl describe certificaterequest -n jitsi
   ```

5. Once staging succeeds, switch to prod issuer in `values/jitsi-values.yaml`:
   ```yaml
   cert-manager.io/cluster-issuer: "letsencrypt-prod"
   ```
   Then upgrade:
   ```bash
   helm upgrade jitsi jitsi/jitsi-meet -n jitsi -f values/jitsi-values.yaml
   ```

6. Enable Grafana ingress in `values/prometheus-values.yaml` (currently disabled):
   ```yaml
   grafana:
     ingress:
       enabled: true
   ```

7. Enable TURNS in `values/jitsi-values.yaml` (currently disabled):
   ```yaml
   coturn:
     turns:
       enabled: true
   ```

## Secrets

- TLS cert: currently a self-signed placeholder; will be replaced by cert-manager on DNS cutover
- JVB credentials: `jitsi-jitsi-meet-jvb-secret` (managed by Helm)
- Jicofo credentials: `jitsi-jitsi-meet-jicofo-secret` (managed by Helm)
- Grafana password: `grafana123` — **rotate before go-live**
- TURN secret: `turnpass123` — **rotate before go-live**
- Jicofo XMPP password: `focuspass` — **rotate before go-live**
- JVB XMPP password: `jvbpass123` — **rotate before go-live**
- Never commit the `secrets/` directory contents to Git

## Snapshots

Before any major change, snapshot the active config:

```bash
mkdir -p ~/jitsi-snapshots/jitsi-k8s-<description>-$(date +%Y-%m-%d)
cp -r ~/jitsi-helm-local/* ~/jitsi-snapshots/jitsi-k8s-<description>-$(date +%Y-%m-%d)/
```

## Repository Structure

```
jitsi-helm-local/
├── .gitignore
├── README.md
├── jitsi-external-availability.patch   (kept for history)
├── manifests/
│   ├── namespace.yaml
│   ├── metallb-pool.yaml
│   ├── metallb-l2.yaml
│   ├── cert-manager-issuer.yaml        (apply when DNS is live)
│   ├── jitsi-colibri-ws.yaml           (Colibri WebSocket ingress)
│   └── jvb-2.yaml                      (JVB-2 Deployment + Services + KEDA ScaledObject)
├── values/
│   ├── jitsi-values.yaml
│   ├── cert-manager-values.yaml
│   ├── prometheus-values.yaml
│   └── keda-values.yaml
├── secrets/
│   └── .gitignore
└── scripts/
    ├── 01-install-deps.sh
    ├── 02-install-jitsi.sh
    ├── 03-create-user.sh
    └── 04-create-hosts.sh
```

## Known Limitations (RnD)

- Prosody and jicofo are single-replica SPOFs — acceptable for RnD, revisit for production HA
- All passwords in values files are placeholders — production team must rotate all credentials before go-live
- TURNS (TURN over TLS/443) disabled — enable in `jitsi-values.yaml` once DNS is active
- Grafana ingress disabled — access via port-forward until DNS is active
- `jenkins` kernel is significantly older (5.15.0-60) than `srv-deploy-eng` (5.15.0-174) — update before production
- Self-signed TLS cert currently in use — will be replaced automatically by cert-manager once DNS is live