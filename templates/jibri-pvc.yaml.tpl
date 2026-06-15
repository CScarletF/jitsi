# Jibri recordings — Longhorn-backed PersistentVolumeClaim
#
# Replaces the NFS-backed jibri-pv.yaml.
# Longhorn handles provisioning and replication automatically —
# no manual PV definition required.
#
# Replication is controlled by the storageClassName annotation:
#   numberOfReplicas: ${LONGHORN_REPLICAS}  (set in config.env)
#
# To migrate to external NAS or a different storage backend later:
#   - Create a new StorageClass pointing at the new backend
#   - Update the storageClassName below
#   - PVC name and Jibri config require no changes
#
# Apply: kubectl apply -f manifests/jibri-pvc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-jibri
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "${LONGHORN_REPLICAS}"
  dataLocality: "disabled"
  fromBackup: ""

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jibri-recordings-pvc
  namespace: jitsi
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-jibri
  resources:
    requests:
      storage: ${JIBRI_STORAGE_SIZE}
