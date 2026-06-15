# kube-prometheus-stack Helm values
# Rendered from templates/prometheus-values.yaml.tpl via apply.sh

kubeScheduler:
  enabled: false
kubeControllerManager:
  enabled: false
kubeProxy:
  enabled: false
kubeEtcd:
  enabled: false

prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    retention: ${PROMETHEUS_RETENTION}

    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: ${PROMETHEUS_STORAGE_SIZE}

    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi

    nodeSelector:
      kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

    affinity:
      nodeAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
                - key: kubernetes.io/hostname
                  operator: In
                  values:
                    - ${CONTROL_PLANE_NODE}

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi

    resources:
      requests:
        cpu: 20m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi

    nodeSelector:
      kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

grafana:
  adminPassword: "${GRAFANA_PASSWORD}"

  persistence:
    enabled: true
    storageClassName: local-path
    accessModes:
      - ReadWriteOnce
    size: 2Gi

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

  ingress:
    enabled: false
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      cert-manager.io/cluster-issuer: "${CERT_ISSUER}"
    hosts:
      - ${DOMAIN}
    path: /grafana
    tls:
      - secretName: grafana-tls
        hosts:
          - ${DOMAIN}

prometheusOperator:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}

nodeExporter:
  enabled: true

prometheus-node-exporter:
  service:
    port: 9101
    targetPort: 9101

  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

kube-state-metrics:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

  nodeSelector:
    kubernetes.io/hostname: ${CONTROL_PLANE_NODE}
