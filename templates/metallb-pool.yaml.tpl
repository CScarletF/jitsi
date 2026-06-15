apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: jitsi-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_VIP}/32
  autoAssign: true
  avoidBuggyIPs: false
