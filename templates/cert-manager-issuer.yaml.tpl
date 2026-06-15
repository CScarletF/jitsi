# cert-manager ClusterIssuer — Let's Encrypt
#
# DO NOT APPLY until both of the following are confirmed:
#   1. DNS: ${DOMAIN} resolves to ${PUBLIC_IP}
#   2. NAT: router forwards TCP 80 from ${PUBLIC_IP} to ${METALLB_VIP}
#
# Apply with: kubectl apply -f manifests/cert-manager-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
            ingressTemplate:
              metadata:
                annotations:
                  nginx.ingress.kubernetes.io/ssl-redirect: "false"

---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
            ingressTemplate:
              metadata:
                annotations:
                  nginx.ingress.kubernetes.io/ssl-redirect: "false"
