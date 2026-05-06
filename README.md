# Jitsi Meet on Kubernetes

Internal Jitsi Meet deployment on a 2-node k8s cluster.

## Cluster

| Host            | IP             |  Role         |
|-----------------|----------------|---------------|
| srv-deploy-eng  | 192.168.20.180 | control-plane |
| jenkins         | 192.168.20.177 | worker        |

- LoadBalancer IP: `192.168.20.190` (MetalLB)
- Access: `https://vidcall3.internal`
- Auth: internal (Prosody users)

## Prerequisites

- Kubernetes 1.35+ with kubeadm
- Helm v4+
- Both nodes joined and Ready

## Fresh Install (in order)

```bash
cd scripts/
bash 01-install-deps.sh
bash 02-install-jitsi.sh
bash 03-create-user.sh admin yourpassword
bash 04-create-hosts.sh
```

## Adding Moderator Users

```bash
bash scripts/03-create-user.sh username password
```

## Upgrading Jitsi config

Edit `values/jitsi-values.yaml` then:

```bash
helm upgrade jitsi jitsi/jitsi-meet \
  -n jitsi \
  -f values/jitsi-values.yaml
```

## Secrets

TLS cert and key are generated fresh on each install and stored in:
- `/home/srv-deploy-eng/jitsi-tls/`
- Kubernetes secret: `jitsi-tls` in namespace `jitsi`

Never commit the `secrets/` directory contents to Git.

## Snapshots

Before any major change, snapshot the active config:

```bash
mkdir -p ~/jitsi-snapshots/jitsi-k8s-<description>-$(date +%Y-%m-%d)
cp -r ~/jitsi-helm-local/* ~/jitsi-snapshots/jitsi-k8s-<description>-$(date +%Y-%m-%d)/
```
