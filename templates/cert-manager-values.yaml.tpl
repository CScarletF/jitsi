# cert-manager Helm values
# Chart: jetstack/cert-manager
# Rendered from templates/cert-manager-values.yaml.tpl via apply.sh

crds:
  enabled: true

replicaCount: 1

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

webhook:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi
  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

cainjector:
  resources:
    requests:
      cpu: 20m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

nodeSelector:
  kubernetes.io/hostname: ${CONTROL_PLANE_NODE}
