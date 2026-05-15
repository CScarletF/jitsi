# Jitsi Meet on Kubernetes

Internal Jitsi Meet deployment on a 2-node Kubernetes cluster for hospital use.
Currently operational locally. External connectivity pending DNS and NAT activation.

## Cluster

| Host            | IP             | Role          | RAM   |
|-----------------|----------------|---------------|-------|
| srv-deploy-eng  | 192.168.20.180 | control-plane | 8 GB  |
| jenkins         | 192.168.20.177 | worker        | 12 GB |

- CNI: Flannel (`10.244.0.0/16` pod CIDR)
- Storage: local-path-provisioner (node-local, default StorageClass)
- LoadBalancer: MetalLB L2 mode, single IP `192.168.20.190`
- LoadBalancer IP shared by: ingress-nginx (TCP 80/443), JVB-1 (UDP 31829), JVB-2 (UDP 31830), coturn (UDP 3478)
- Access: `https://vidcall3-prod.transmedika.co.id` (local /etc/hosts until DNS is active)
- Auth: internal Prosody users only

## Public Network (pending)

| Resource  | Value                          | Status   |
|-----------|--------------------------------|----------|
| Public IP | 157.15.164.236                 | Active   |
| Domain    | vidcall3-prod.transmedika.co.id | DNS pending |
| NAT       | 157.15.164.236 → 192.168.20.190 | Pending  |

Port forwards requested (router → 192.168.20.190):

| Port       | Protocol | Purpose              |
|------------|----------|----------------------|
| 80         | TCP      | Let's Encrypt HTTP-01 |
| 443        | TCP      | HTTPS + WSS          |
| 31829      | UDP      | JVB-1 media          |
| 31830      | UDP      | JVB-2 media          |
| 3478       | UDP      | TURN                 |

## Architecture

### Infrastructure
- **MetalLB** — L2 mode, single VIP `.190`, ARP failover between nodes
- **ingress-nginx** — TCP 80/443, LoadBalancer on `.190`
- **cert-manager** — Let's Encrypt HTTP-01 (issuer applied when DNS is live)
- **Prometheus + Grafana + Alertmanager** — `monitoring` namespace, kube-prometheus-stack
- **KEDA** — event-driven autoscaling for JVB-2

### Jitsi Components (`jitsi` namespace)

| Component | Managed by | Replicas      | Notes                          |
|-----------|------------|---------------|--------------------------------|
| web       | Helm       | 1             | Stateless, scalable            |
| prosody   | Helm       | 1 (fixed)     | Persistent storage, SPOF       |
| jicofo    | Helm       | 1 (fixed)     | SPOF, acceptable for RnD       |
| coturn    | Helm       | 1             | STUN/TURN UDP/3478             |
| jvb-1     | Helm       | 1 (always up) | Primary bridge, never scaled down |
| jvb-2     | Raw manifest + KEDA | 0→1  | Scales up when JVB-1 CPU ≥ 60% |

### JVB Scaling Logic (KEDA)
- JVB-1 is always running — never scaled to zero
- JVB-2 scales **up** when JVB-1 CPU ≥ 60%
- JVB-2 scales **down** only when JVB-1 CPU < 60% **AND** JVB-2 active conferences = 0
- AND logic implemented via KEDA `scalingModifiers` formula
- When JVB-2 is at 0 replicas, absent Prometheus metric is treated as 0 conferences (`ignoreNullValues: true`)
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

| Release   | Namespace    | Chart                                    |
|-----------|--------------|------------------------------------------|
| ingress-nginx | ingress-nginx | ingress-nginx/ingress-nginx           |
| jitsi     | jitsi        | jitsi/jitsi-meet v2.16.0               |
| cert-manager | cert-manager | jetstack/cert-manager                 |
| prometheus | monitoring   | prometheus-community/kube-prometheus-stack |
| keda      | keda         | kedacore/keda                           |

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

# 8. Add local /etc/hosts entry
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

## Enabling External Access (when DNS and NAT are active)

1. Confirm DNS resolves: `dig vidcall3-prod.transmedika.co.id`
2. Confirm TCP 80 reaches ingress: `curl http://vidcall3-prod.transmedika.co.id`
3. Apply cert-manager issuers:
   ```bash
   kubectl apply -f manifests/cert-manager-issuer.yaml
   ```
4. Verify staging certificate issues:
   ```bash
   kubectl describe certificate jitsi-tls -n jitsi
   ```
5. Once staging succeeds, switch to prod issuer in `jitsi-values.yaml`:
   ```yaml
   cert-manager.io/cluster-issuer: "letsencrypt-prod"
   ```
   Then upgrade:
   ```bash
   helm upgrade jitsi jitsi/jitsi-meet -n jitsi -f values/jitsi-values.yaml
   ```

## Secrets

- TLS cert: managed by cert-manager, stored in `jitsi-tls` secret in `jitsi` namespace
- JVB credentials: `jitsi-jitsi-meet-jvb-secret` (managed by Helm)
- Jicofo credentials: `jitsi-jitsi-meet-jicofo-secret` (managed by Helm)
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
- Passwords in values files are placeholders — production team must rotate all credentials before go-live
- TURNS (TURN over TLS/443) disabled — enable in `jitsi-values.yaml` once DNS is active
- Grafana ingress disabled — access via port-forward until DNS is active
- `jenkins` kernel is significantly older (5.15.0-60) than `srv-deploy-eng` (5.15.0-174) — update before production