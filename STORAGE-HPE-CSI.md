# Storage for TokenFactory: HPE CSI Driver + Alletra Storage MP X10000 (NFSv4.1)

The Etisalat cluster has no storage of its own. Persistent volumes come from the **HPE Alletra Storage MP X10000** over **NFSv4.1**, through the **HPE CSI Driver for Kubernetes 3.2.0** and its X10000 NFS Container Storage Provider (CSP). HPE's references (sent by HPE, read for this guide):
- Helm chart: https://artifacthub.io/packages/helm/hpe-storage/hpe-csi-driver/3.2.0
- Compatibility matrix: https://scod.hpedev.io/csi_driver/index.html#hpe_csi_driver_for_kubernetes_320
- Release notes: https://github.com/hpe-storage/csi-driver/blob/master/release-notes/v3.2.0.md
- X10000 CSI guide: https://scod.hpedev.io/csi_driver/container_storage_provider/hpe_alletra_storage_mp_x10000/index.html

The CSI driver is only the connector inside Kubernetes. It creates NFS exports on the X10000, so **the X10000 (platform OS >= 2.0.0.0, NFS enabled) must exist and be reachable**.

Everything in this guide is done by `airgap/deploy-all.sh` (phase `storage`) once `config.env` is filled. The manual commands are shown so you can follow or debug each step.

## 1. Compatibility (checked)
| | Required (CSI 3.2.0) | Etisalat cluster |
|---|---|---|
| Kubernetes | 1.33 - 1.36 | v1.35.6 |
| Worker OS | Ubuntu 18.04 / 20.04 / 22.04 / 24.04 | Ubuntu 24.04.5 |
| CPU | AMD64 / ARM64 | AMD64 |
| Storage | Alletra Storage MP X10000 OS **2.0.0.0** (NFS) | confirm with the storage team |
| Data protocol / filesystem | NFSv4.1 | |
| Helm | >= 3.2 | in `bundle/tools/helm` |
HPE now lists 3.3.1 as the latest (Kubernetes 1.34 - 1.37). This package uses 3.2.0, the version HPE referenced; 3.3.x is a later option.

## 2. What the storage team must provide (X10000 side)
Send them this list. Nothing in Kubernetes works without it.
1. The X10000 runs platform OS **>= 2.0.0.0** with the **NFS file service enabled**, and the **frontend data IP range** is provisioned (CSP guide, "Platform Requirements").
2. **Management address** (IP or FQDN, HTTPS 443) -> `X10000_MGMT`.
3. A **CSP API client**, created by an admin on the X10000 CLI. The admin runs (password typed silently, then removed):
   ```
   read -p "Paste the client secret: " -s MY_PASSWORD
   cat << EOF > /tmp/extoauthclient.yaml
   apiVersion: sc.hpe.com/v1
   kind: ExtOAuthClient
   metadata:
     name: hpe-csi-driver
     namespace: cm
   spec:
     client_name: csp
     client_secret: "${MY_PASSWORD}"
     groups:
       - ext:file-provisioner
   EOF
   glsctl create extoauthclient -f /tmp/extoauthclient.yaml
   rm -f /tmp/extoauthclient.yaml
   glsctl describe extoauthclient hpe-csi-driver | grep hf_client_id | awk -F= '{print $2}'
   ```
   The secret must contain a number, an upper-case letter and a special character, at least 8 characters. The command prints the **client ID** -> `X10000_CLIENT_ID`. The **secret** is given to you separately and is never written in a file (step 6).
4. **Capacity** for the volumes (section 5) and the quota/pool they come from.
5. NFS exports may be mounted by the 4 workers `172.22.100.24 - 172.22.100.27` (this is the StorageClass `accessControlList`, `X10000_ACL`).
6. Confirm whether the CSP can **expand volumes** (the HPE example StorageClass has `allowVolumeExpansion: false`). Default here: `false`.
7. IPv6 is not supported by the CSI driver/CSP on the X10000: use IPv4 data addresses.

## 3. Network and node prerequisites
| What | Detail |
|---|---|
| Firewall: workers -> X10000 management | `tcp/443` (the CSP pod talks to the platform API) |
| Firewall: workers -> X10000 data IPs | `tcp/2049` (NFSv4.1) |
| NFS client on every worker | `nfs-common` (Ubuntu). The chart's own package installation is turned off (no package mirror in the air-gap) |
| `/etc/hpe-storage` | must survive reboots/upgrades (not an ephemeral node) |
| CNI | the CSI node driver uses host networking; HPE recommends Calico, some CNIs (e.g. Flannel on K3s) are flaky |
| VolumeSnapshot CRDs | `snapshot.storage.k8s.io` CRDs should exist (the snapshotter sidecar needs them) |
Check and prepare, from the install VM (replace the user):
```
export KUBECONFIG=~/etisalat.kubeconfig; export PATH=~/etisalat/bundle/tools:$PATH
kubectl get crd | grep snapshot.storage.k8s.io          # volumesnapshots, volumesnapshotclasses, volumesnapshotcontents
for ip in 172.22.100.24 172.22.100.25 172.22.100.26 172.22.100.27; do
  ssh <ssh-user>@$ip 'dpkg -s nfs-common >/dev/null 2>&1 && echo "$(hostname): nfs-common ok" || echo "$(hostname): nfs-common MISSING"'
done
```
If `nfs-common` is missing and the workers have no package mirror, copy the `.deb` files (`nfs-common` and its dependencies for Ubuntu 24.04) onto each worker and run `sudo dpkg -i *.deb`.
From a worker, once the storage team gave you the IPs:
```
nc -zv <X10000-management-IP> 443
nc -zv <X10000-data-IP> 2049
```
Both must say `succeeded`.
If the VolumeSnapshot CRDs are missing, apply the upstream external-snapshotter CRDs from a machine with internet and copy them in (they are not part of the HPE chart).

## 4. Air-gap content (already in the bundle)
`airgap/images.txt` lists the 11 images the chart needs when only the X10000 CSP is enabled (verified by rendering the chart): `hpestorage/csi-driver:v3.2.0`, `alletrastoragemp-x10000-nfs-csp:v1.0.0`, `csi-extensions:v1.2.11`, `volume-mutator:v1.3.10`, `volume-group-provisioner:v1.0.10`, `volume-group-snapshotter:v1.0.10`, and `sig-storage/` `csi-attacher:v4.12.0`, `csi-node-driver-registrar:v2.17.0`, `csi-provisioner:v6.2.0`, `csi-resizer:v2.1.0`, `csi-snapshotter:v8.5.0`. The chart is `bundle/charts/hpe-csi-driver-3.2.0.tgz`. They are built by `airgap/01-bundle-connected.sh` and loaded onto the nodes by the `images` phase, like every other image. Check:
```
ls bundle/charts/hpe-csi-driver-3.2.0.tgz && ls bundle/tars | grep -c -E 'hpestorage|sig-storage'          # 11
```
This package uses the **tar mode** (images loaded on the nodes). The HPE chart does not set image pull secrets, so the registry mode (`IMAGE_MODE=registry` with a private registry) needs extra work for the `hpe-storage` namespace.

## 5. What TokenFactory needs from the storage
All PVCs use the one StorageClass `STORAGE_CLASS` (default name `hpe-standard-file`). Approximate need, from the chart values (grow-room not included):
| Volume | Size | Note |
|---|---|---|
| Postgres `pgdb` (Zalando, 3 instances) | 3 x 20Gi (`PG_VOLUME_SIZE`) | RWO |
| ClickHouse (OpenMeter) | 50Gi data + 5Gi log (`CH_DATA_SIZE`, `CH_LOG_SIZE`) | RWO |
| Redis (tokenfactory) | 10Gi | RWO |
| MinIO | 10Gi | RWO |
| Kafka (OpenMeter, 3 pods) | a few 10 Gi each (see `values/openmeter.values.yaml.tmpl`) | RWO |
| other small PVCs | 2Gi each | |
Plan roughly **250 GiB usable** plus headroom. Raise it before production if retention is long.

**Points to agree with the storage team (NFS has limits):**
1. **Databases on NFS.** Postgres (Patroni) and ClickHouse on NFS are not the usual recommendation (latency, fsync behaviour). If the storage team can also offer block storage or local disks for Postgres, use it (set a second class for `pgdb`). If everything stays on the X10000, check latency and use `hard`/`vers=4.1` mounts as configured here.
2. **Kafka on NFS.** The TokenFactory repo has an incident runbook (`openmeter-kafka-nfs-quorum-recovery`): a degraded node with Kafka KRaft on NFS stalled OpenMeter ingest. A healthy, fast NFS service avoids it.
3. **Volume expansion.** Off by default (`X10000_ALLOW_EXPANSION="false"`); the CSP guide documents dynamic provisioning only (no snapshots or clones). Size volumes generously, or get the vendor's confirmation before turning expansion on.
4. **Reclaim policy.** The StorageClass uses `Retain`: deleting a PVC keeps the export and its data until an admin removes it. Safer for databases; clean up unused exports by hand.

## 6. Install it (one command, or step by step)
Fill `config.env` (Part B5 of `DEPLOY.md`):
```
export STORAGE_BACKEND="hpe-x10000"
export STORAGE_CLASS="hpe-standard-file"
export X10000_MGMT="<management IP or FQDN>"
export X10000_CLIENT_ID="<client id from step 2.3>"
export X10000_ACL="172.22.100.24,172.22.100.25,172.22.100.26,172.22.100.27"
export X10000_ALLOW_EXPANSION="false"
```
Give the secret in your shell only (it is not stored anywhere):
```
read -rs X10000_CLIENT_SECRET; export X10000_CLIENT_SECRET
```
Then the full deployment (`deploy-all.sh all`) creates the storage in phase `storage` (after the images are loaded, before Postgres), or run just the storage part now:
```
cd ~/etisalat
airgap/deploy-all.sh dry-run                       # must end with "dry-run PASSED"
airgap/deploy-all.sh check prepare render ns images storage
```
What the `storage` phase does (the manual equivalent):
```
helm upgrade --install hpe-csi bundle/charts/hpe-csi-driver-3.2.0.tgz -n hpe-storage -f rendered/hpe-csi.yaml --wait --timeout 10m
kubectl -n hpe-storage create secret generic hpe-backend \
  --from-literal=serviceName=alletrastoragemp-x10000-nfs-csp-svc --from-literal=servicePort=8080 \
  --from-literal=backend="<management IP>:443" --from-literal=username="$X10000_CLIENT_ID" --from-literal=password="$X10000_CLIENT_SECRET"
kubectl apply -f rendered/storageclass-hpe-x10000.yaml
```
`rendered/hpe-csi.yaml` enables only the X10000 NFS CSP, turns off the automatic package installation, and points every image at the bundled names. `rendered/storageclass-hpe-x10000.yaml` is the StorageClass: provisioner `csi.hpe.com`, `accessProtocol: nfs`, your `accessControlList`, mount option `vers=4.1` (mandatory: NFS negotiation fails without it), `reclaimPolicy: Retain`, `volumeBindingMode: Immediate`.

## 7. Verify (do this before deploying TokenFactory)
```
kubectl -n hpe-storage get pods                      # hpe-csi-controller, hpe-csi-node (one per node), alletrastoragemp-x10000-nfs-csp: all Running
kubectl get csidriver csi.hpe.com
kubectl get sc hpe-standard-file
```
A real test volume and a pod that writes to it:
```
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: x10000-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: hpe-standard-file
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: x10000-test, namespace: default }
spec:
  containers:
  - name: t
    image: registry.etisalat.local/busybox:1.37.0
    command: ["sh","-c","echo ok > /data/f && cat /data/f && sleep 3600"]
    volumeMounts: [{ name: d, mountPath: /data }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: x10000-test } }]
EOF
kubectl -n default get pvc x10000-test                # Bound within ~1 minute
kubectl -n default logs x10000-test                   # prints: ok
kubectl -n default exec x10000-test -- mount | grep /data     # type nfs4, vers=4.1
kubectl -n default delete pod,pvc x10000-test
```
With `reclaimPolicy: Retain` the test export stays on the X10000 after the PVC is deleted: ask the storage admin to remove it, or delete the leftover `PersistentVolume` (`kubectl get pv`).

## 8. Troubleshooting
| You see | Check |
|---|---|
| PVC stays `Pending` | `kubectl -n hpe-storage logs deploy/alletrastoragemp-x10000-nfs-csp` and `kubectl describe pvc <name>`: wrong client ID/secret, management address unreachable (`nc -zv <ip> 443`), or the ExtOAuthClient lacks group `ext:file-provisioner` |
| Pod stuck `ContainerCreating`, mount error | `nfs-common` missing on that worker, `tcp/2049` blocked to the data IP, the worker is not in `accessControlList`, or `vers=4.1` is missing from the StorageClass |
| `hpe-csi-node` pod not starting | `kubectl -n hpe-storage logs ds/hpe-csi-node -c hpe-csi-driver`; CNI/host-networking problem (see section 3) |
| `ErrImagePull` in `hpe-storage` | an image tar is missing on that node: `airgap/deploy-all.sh images`, then delete the pod |
| `storage` phase: `X10000_CLIENT_SECRET: run first` | `read -rs X10000_CLIENT_SECRET; export X10000_CLIENT_SECRET`, then run the phase again |
| Need to change the secret later | re-run the phase with the new `X10000_CLIENT_SECRET` (it re-applies the Secret `hpe-backend`) |
| Remove it all | delete the PVCs first, then `helm -n hpe-storage uninstall hpe-csi`; the CRDs stay on purpose (HPE chart behaviour) |

Status: the chart rendering and the images were verified offline (`airgap/deploy-all.sh dry-run` passes). It has not been run against an X10000 yet: report the first failing step with its output.
