# JVB-2 — Jitsi Videobridge second instance
#
# Managed independently of Helm. KEDA scales this 0→1 based on JVB-1 load.
# JVB-1 (Helm-managed) is always running. JVB-2 scales up when JVB-1 CPU ≥ 60%
# and scales down only when JVB-1 CPU < 60% AND JVB-2 active conferences = 0.
#
# Prerequisites before applying:
#   - KEDA installed: helm install keda kedacore/keda -n keda --create-namespace
#   - Prometheus installed and scraping (serviceMonitorSelectorNilUsesHelmValues: false)
#   - jitsi-jitsi-meet-jvb-secret exists in jitsi namespace
#
# Apply via apply.sh:
#   bash apply.sh jvb2
#
# Verify:
#   kubectl get scaledobject -n jitsi
#   kubectl get deployment jvb-2 -n jitsi
#   kubectl describe scaledobject jvb-2-scaledobject -n jitsi

# ==============================================================================
# ConfigMap — JVB-2 environment
# ==============================================================================
apiVersion: v1
kind: ConfigMap
metadata:
  name: jvb-2-config
  namespace: jitsi
data:
  JVB_WS_SERVER_ID: "${DOMAIN}"
  JVB_WS_DOMAIN: "${DOMAIN}"
  JVB_ENABLE_APIS: "rest,colibri"
  JVB_ENABLE_COLIBRI_WS: "1"
  ENABLE_COLIBRI_WEBSOCKET: "true"
  ENABLE_COLIBRI_WEBSOCKET_UNSAFE_REGEX: "1"
  # XMPP connection — must match prosody and jicofo config
  XMPP_SERVER: "jitsi-jitsi-meet-prosody.jitsi.svc.cluster.local"
  XMPP_DOMAIN: "${XMPP_DOMAIN}"
  XMPP_AUTH_DOMAIN: "${XMPP_AUTH_DOMAIN}"
  XMPP_INTERNAL_MUC_DOMAIN: "${XMPP_INTERNAL_MUC_DOMAIN}"
  JVB_BREWERY_MUC: "jvbbrewery"
  # Public IP advertised to clients — same as JVB-1
  JVB_ADVERTISE_IPS: "${PUBLIC_IP}"
  # UDP port — must be unique per JVB instance (JVB-1 uses JVB1_UDP_PORT)
  JVB_PORT: "${JVB2_UDP_PORT}"
  # Colibri REST enabled for KEDA metrics polling
  COLIBRI_REST_ENABLED: "true"
  TZ: "Asia/Jakarta"

---
# ==============================================================================
# Deployment
# ==============================================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jvb-2
  namespace: jitsi
  labels:
    app: jvb-2
    app.kubernetes.io/component: jvb
    app.kubernetes.io/part-of: jitsi-meet
spec:
  # Replica count managed by KEDA ScaledObject below.
  # Do not set replicas here — KEDA owns this field.
  selector:
    matchLabels:
      app: jvb-2
  template:
    metadata:
      labels:
        app: jvb-2
        app.kubernetes.io/component: jvb
        app.kubernetes.io/part-of: jitsi-meet
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9888"
        prometheus.io/path: "/metrics"
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 50
              preference:
                matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - ${CONTROL_PLANE_NODE}
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/component
                      operator: In
                      values:
                        - jvb
                topologyKey: kubernetes.io/hostname

      containers:
        - name: jvb
          image: jitsi/jvb:stable-10888
          envFrom:
            - configMapRef:
                name: jvb-2-config
          env:
            - name: JVB_AUTH_USER
              valueFrom:
                secretKeyRef:
                  name: jitsi-jitsi-meet-jvb-secret
                  key: JVB_AUTH_USER
            - name: JVB_AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jitsi-jitsi-meet-jvb-secret
                  key: JVB_AUTH_PASSWORD
          ports:
            - name: rtp-udp
              containerPort: ${JVB2_UDP_PORT}
              protocol: UDP
            - name: colibri-ws
              containerPort: 9090
              protocol: TCP
            - name: rest-api
              containerPort: 8080
              protocol: TCP

          livenessProbe:
            httpGet:
              path: /about/health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /about/health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 3

          resources:
            requests:
              cpu: 300m
              memory: 512Mi
            limits:
              cpu: 2000m
              memory: 2Gi

        - name: metrics
          image: docker.io/systemli/prometheus-jitsi-meet-exporter:1.2.3
          args:
            - "-videobridge-url"
            - "http://localhost:8080/colibri/stats"
          ports:
            - name: metrics
              containerPort: 9888
              protocol: TCP
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 20m
              memory: 32Mi

---
# ==============================================================================
# Service — UDP media port (LoadBalancer, shared VIP via MetalLB)
# ==============================================================================
apiVersion: v1
kind: Service
metadata:
  name: jvb-2-udp
  namespace: jitsi
  labels:
    app: jvb-2
  annotations:
    metallb.io/allow-shared-ip: "jitsi-shared"
spec:
  type: LoadBalancer
  loadBalancerIP: ${METALLB_VIP}
  externalTrafficPolicy: Cluster
  selector:
    app: jvb-2
  ports:
    - name: rtp-udp
      port: ${JVB2_UDP_PORT}
      targetPort: ${JVB2_UDP_PORT}
      nodePort: ${JVB2_UDP_PORT}
      protocol: UDP

---
# ==============================================================================
# Service — internal ports (ClusterIP)
# ==============================================================================
apiVersion: v1
kind: Service
metadata:
  name: jvb-2-internal
  namespace: jitsi
  labels:
    app: jvb-2
spec:
  type: ClusterIP
  selector:
    app: jvb-2
  ports:
    - name: colibri-ws
      port: 9090
      targetPort: 9090
      protocol: TCP
    - name: rest-api
      port: 8080
      targetPort: 8080
      protocol: TCP
    - name: metrics
      port: 9888
      targetPort: 9888
      protocol: TCP

---
# ==============================================================================
# ServiceMonitor — Prometheus scrape config for JVB-2 metrics sidecar
# ==============================================================================
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: jvb-2-monitor
  namespace: jitsi
  labels:
    app: jvb-2
    release: prometheus
spec:
  selector:
    matchLabels:
      app: jvb-2
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics

---
# ==============================================================================
# ScaledObject — KEDA scaling logic for JVB-2
#
# Scale-up:  JVB-1 CPU utilization >= 60%
# Scale-down: JVB-1 CPU < 60% AND JVB-2 conferences = 0
#
# Formula: jvb1_cpu >= 60 ? 100 : jvb2_conferences * 100
# ==============================================================================
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: jvb-2-scaledobject
  namespace: jitsi
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: jvb-2

  minReplicaCount: 0
  maxReplicaCount: 1
  pollingInterval: 30
  cooldownPeriod: 300

  advanced:
    scalingModifiers:
      target: "1"
      metricType: "AverageValue"
      formula: "jvb1_cpu >= 60 ? 100 : jvb2_conferences * 100"

    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 60
          policies:
            - type: Pods
              value: 1
              periodSeconds: 60
        scaleDown:
          stabilizationWindowSeconds: 300
          policies:
            - type: Pods
              value: 1
              periodSeconds: 120

  triggers:
    - type: prometheus
      name: jvb1_cpu
      metadata:
        serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
        query: |
          rate(container_cpu_usage_seconds_total{
            namespace="jitsi",
            pod=~"jitsi-jitsi-meet-jvb-0-.*",
            container="jvb"
          }[2m]) * 100
        threshold: "60"

    - type: prometheus
      name: jvb2_conferences
      metadata:
        serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
        query: |
          jitsi_conferences{
            namespace="jitsi",
            pod=~"jvb-2-.*"
          }
        threshold: "1"
        ignoreNullValues: "true"
