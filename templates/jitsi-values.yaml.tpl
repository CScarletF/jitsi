publicURL: "https://${DOMAIN}"
turnHost: "${PUBLIC_IP}"
enableRecording: ${ENABLE_RECORDING}
fileRecordingsEnabled: ${ENABLE_RECORDING}

enableAuth: ${ENABLE_AUTH}
enableGuests: ${ENABLE_GUESTS}

xmpp:
  domain: ${XMPP_DOMAIN}
  authDomain: ${XMPP_AUTH_DOMAIN}
  mucDomain: ${XMPP_MUC_DOMAIN}
  internalMucDomain: ${XMPP_INTERNAL_MUC_DOMAIN}
  guestDomain: ${XMPP_GUEST_DOMAIN}

# ==============================================================================
# Web
# ==============================================================================
web:
  replicaCount: 1

  service:
    type: ClusterIP
    port: 80

  httpsEnabled: false
  httpRedirect: false

  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      cert-manager.io/cluster-issuer: "${CERT_ISSUER}"
    hosts:
      - host: ${DOMAIN}
        paths:
          - /
    tls:
      - secretName: jitsi-tls
        hosts:
          - ${DOMAIN}

  extraEnvs:
    ENABLE_XMPP_WEBSOCKET: "1"
    ENABLE_COLIBRI_WEBSOCKET: "1"
    COLIBRI_WEBSOCKET_REGEX: ".*"
    JVB_PREFER_SCTP: "false"
    ENABLE_RECORDING: "1"
    ENABLE_FILE_RECORDINGS_SERVICE: "1"
    ENABLE_LOCAL_RECORDING_NOTIFY_ALL_PARTICIPANTS: "false"
    ENABLE_LOCAL_RECORDING: "false"
    JIBRI_BASE_URL: "http://jitsi-jitsi-meet-web.jitsi.svc.cluster.local"
    ENABLE_PREJOIN_PAGE: "true"

  securityContext:
    capabilities:
      add:
        - SYS_ADMIN

  extraVolumes:
    - name: watermark
      configMap:
        name: jitsi-watermark
  extraVolumeMounts:
    - name: watermark
      mountPath: /usr/share/jitsi-meet/images/watermark.svg
      subPath: watermark.svg

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

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

  custom:
    configs:
      _custom_config_js: |
        config.fileRecordingsEnabled = true;
        config.liveStreamingEnabled = false;
        config.hiddenDomain = "${XMPP_HIDDEN_DOMAIN}";
        config.disableP2P = true;
        config.prejoinPageEnabled = true;

# ==============================================================================
# Prosody
# ==============================================================================
prosody:
  persistence:
    enabled: true
    size: ${PROSODY_STORAGE_SIZE}

  extraEnvs:
    ENABLE_AUTH: "0"

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

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

# ==============================================================================
# Jicofo
# ==============================================================================
jicofo:
  xmpp:
    password: "${JICOFO_PASSWORD}"

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

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

# ==============================================================================
# JVB (JVB-1 — always running, never scaled to zero)
# ==============================================================================
jvb:
  replicaCount: 1
  UDPPort: ${JVB1_UDP_PORT}
  image:
    tag: ${JITSI_IMAGE_TAG}

  service:
    enabled: true
    type: LoadBalancer
    loadBalancerIP: ${METALLB_VIP}
    externalTrafficPolicy: Cluster
    annotations:
      metallb.io/allow-shared-ip: "jitsi-shared"
    nodePort: ${JVB1_UDP_PORT}
    extraPorts:
      - name: colibri-ws
        port: 9090
        targetPort: 9090
        protocol: TCP

  publicIPs:
    - ${PUBLIC_IP}

  useNodeIP: false
  stunServers: ""
  useInternalStun: false

  xmpp:
    password: "${JVB_PASSWORD}"

  extraEnvs:
    JVB_ENABLE_APIS: "rest,colibri"
    JVB_ENABLE_COLIBRI_WS: "1"
    JVB_WS_SERVER_ID: "${DOMAIN}"
    JVB_WS_DOMAIN: "${DOMAIN}"

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

  resources:
    requests:
      cpu: 300m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

# ==============================================================================
# Coturn (STUN/TURN — UDP/3478)
# ==============================================================================
coturn:
  enabled: true

  replicaCount: 1

  staticAuth:
    secret: "${TURN_SECRET}"

  turn:
    transport: "udp"

  turns:
    enabled: false

  service:
    type: LoadBalancer
    annotations:
      metallb.io/allow-shared-ip: "jitsi-shared"
    ports:
      turn: ${TURN_PORT}
      turns: 443

  allowedPeerIPs:
    - "10.244.0.0-10.244.255.255"

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

  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 500m
      memory: 128Mi

# ==============================================================================
# WebSockets
# ==============================================================================
websockets:
  colibri:
    enabled: true
  xmpp:
    enabled: true

# ==============================================================================
# Jibri (recording)
# ==============================================================================
jibri:
  enabled: true
  replicaCount: ${JIBRI_REPLICA_COUNT}

  singleUseMode: true

  xmpp:
    password: "${JIBRI_XMPP_PASSWORD}"

  recorder:
    password: "${JIBRI_RECORDER_PASSWORD}"

  brewery:
    muc: "${JIBRI_BREWERY_MUC}"

  persistence:
    enabled: true
    existingClaim: "jibri-recordings-pvc"
    mountPath: /data

  nodeSelector:
    kubernetes.io/hostname: ${WORKER_NODE}

  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                  - ${WORKER_NODE}

  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 3Gi

  extraVolumes:
    - name: dev-shm
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi

  extraVolumeMounts:
    - name: dev-shm
      mountPath: /dev/shm

  hostAliases:
    - ip: "${METALLB_VIP}"
      hostnames:
        - "${DOMAIN}"
