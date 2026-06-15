apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jitsi-colibri-ws
  namespace: jitsi
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # configuration-snippet is required here instead of proxy-set-headers
    # because nginx variables ($host, $http_upgrade, $scheme) are not
    # interpolated when read from a ConfigMap — they arrive as literal strings.
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header X-Forwarded-Proto $scheme;
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /colibri-ws
            pathType: Prefix
            backend:
              service:
                name: jitsi-jitsi-meet-jvb
                port:
                  number: 9090
  tls:
    - hosts:
        - ${DOMAIN}
      secretName: jitsi-tls
