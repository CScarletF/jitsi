# KEDA Helm values
# Chart: kedacore/keda
# Rendered from templates/keda-values.yaml.tpl via apply.sh

# ==============================================================================
# Operator
# ==============================================================================
operator:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

# ==============================================================================
# Metrics API server
# ==============================================================================
metricsServer:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

# ==============================================================================
# Webhooks
# ==============================================================================
webhooks:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}
