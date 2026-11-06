# TokenFactory – Etisalat air-gap deployment (ONE document, follow top to bottom)

No internet and **no registry** inside the air-gap: every image is a `.tar` file that gets loaded straight into each node.
Three places are involved (in the lab, `[VM]` = the Azure jumphost). Every step below says where to run it:

| Tag | Where |
|---|---|
| **[MAC]** | your laptop WITH internet (builds the bundle) |
| **[VM]** | the dedicated Etisalat **install VM** inside the air-gap (there is no jumphost). It must reach the cluster API and the nodes. *Lab only: this role is played by the Azure jumphost `azureuser@10.40.1.4`* |
| **[CLUSTER]** | the AKS lab `aks-etisalat-test` (real Etisalat: their cluster) |

What gets installed (HA), laid out like `tokenfactory-prod`: namespace **`tokenfactory`** = all tf-* services, Keycloak (3 replicas), the Ingress (portal/admin/www/auth), Envoy AI Gateway (api, ≥ 6 pods, no CPU/RAM limits) and the Postgres cluster `pgdb` (Zalando, 3 instances, external for the app); namespace **`postgres`** = the Zalando operator only; namespace **`openmeter`** = OpenMeter (uses `pgdb`).
Lab note: a 1-node cluster cannot hold 3 Postgres instances, so the lab uses `SINGLE_NODE=yes` (1 instance). Everything else is identical.

---
## STEP 0 — Things you need before starting
1. A **GitHub token (PAT) with `read:packages`** that can read `ghcr.io/infinia-technology/*` (the tf-* images are private). The token saved on your Mac is invalid.
2. Two image tags: `TF_TAG` (release `0.17.2` = `0.17.2-356be61`) and `BRAND_TAG` (the **Etisalat-branded** web images, looks like `0.17.2-etisalat-abc1234`; it MUST end in a 7-character git sha). Step A3 finds them. *If no `-etisalat-` tag exists, the images were never built — ask the developer to run the Etisalat brand build first; nothing can be deployed without them.*
3. Lab only: the cluster exists (`~/etisalat.kubeconfig` on the install VM works: `kubectl --kubeconfig ~/etisalat.kubeconfig get nodes` shows 1 Ready node).

---
## PART A — [MAC] build the bundle (needs internet)

**A1. Tools**
```
brew install skopeo helm
```
**A2. Log in** (Docker Hub avoids rate limits; ghcr needs your PAT as the password)
```
skopeo login docker.io
skopeo login ghcr.io -u <your-github-username>
```
**A3. Find the tags** (replace nothing, just run)
```
skopeo list-tags docker://ghcr.io/infinia-technology/ai-gateway-platform/tf-portal-web | tr ',' '\n' | grep -E 'etisalat' | tail -5
skopeo inspect --no-tags docker://ghcr.io/infinia-technology/ai-gateway-platform/tf-accounts:0.17.2-356be61 >/dev/null && echo "TF_TAG ok"
```
**A4. Edit `~/Downloads/ethisalat/config.env`** — only these two lines now:
```
export TF_TAG="0.17.2-356be61"
export BRAND_TAG="<the etisalat tag from A3>"
```
**A5. Build the bundle** (≈ 8–10 GB, 30–60 min, safe to re-run if it stops)
```
cd ~/Downloads/ethisalat
airgap/01-bundle-connected.sh
```
It ends with `== done. total size:` and `image tars: 37 of 38`. **The one missing tar is MinIO** — its public images were removed from Docker Hub and quay.io (that is why the script prints one `FAILED images` entry). It is created in step A7. Anything else listed as FAILED is a real error: fix it and re-run A5 (finished images are skipped).
Result: `bundle/tars/*.tar`, `bundle/charts`, `bundle/crds`, `bundle/jars` (the Keycloak plugin jar, see B4), `bundle/tools/helm` and `bundle/tools/kubectl` (Linux binaries for the air-gap side).

**A6. Copy everything to the install VM** (resumable). First time as written; when you copy again later add `--exclude config.env` so your filled-in file on the VM is not overwritten
```
rsync -avP --exclude .git --exclude E-_TokenFactory ~/Downloads/ethisalat/ <vm-user>@<VM-IP>:~/etisalat/
# lab: rsync -avP --exclude .git --exclude E-_TokenFactory -e "ssh -i ~/.ssh/id_rsa_jumphost" ~/Downloads/ethisalat/ azureuser@10.40.1.4:~/etisalat/
# no network path Mac -> VM (real air-gap)? copy the folder on a USB disk / approved transfer, then `tar -xf` it as ~/etisalat on the VM
```
**A7. [VM] Create the MinIO tar** (the only image the Mac cannot fetch). The VM can reach the ACR `acrtokenfactory` that still holds it; the script talks to the ACR REST API, no docker/skopeo needed:
```
ssh <vm-user>@<VM-IP>          # lab: ssh -i ~/.ssh/id_rsa_jumphost azureuser@10.40.1.4
cd ~/etisalat && airgap/fetch-minio-from-acr.sh      # ends with: wrote .../minio_minio_RELEASE.2025-09-07T16-13-09Z.tar
ls bundle/tars/*.tar | wc -l                          # must print 38
```
(Real Etisalat: they have no ACR — run this on any host that can reach a registry holding `minio/minio:RELEASE.2025-09-07T16-13-09Z` (edit `MINIO_ACR`), or `docker save` the image on a connected host, and drop the file at that path with the image name `registry.etisalat.local/minio/minio:RELEASE.2025-09-07T16-13-09Z`.)

---
## PART B — [VM] deploy

**B1. Log in**
```
ssh <vm-user>@<VM-IP>          # lab: ssh -i ~/.ssh/id_rsa_jumphost azureuser@10.40.1.4
cd ~/etisalat
export VM_IP=<this VM's IP as the cluster nodes see it>      # lab: 10.40.1.4
```
**B2. Check prerequisites.** Nothing has to be installed on this machine: `kubectl` and `helm` come inside the bundle (`bundle/tools/`, the scripts put them on PATH automatically). The only other things needed are standard on every Ubuntu/RHEL server: `bash perl python3 openssl tar`. Verify:
```
ls ~/etisalat.kubeconfig && ~/etisalat/bundle/tools/kubectl --kubeconfig ~/etisalat.kubeconfig get nodes
for t in perl python3 openssl tar; do command -v $t >/dev/null && echo "ok $t" || echo "MISSING $t"; done
ls ai-gateway-platform/helm/tokenfactory/templates/ingress.yaml bundle/tars/INDEX bundle/tools/helm bundle/tools/kubectl bundle/jars/*.jar
```
If a tool really is missing on a brand-new VM, install it from the OS media/package mirror of that VM (only `perl`/`python3`/`openssl` are ever needed). `make`, `envsubst` and `skopeo` are NOT needed in the air-gap.
(Lab only, if the kubeconfig is missing: `az aks get-credentials -g rg-tokenfactory -n aks-etisalat-test --admin --file ~/etisalat.kubeconfig`.)

**B3. TLS certificate.** Lab: make a self-signed wildcard. Real Etisalat: use their cert and key files instead.
```
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout ~/wild.key -out ~/wild.crt -subj "/CN=*.etisalat.lab" -addext "subjectAltName=DNS:*.etisalat.lab,DNS:etisalat.lab"
```
**B4. Keycloak plugin jar — nothing to download, it is inside the bundle.**
* **What it is:** `keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar` (Maven Central, `mesutpiskin`) — **exactly the jar tokenfactory-prod and the Xailon PR #678 use**, and it **is valid for Etisalat**: it matches the Keycloak 26.7 line, the Keycloak image in this bundle is **26.7.5** (Xailon runs the same jar on 26.7.4). `tf-auth` needs it (it wires the email-OTP step and refuses to start without it). We do not build it.
* **Where it comes from:** step A5 downloads it on the Mac into `bundle/jars/`; the whole `bundle/` folder reaches the VM with A6. It is **not in the git repo** (the repo has no `bundle/`).
* **Check it on the VM** (size 90807 bytes):
  ```
  cd ~/etisalat/bundle/jars && ls -l *.jar && sha256sum *.jar
  # 8b478b84e0ab1e812f7d512c648f37ef9fbb9154343be373e7127fcfa0c9d3ba  keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar
  ```
  If the folder is empty (the download in A5 failed), open this URL on any machine with internet and put the file into `bundle/jars/`:
  `https://repo1.maven.org/maven2/io/github/mesutpiskin/keycloak-2fa-email-authenticator/26.5.0-KC26.7.3/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar`
  Without the jar `airgap/deploy-all.sh check` stops with *"no Keycloak jar in …/jars"*.
* **How Keycloak gets it in the air-gap:** `KEYCLOAK_JAR_URL` is **empty** in `config.env` (leave it empty; the Maven Central URL only works with internet). Phase `jar` of B7 puts the file into ConfigMap `keycloak-spi-jar` and serves it with **2 tiny busybox `httpd` pods behind Service `keycloak-spi`** in namespace `tokenfactory`. Every Keycloak pod (all 3 of the HA set) downloads it from there in its init container `fetch-providers` when it starts.
* **HA behaviour:** two jar pods, so one can fail. Running Keycloak pods are never affected. Only if **both** jar pods are down *and* a Keycloak pod restarts at that moment, that pod waits (`Init`) until a jar pod is back.
* **Your own server instead:** put its URL in `KEYCLOAK_JAR_URL` (it must serve that same file and be reachable from inside a pod); the `jar` phase then does nothing.
* **After B7** confirm: `kubectl -n tokenfactory get pods -l app.kubernetes.io/name=keycloak-spi` shows 2 pods Running (this in-cluster server has not yet been run on the real cluster — report it if not).

**B5. Edit `config.env`** (`nano config.env`). Set exactly these lines (everything else stays):
```
export KUBECONFIG_FILE="/home/azureuser/etisalat.kubeconfig"
export STORAGE_CLASS="managed-csi"
export SINGLE_NODE="yes"                      # lab only. Real Etisalat: "no"
export LB_INTERNAL="yes"                      # Azure only. Real Etisalat: "no"
export DOMAIN="etisalat.lab"
export TLS_CERT="/home/azureuser/wild.crt"
export TLS_KEY="/home/azureuser/wild.key"
export SMTP_HOST="smtp.etisalat.lab"          # lab: any name; mails will simply not be delivered
export SMTP_USER="lab"
```
`TF_TAG` / `BRAND_TAG` are already filled (copied from the Mac). Nothing may still say `REPLACE_`:
```
grep -n REPLACE_ config.env | grep -v '^[0-9]*:#' || echo "config.env complete"
```
**B6. Dry-run** — renders every chart offline, changes nothing on the cluster
```
airgap/deploy-all.sh dry-run
```
Must end with `dry-run PASSED`. If it stops with a FATAL line, fix what it says and re-run.

**B6b. Choose how the images reach the nodes** (set it in `config.env` **before** B7 — the `images` phase of B7 uses it):
| Where | Set in `config.env` | What happens |
|---|---|---|
| **Real Etisalat air-gap (use this)** | `export NODE_LOAD_MODE="ssh"`<br>`export NODES="user@node1 user@node2 user@node3"` | the VM copies the tars to each node with `scp` and runs `sudo ctr -n k8s.io images import` there. Needs **SSH from the install VM to every node + passwordless `sudo`**. **No container image is needed**, so it works with zero internet and zero registry |
| Real Etisalat, **no SSH to the nodes** | `export NODE_LOAD_MODE="ssh"` is not possible → load by hand | copy `bundle/tars/` to each node (USB / scp from anywhere) and on **every node** run: `cd <folder-with-tars> && for f in *.tar; do sudo ctr -n k8s.io images import --all-platforms $f; done`. Then run B7 **without** the `images` phase: `airgap/deploy-all.sh check prepare render ns pg secrets controllers ingress openmeter app verify` (everything except `images`) |
| AKS lab only | `export NODE_LOAD_MODE="pod"` (default) | a privileged helper pod does the import. It needs an image that is *already on the node* with `/bin/sh` + `chroot`; the lab got it from AKS's private MCR cache — a real air-gap would end in `ErrImagePull` |
Check on a node afterwards (any mode): `sudo ctr -n k8s.io images ls -q | grep -c registry.etisalat.local` must print **38** (the `images` phase also prints `ALL 38 IMAGES PRESENT` by itself in `ssh`/`pod` mode).

**B7. Deploy everything (one command)**
```
airgap/deploy-all.sh all 2>&1 | tee ~/etisalat-deploy.log
```
Order it runs, with what each prints: `check` → `prepare` → `render` → `ns` → **`images`** (loads all 38 tars into the node; ends with `ALL 38 IMAGES PRESENT`) → **`jar`** (hosts the Keycloak plugin jar in the cluster) → `pg` (Postgres, waits for Running) → `secrets` → `controllers` (Envoy) → `ingress` → `openmeter` (slowest, up to 60 min) → `app` → `verify`.
Total 40–90 min. If anything fails, fix the cause and continue where it stopped:
```
airgap/deploy-all.sh --from <phase>        # e.g. --from openmeter
```
Never delete `~/.etisalat-service-keys.env` (created by the `secrets` phase; every upgrade needs it).

**B8. Open the portal.** `verify` printed the ingress IP (portal/admin/www/auth) and the Envoy IP (api); lab values were `10.40.16.7` and `10.40.16.8`. The lab has no DNS, so test with `--resolve` (nothing to edit on the machine):
```
export KUBECONFIG=~/etisalat.kubeconfig
ING=$(kubectl -n nginx-ingress get svc nginx-ingress-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for h in www portal admin; do curl -sk -o /dev/null -w "$h %{http_code}\n" --resolve $h.etisalat.lab:443:$ING https://$h.etisalat.lab/; done      # 200 200 200
curl -sk --resolve auth.etisalat.lab:443:$ING https://auth.etisalat.lab/auth/realms/master/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
```
Admin login: user = `admin@etisalat.lab`, password:
```
kubectl -n tokenfactory get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d; echo
```
Real Etisalat: create DNS records instead (`api.<domain>` → Envoy IP, `portal. admin. www. auth.<domain>` → ingress IP).

**B9. Check it is healthy**
```
export KUBECONFIG=~/etisalat.kubeconfig
kubectl get pods -A | grep -v -E 'Running|Completed'          # nothing important should be listed
kubectl -n tokenfactory get postgresql pgdb          # Running
kubectl -n tokenfactory get sts keycloak             # READY 3/3
kubectl -n tokenfactory get ingress tokenfactory
```

**B10. Etisalat brand + feature gate** (the verification the developer's overlay asks for). The scripts are in the repo copy; they need `curl` and `python3`, and they read the release `tokenfactory` in namespace `tokenfactory`. The lab has no DNS, so first map the names on this VM (real Etisalat: DNS exists, skip these two lines):
```
echo "<INGRESS_IP> portal.etisalat.lab admin.etisalat.lab www.etisalat.lab auth.etisalat.lab" | sudo tee -a /etc/hosts      # lab: 10.40.16.7
echo "<ENVOY_IP>   api.etisalat.lab" | sudo tee -a /etc/hosts                                                             # lab: 10.40.16.8
```
then (replace `<domain>` by your `DOMAIN`):
```
export KUBECONFIG=~/etisalat.kubeconfig; export PATH=~/etisalat/bundle/tools:$PATH
cd ~/etisalat/ai-gateway-platform/test/e2e
KC=kubectl NS=tokenfactory PORTAL_URL=https://portal.<domain> ADMIN_URL=https://admin.<domain> \
  SITE_URL=https://www.<domain> DOCS_URL=https://www.<domain>/docs \
  EXPECT_PRODUCT='Token Factory by etisalat' EXPECT_FAVICON=favicon.png \
  EXPECT_THEME_POLICY=both EXPECT_DARK_TOKENS=yes EXPECT_SIGNUP=yes ./branding.sh
KC=kubectl NS=tokenfactory PORTAL_URL=https://portal.<domain> SITE_URL=https://www.<domain> ./features.sh
```
Expected: `branding.sh` passes (brand `etisalat`, product `Token Factory by etisalat`, Etisalat Keycloak theme, light+dark). `features.sh` must show **`auth.socialLogin` and `billing.topup` OFF** (HTTP 404 `feature_disabled`) and **`auth.signup` ON** — that is the Etisalat feature ceiling from the brand package, not a bug. With the lab's self-signed certificate the scripts' `curl` needs `-k`; if a check fails only for that reason, note it and move on. In the lab the `docs` check fails by design (`DOCS_WEB=no`, no Etisalat docs image).

---
## PART C — Real Etisalat (instead of the lab)
Same steps, only these differences:
* B3: use the real wildcard certificate; B5: `SINGLE_NODE="no"`, `LB_INTERNAL="no"`, real `DOMAIN`, `SMTP_*`, `STORAGE_CLASS`, nothing for the Keycloak jar (the installer hosts it in the cluster).
* Loading images: set in `config.env` **`export NODE_LOAD_MODE="ssh"`** and `export NODES="user@node1 user@node2 user@node3"` (the install VM must reach the nodes over SSH, the user needs passwordless `sudo`). This copies the tars with `scp` and runs `sudo ctr -n k8s.io images import` on each node — **no container image is needed**, so it works in a real air-gap.
  `pod` mode (the lab default) starts a helper pod and therefore needs an image that is *already on the node* and has `/bin/sh` + `chroot`. The lab got it from AKS's private MCR cache (`mcr.microsoft.com/azurelinux/busybox:1.36`); a real air-gap has no MCR/ACR, so the pod would sit in `ErrImagePull`. Use `pod` mode only if you set `LOADER_DEBUG_IMAGE` to an image that really exists on every node. No SSH to the nodes at all? Copy `bundle/tars` to each node by hand and run on it: `for f in *.tar; do sudo ctr -n k8s.io images import --all-platforms $f; done`.
* TLS for `api.` — the developer's overlay offers two options: **(a) terminate at the Envoy Gateway** (what this package does: wildcard secret `tf-etisalat-tls`, listener 8443 published on 443) or **(b) terminate at an external load balancer / CDN**: add `tf-gateway-resources: { tls: { enabled: false } }` to `values/umbrella.values.yaml.tmpl` (Envoy then serves plain HTTP on 8080 only) and skip `TLS_CERT/TLS_KEY` for the gateway. The web hosts (portal/admin/www/auth) are always terminated by the NGINX ingress with the same wildcard secret.
* Keycloak inside the cluster speaks HTTP and HTTPS (`keycloak.config.httpEnabled: true` in the developer's overlay). Flip it to `false` only after every caller is green on HTTPS (add `config: { httpEnabled: false }` under `keycloak:` in the template).
* Need ≥ 3 Ready nodes, a StorageClass with volume expansion, a LoadBalancer provider (two IPs: Envoy for `api.`, ingress for portal/admin/www/auth).

## PART D — Sizing and HA: all in `config.env` (section "SIZING & HA")
Layout is the same as `tokenfactory-prod`: **`tokenfactory`** = everything of TokenFactory incl. the Postgres cluster `pgdb`; **`postgres`** = Zalando operator only; **`openmeter`** = OpenMeter.
| What | `config.env` variable (default) |
|---|---|
| **Envoy** pods (all inference load; **no CPU/RAM requests or limits**, like prod; **minimum 6**) | `ENVOY_REPLICAS` (**6**), `ENVOY_PDB_MIN_AVAILABLE` (1) |
| **Keycloak HA** | `KEYCLOAK_REPLICAS` (**3**), `KEYCLOAK_MEM_REQUEST/LIMIT` (1Gi/8Gi), `KEYCLOAK_HEAP` (`-Xmx2g`) |
| **Postgres HA** (Zalando `pgdb`, external for the app) | `PG_INSTANCES` (**3**), `PG_VOLUME_SIZE` (20Gi), `PG_CPU_REQUEST/LIMIT` (1/4), `PG_MEM_REQUEST/LIMIT` (2Gi/8Gi), `PG_MAX_CONNECTIONS` (300) |
| tf-* replicas | `TF_REPLICAS` (3; `tf-ledger` always 1), `SITE_DOCS_REPLICAS` (1) |
| ClickHouse disk | `CH_DATA_SIZE`, `CH_LOG_SIZE` |
| Ingress on/off | `INGRESS_ENABLED` (true) |
| **anything else** (one service's CPU/RAM, annotations, SMTP SSL, …) | `CUSTOM_VALUES_YAML` (raw YAML, last section of `config.env`) |
The CPU/RAM of every tf-* pod is already the **tokenfactory-prod live value** (checked on the running prod cluster). To change one, use `CUSTOM_VALUES_YAML`, e.g. `tf-relay: { replicas: 4, resources: { requests: { cpu: 100m, memory: 512Mi } } }` — see `VALUES-GUIDE.md` §3. OpenMeter, NGINX-ingress and the Envoy controllers keep their own small files (`values/openmeter…`, `values/nginx-ingress…`, `values/envoy-gateway…`, `values/ai-gateway…`).
After editing `config.env`: `airgap/deploy-all.sh dry-run`, then `airgap/deploy-all.sh render ns app` (Postgres: `airgap/deploy-all.sh pg`).

## PART E — If something goes wrong
| You see | Do |
|---|---|
| `01-bundle-connected.sh` prints nothing and exits | old `env.sh` (a failing `[ -d tools ] && …` under `set -e`). Use the current scripts; test with `bash -x airgap/01-bundle-connected.sh \| head -30` |
| `01`: `unauthorized` from ghcr.io | `skopeo login ghcr.io -u <user>` with a PAT that has `read:packages` for Infinia-Technology. The token saved by Docker on the Mac was invalid |
| `01`: `Docker references with both a tag and digest are not supported` | old script. Current one strips the tag for `@sha256` images |
| `01`: `FAILED images … minio` | expected: MinIO's public images are gone. Do step A7 |
| `01`: `helm: cannot execute binary file` on the Mac | `bundle/tools/helm` is a Linux binary; current `env.sh` only puts it on PATH on Linux |
| `FATAL: missing tool: make` / `envsubst` / `skopeo` | old script versions. The current scripts need only `perl python3 openssl tar`; `kubectl` + `helm` come from `bundle/tools` |
| `FATAL: config.env still has REPLACE_` | fill that line |
| `check`: `no Keycloak jar in …/jars` | `bundle/jars/` is empty: download the jar (URL in B4) into it, or rebuild the bundle (A5) |
| `images` phase: `MISSING <image>` | the tar was not in the bundle → rebuild on the Mac (A5) and rsync again |
| pod `ErrImagePull` / `ImagePullBackOff` | the image is not on that node. Run `airgap/deploy-all.sh images`. For `@sha256` images (keycloak, busybox, openmeter) also check `kubectl describe pod` shows the exact reference |
| Keycloak not Ready / init `fetch-providers` fails | the jar server is not up: `kubectl -n tokenfactory get pods -l app.kubernetes.io/name=keycloak-spi` (2 pods Running) and `kubectl -n tokenfactory logs keycloak-0 -c fetch-providers`; fix and `airgap/deploy-all.sh jar`, then delete the Keycloak pod. With your own `KEYCLOAK_JAR_URL`: that URL must answer from inside a pod |
| `pg` phase stuck | `kubectl -n tokenfactory describe postgresql pgdb`; on a 1-node cluster SINGLE_NODE must be `yes` |
| `tf-accounts` stuck in `Init:ErrImagePull` on `tf-docs-web` | the docs image tar is missing on the node (its init container `legal-src` copies the legal pages out of it). `airgap/deploy-all.sh images`, then delete the pod |
| `tf-ledger` CrashLoop: `Dirty database version N` | a pod was killed in the middle of a DB migration. Lab-safe fix: undo that one migration and let it re-run, e.g. for 5: `kubectl -n tokenfactory exec pgdb-0 -c postgres -- psql -U postgres -d tokenfactory -c "BEGIN; DROP TABLE IF EXISTS tf_credit_grants; UPDATE tf_ledger_schema_migrations SET version=4, dirty=false; COMMIT;"` then delete the tf-ledger pod. Do not delete pods while a first start is migrating |
| `app` phase: `HARD BLOCKERS` from preflight | not used any more: `preflight.sh`'s OpenMeter probe runs in the `openmeter` namespace and OpenMeter's NetworkPolicy (Cilium) blocks it, so it can never pass. `deploy-all.sh` runs its own checks and calls install.sh with `SKIP_PREFLIGHT=1` |
| `openmeter-billing-*-invoices-…` pods in `Error` | the first cron runs fired before OpenMeter finished starting; later runs show `Completed`. Ignore |
| your SSH session dies when you stop a background web server | never use `pkill -f '<text>'` — the pattern also matches your own shell. Stop by port (see Part F) |
| AKS lab create failed: `Bootstrap Container Registry is not reachable` | the NSG of the private-endpoint subnet (`nsg-pe-tokenfactory`) only admits mgmt + the old AKS subnet. `Etisalat-aks.tf` adds rule `Allow-Etisalat-AKS` (443 from `10.40.16.0/26`); see Part G |
| anything else | send the last 40 lines of `~/etisalat-deploy.log` |

## PART F — Lab clean-up (after testing)
```
kubectl --kubeconfig ~/etisalat.kubeconfig delete pod img-loader-test use-tag use-digest --ignore-not-found     # leftovers from my earlier test
for port in 8000 8001; do p=$(ss -ltnp "sport = :$port" | grep -o "pid=[0-9]*" | head -1 | cut -d= -f2); [ -n "$p" ] && kill $p; done; rm -rf ~/lab-tars
```
Delete the cluster: `terraform destroy` with the `-target` list written at the top of `Etisalat-aks.tf`.

## PART G — The lab cluster (how it was built, how to remove it)
* File: `jumphost:/home/azureuser/terraform_tokenfactory/Etisalat-aks.tf` — same RG `rg-tokenfactory`, same region (UAE North), same VNet, **no internet path**: AKS "network isolated" mode (`outboundType none`), node subnet `snet-aks-etisalat` `10.40.16.0/26` with default outbound off + NSG denying Internet, no route to the firewall, private API server.
* 1 node `Standard_D16as_v5` (16 vCPU/64 GiB), `maxPods=250` (the stack is ~100 pods; default 30 is far too low), 256 GiB OS disk, Cilium (NetworkPolicies really enforced), local admin accounts ON so no Entra login is needed.
* **Why an ACR exists at all:** AKS itself (not our application) needs Microsoft's kube-system/CSI images; an isolated cluster cannot reach `mcr.microsoft.com`, so AKS pulls them from a private ACR with the mandatory cache rule `aks-managed-mcr`. Our application images never touch it — they come from the tars.
* Node → ACR private endpoint needs 443 through `nsg-pe-tokenfactory` (rule `Allow-Etisalat-AKS`, created by the same file).
* Kubeconfig: `az aks get-credentials -g rg-tokenfactory -n aks-etisalat-test --admin --file ~/etisalat.kubeconfig`. All scripts read it via `KUBECONFIG_FILE` in `config.env` (no `--kubeconfig` typing).
* Apply (needs the operator, `-target` keeps prod infra untouched): `terraform apply -target=azurerm_role_assignment.etisalat_admin_creds -target=azurerm_subnet_network_security_group_association.etisalat_aks -target=azurerm_network_security_rule.etisalat_to_pe`
* **Delete everything after testing:** `terraform destroy -target=azapi_resource.etisalat_aks -target=azurerm_container_registry.etisalat -target=azurerm_private_endpoint.etisalat_acr -target=azurerm_user_assigned_identity.etisalat_cluster -target=azurerm_user_assigned_identity.etisalat_kubelet -target=azurerm_subnet.etisalat_aks -target=azurerm_network_security_group.etisalat_aks -target=azurerm_network_security_rule.etisalat_to_pe` (deleting only the cluster leaves the ACR, endpoint and identities behind).

## PART H — Findings log (what the dry runs and the lab run taught us)
| # | Finding | What we did |
|---|---|---|
| 1 | The original doc assumed a registry; Etisalat has none | images are OCI tars imported with `ctr` into every node (`load-images.sh`); image names carry the fixed prefix `registry.etisalat.local` but nothing is ever pulled |
| 2 | Digest-pinned images (`@sha256`: keycloak, busybox 1.36, openmeter) | copied with `--all --preserve-digests`; loader also tags `name@sha256:…`. Confirmed working in the lab (tf-auth init uses the busybox digest) |
| 3 | 4 image references are hardcoded in chart templates | `03-patch-hardcoded-images.sh` rewrites tf-auth busybox, OpenMeter busybox + clickhouse, and the ClickHouse PVC (upstream hardcodes 3Gi/1Gi and no StorageClass) |
| 4 | No Ingress template on `develop` | PR #678 template is required in the chart checkout; `prepare` stops with an error if it is missing |
| 5 | Keycloak downloads its SPI jar from Maven Central on every start | the same jar as tokenfactory-prod / Xailon PR #678 (valid for Keycloak 26.7.x, bundle has 26.7.5) is bundled (`bundle/jars/`) and hosted inside the cluster by phase `jar` (ConfigMap + busybox httpd + Service `keycloak-spi`); `KEYCLOAK_JAR_URL` stays empty, or points to your own server |
| 6 | GeoIP sidecar downloads from GitHub, NGINX controller phones home | GeoIP off (`tf-ledger.geoip.enabled: false`), controller telemetry off |
| 7 | MinIO's official image no longer exists on Docker Hub/quay | step A7 builds the tar from the prod ACR |
| 8 | No Etisalat-branded `tf-docs-web` image | default-brand image stored under the branded tag (needed by `tf-accounts` init `legal-src`); `DOCS_WEB=no`. **Ask the developer for an Etisalat docs build** |
| 9 | `preflight.sh`'s OpenMeter probe cannot pass on a NetworkPolicy-enforcing cluster | `deploy-all.sh app` runs its own checks and calls `install.sh` with `SKIP_PREFLIGHT=1` |
| 10 | `install.sh` prints the helm command (with `--set` secrets) into the log | service keys go in a 0600 values file (`rendered/service-keys.yaml`) |
| 11 | `make`, `envsubst`, `skopeo` are not on a fresh VM | not needed any more (perl-based `envsub`, `install.sh` called directly; `kubectl`/`helm` in `bundle/tools`) |
| 12 | A 1-node cluster cannot hold 3 Postgres instances (anti-affinity) | `SINGLE_NODE=yes` → 1 instance, node-count check skipped (lab only) |
| 13 | On AKS the LoadBalancer Services would get public IPs | `LB_INTERNAL=yes` adds the Azure internal-LB annotation to Envoy and NGINX |
| 14 | `tf-ledger` cannot run >1 replica (no leader election, 5 unguarded loops) | pinned to 1; ticket drafted for the developer |
| 15 | Postgres `pg_hba` allows `0.0.0.0/0 md5` (copied from prod) | tighten to the pod CIDR for production |
| 16 | No Postgres backup inside an air-gap | not configured — plan `pg_dump`/WAL-G to an internal object store before production |

## PART I — The developer's `values-tf-etisalat.yaml`: where each `TODO(owner)` is filled in this package
`ai-gateway-platform/helm/tokenfactory/values-tf-etisalat.yaml` (identical to `develop`, checked 5 Nov) stays untouched. It is layer 1; our files are layer 2. Order Helm applies: chart `values.yaml` → `values-tf-etisalat.yaml` → `rendered/umbrella.yaml` → `rendered/lb-umbrella.yaml` → `rendered/service-keys.yaml`.

| `TODO(owner)` in the developer's file | Filled here by |
|---|---|
| `brandImages` (placeholder `0.17.0-etisalat-0000000`) | `config.env` → `BRAND_TAG` |
| `global.image.tag` (empty on purpose) | `config.env` → `TF_TAG` |
| `global.urls.*` (`etisalat.example.com`) | `config.env` → `DOMAIN` (creates `api. auth. portal. admin. www.`) |
| `supportEmail`, `platformAdminEmail`, SMTP host/port/user | `config.env` → `SUPPORT_EMAIL`, `PLATFORM_ADMIN_EMAIL`, `SMTP_HOST/PORT/USER/PASSWORD` |
| `stripePublishableKey` (empty) | leave empty — `billing.topup` is off in this brand |
| Persona CDD | not in the chart on `develop` yet — nothing to set |
| datastores ("inherited: external") | set **explicitly** in `umbrella.values.yaml.tmpl` (`global.postgres`, `keycloak.postgres`, `openfga.postgres` → Zalando `pgdb`) |
| replicas / PDB / sizing | `umbrella.values.yaml.tmpl` (3 replicas, Keycloak HA, Envoy PDB) |
| `OPENMETER_URL` namespace | default `openmeter` is kept (our OpenMeter release uses it) |
| `tf-gateway-resources.tls` (wildcard + `tf-etisalat-tls`) + Envoy Service | `config.env` → `DOMAIN`, `TLS_CERT`, `TLS_KEY`; `LB_INTERNAL` for Azure |
| `storageClass` | `config.env` → `STORAGE_CLASS` |
| Ingress (not in the developer's file) | `umbrella.values.yaml.tmpl` → `ingress:` — see Part J |

**What comes unchanged from the developer's Etisalat overlay (we do not touch it):** the whole `brandPack` (Etisalat theme, copy, colours, feature ceiling: sign-up on, social login and top-up off), `keycloakSecrets.generate: true`, `secrets.existingSecret: tokenfactory-secrets`, Keycloak in-cluster TLS (`keycloak-tls`, `keycloak-ca`, HTTPS upstreams of the portal/admin pods), the complete `tf-ledger.env` list (OpenMeter URL, freshness, replay horizon), `tf-warden`/`tf-relay`/`tf-shim` sizing, Redis 10Gi/3gb, and the `tf-gateway-resources` TLS + Envoy LoadBalancer port patch.
**What this package adds on top (layer 2):** the **Ingress** (portal/admin/www/auth), **Keycloak HA** (3 replicas, Infinispan, PDB, anti-affinity), **Postgres** (Zalando `pgdb`, explicit external blocks for the app, Keycloak and OpenFGA), registry prefix / image tags, URLs from `DOMAIN`, SMTP, replicas and resources of every service, Envoy replicas + PDB, GeoIP off, and the lab flags.
The Ingress is the Xailon chart change (PR #678, `ingress.yaml` + `ingress:` values) that is **not merged into `develop` yet**; the developer's file therefore says "no Ingress objects". `patches/0001-…` carries it (the chart copy used here already contains it). Once #678 is merged just delete the patch step; the `ingress:` block in our values stays exactly as it is.
`develop` is already 18 commits ahead (0.17.3 preparation, new validators such as `validate-sso-proof`, `validate-control-plaintext`). This package is pinned to 0.17.2 on purpose (it is what was tested). To move to 0.17.3: update the chart checkout, `TF_TAG`/`BRAND_TAG`, rebuild the bundle, run `dry-run`, and expect to fix whatever the new validators ask for.

## PART J — Changing a value later (any value, including the Ingress)
**Quick finder:** `VALUES-GUIDE.md` lists every `config.env` variable, how to change *any* other value with `CUSTOM_VALUES_YAML`, and what each key of the developer's overlay maps to.

**The loop is always the same:** edit → `dry-run` → apply → check.
```
nano ~/etisalat/config.env                       # site values AND sizing (domain, tag, SMTP, cert, replicas, Keycloak/Postgres/Envoy, CUSTOM_VALUES_YAML)
cd ~/etisalat
airgap/deploy-all.sh dry-run                     # must end with "dry-run PASSED"
airgap/deploy-all.sh render app                  # applies the app change (helm upgrade)
kubectl -n tokenfactory get pods        # check
helm -n tokenfactory history tokenfactory      # every change is a revision; undo with: helm -n tokenfactory rollback tokenfactory <revision>
```
Which phase applies which file:
| You changed | Run |
|---|---|
| `config.env` (domain, SMTP, tag, cert, replicas, Keycloak/Envoy sizing, `CUSTOM_VALUES_YAML`) | `airgap/deploy-all.sh render ns app` (`ns` re-applies the TLS secret) |
| `config.env` `PG_*` (Postgres) | `airgap/deploy-all.sh pg` |
| `zalando/charts/pgdb/values.yaml` | `airgap/deploy-all.sh pg` |
| `values/openmeter.values.yaml.tmpl` | `airgap/deploy-all.sh render openmeter` |
| `values/nginx-ingress.values.yaml.tmpl` (controller replicas/CPU/class) | `airgap/deploy-all.sh render ingress` |
| `values/envoy-gateway…` / `ai-gateway…` | `airgap/deploy-all.sh render controllers` |

### J1. The Ingress (`ingress:` block in `values/umbrella.values.yaml.tmpl`)
The block has four parts: `className`, `annotations`, `tls`, `hosts`. Rules that avoid every Ingress mistake: **a host name must be identical in 5 places** — `ingress.hosts[].host`, `ingress.tls[].hosts`, `global.urls.*`, the certificate's SAN, and DNS. If you only change `DOMAIN` in `config.env` the first three move together automatically.

| Task | Edit |
|---|---|
| Change the domain (all hosts) | `config.env` → `DOMAIN`; new cert in `TLS_CERT/TLS_KEY`; then `render ns app`; then update DNS |
| Change ONE host name (e.g. portal on `tokenfactory.etisalat.com`) | in the template change **all three**: `global.urls.portal`, the `portal.` line under `ingress.hosts`, and the same name under `ingress.tls[0].hosts`; the cert must cover it; DNS too |
| Add another host | add `- { host: "docs.${DOMAIN}", service: tf-site-web, port: 80 }` under `ingress.hosts` **and** the name under `ingress.tls[0].hosts` |
| Bigger uploads / longer timeouts | `annotations`: `nginx.org/client-max-body-size: 256m`, `nginx.org/proxy-read-timeout: 900s` (units as shown) |
| Send `auth.` straight to Keycloak | `ingress.hosts` line for `auth.`: `service: keycloak` instead of `keycloak-edge` (edge = nginx in the portal pods that turns a Keycloak 502/504 into the "sign-in unavailable" page) |
| Different ingress controller | change `className`; the `nginx.org/*` annotations only work with the F5 controller — community ingress-nginx needs its own `nginx.ingress.kubernetes.io/*` equivalents (`proxy-body-size`, `proxy-buffer-size`, `proxy-read-timeout`) |
| Etisalat has its own ingress/LB | `ingress.enabled: false`, and route the 4 hosts yourself to Services `tf-portal-web:80`, `tf-admin-web:80`, `tf-site-web:80`, `keycloak-edge:80` (or `keycloak:80`) |
| Replace the TLS certificate | `kubectl -n tokenfactory create secret tls tf-etisalat-tls --cert=new.crt --key=new.key --dry-run=client -o yaml \| kubectl apply -f -` (or set `TLS_CERT/TLS_KEY` and run `deploy-all.sh ns`); the controller and Envoy reload it by themselves, no pod restart |
After any Ingress edit: `kubectl -n tokenfactory get ingress tokenfactory -o yaml` (hosts, tls, annotations), then `curl -sk --resolve portal.<domain>:443:<ingress-ip> https://portal.<domain>/ -o /dev/null -w '%{http_code}\n'`. If a host answers with nginx's own self-signed certificate, the TLS secret name or the host in `tls.hosts` does not match.

### J2. Other common changes
| Change | Where / how |
|---|---|
| SMTP relay (or its SSL mode) | `config.env` `SMTP_*`; SSL/STARTTLS: add under `tf-auth.config.keycloak.smtp` in the template `ssl: true` / `starttls: false` (prod used port 465 + ssl) |
| SMTP password / Stripe or Google keys later | they live in Secret `tokenfactory-secrets`: `kubectl -n tokenfactory patch secret tokenfactory-secrets -p '{"stringData":{"smtp-password":"NEW"}}'` then `kubectl -n tokenfactory rollout restart deploy/tf-auth deploy/tf-accounts` and `rollout restart sts/keycloak` (the chart cannot detect a change inside an existing Secret) |
| Replicas / CPU / RAM of a service | template: `tf-relay: { replicas: 3, resources: … }` etc. (Part D lists every block) |
| Keycloak replicas, RAM, heap | template `keycloak:` — keep `-Xmx` at ½–¾ of `limits.memory` |
| New image version | rebuild bundle with new `TF_TAG` (Part A), copy, then `airgap/deploy-all.sh images render app` |
| Envoy replicas / limits | template `tf-gateway-resources.envoyProxy…envoyDeployment` |
| Postgres size / instances / parameters | `zalando/charts/pgdb/values.yaml`, then `deploy-all.sh pg` (disk can only grow) |
| A value that has no key in the template yet | add the key exactly as it appears in the chart's `values.yaml` (see `ai-gateway-platform/helm/tokenfactory/values-tf-prod.yaml` for every available key and its comment); lists such as `tf-ledger.env` are **replaced wholesale** — copy the whole list from `values-tf-etisalat.yaml` and change the one entry |

## PART K — `tokenfactory-secrets`: what the developer's overlay requires, and what `deploy-all.sh secrets` creates
The overlay sets `global.secrets.existingSecret: tokenfactory-secrets` (the chart then renders no Secret of its own). `deploy-all.sh secrets` creates it with fresh random values; nothing is copied from another environment.
| Key (from the overlay header) | Needed | Created by the script |
|---|---|---|
| `db-password`, `kc-db-username`, `kc-db-password`, `openfga-db-password` | required (the live DB passwords are the Zalando ones; these keys only have to exist) | yes (random; `kc-db-username=keycloak`) |
| `jwt-secret`, `portal-jwt-secret` (same value), `admin-api-key`, `ce-userinfo-signing-key`, `auth-state-signing-key` | required | yes (64 hex chars) |
| `encryption-key` | required, must decode to exactly 32 bytes | yes (`openssl rand -base64 32`) |
| `kc-admin-username`, `kc-admin-password` | required | yes (`admin` + generated, meets the Keycloak policy) |
| `platform-admin-password`, `platform-init-admin-password` | required, upper+lower+digit+special, ≥ 8 | yes |
| `s3-access-key`, `s3-secret-key` | required (bundled MinIO + ledger archive) | yes |
| `stripe-webhook-secret` | required, empty string allowed | yes, empty |
| `stripe-secret-key` | optional (top-up is off in this brand) | yes, empty |
| `smtp-password` | optional | yes, from `SMTP_PASSWORD` in `config.env` |
| `kc-admin-sa-client-secret`, `kc-accounts-sa-client-secret`, `keycloak-tls`, `keycloak-ca` | generated **in the cluster** by the `kc-secrets` hook (`global.keycloakSecrets.generate: true`) | do not create by hand |
| `google-/microsoft-/github-client-secret`, `sso-verification-google-client-secret`, `openfga-api-token` | only if social login / SSO verification / OpenFGA token is turned on (all off here) | no |
| `persona-*`, `cdd-email-hmac-key` | only for the Persona CDD block (not in the chart on `develop` yet) | no |
| the five `serviceKeyTf*` | not in the Secret: pod env literals | yes, in `~/.etisalat-service-keys.env`, passed through `rendered/service-keys.yaml` |
Other objects the overlay expects to exist before the app: the pull secret (here `registry-pull`, instead of the overlay's `ghcr-secret`; the script creates it in every namespace), the gateway TLS secret `tf-etisalat-tls`, and the Zalando role Secrets `<role>.pgdb.credentials.postgresql.acid.zalan.do` (created by the operator). All of them are created by `deploy-all.sh` before the app is installed. To use your own secret manager instead (Vault, External Secrets): create `tokenfactory-secrets` with the keys above **before** running `deploy-all.sh all` — the `secrets` phase keeps an existing Secret (but still needs `~/.etisalat-service-keys.env`; create it with the five `SERVICE_KEY_TF_ACCOUNTS/LEDGER/CONTROL/RELAY/WARDEN` lines).

## PART L — Internal registry instead of node tars (create → push → use), end to end
Use this only if Etisalat has (or is willing to run) an internal registry (Harbor, Nexus, Artifactory, `registry:2`). The default flow of this document (`IMAGE_MODE=tar`) needs none. Same bundle, same scripts; only the way the images reach the nodes changes.
| | `IMAGE_MODE=tar` (default) | `IMAGE_MODE=registry` |
|---|---|---|
| images reach nodes by | `ctr import` of the tars on every node | nodes **pull** from the registry |
| extra needs | nothing | the registry, node trust of it, **`skopeo` on the install VM** (install it from the VM's OS package mirror; if impossible use `tar`) |
| `REGISTRY` in `config.env` | name prefix only (`registry.etisalat.local`) | the real registry address |
> Status: the tar flow was tested end to end in the lab; the registry flow reuses the same bundle but its push script has not yet been run against a real registry — treat the first run as a test.

**L1. Create the registry** (pick one)
* *Existing registry (Harbor/Nexus/Artifactory):* create **one project/repository path** for us, e.g. project `tokenfactory`, and a user or robot account with **push + pull** on it. Harbor: Projects → New project `tokenfactory` (private) → Robot Accounts → New (push & pull). Then your address is `harbor.etisalat.com/tokenfactory`.
* *No registry at all:* start one on the install VM from the bundle (needs docker or podman on the VM):
  ```
  cd ~/etisalat && airgap/02a-local-registry.sh          # registry:2 on port 5000, http, data in volume etisalat-registry-data
  ```
  Address: `<VM-IP>:5000` (plain http, no login → leave `REGISTRY_USER/PASS` empty and set `DEST_TLS_VERIFY="false"`).

**L2. Let every node trust it** (otherwise `x509: certificate signed by unknown authority` or `http: server gave HTTP response`). On **each** node, containerd (1.7+), no restart needed:
```
H=harbor.etisalat.com                       # the registry HOST[:port] only, no project path
sudo mkdir -p /etc/containerd/certs.d/$H
sudo cp etisalat-registry-ca.crt /etc/containerd/certs.d/$H/ca.crt       # the CA that signed the registry certificate
sudo tee /etc/containerd/certs.d/$H/hosts.toml >/dev/null <<EOF
server = "https://$H"
[host."https://$H"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/$H/ca.crt"
EOF
```
For the plain-http `registry:2` of L1 use `server = "http://<VM-IP>:5000"` and `[host."http://<VM-IP>:5000"]` with `capabilities = ["pull","resolve"]` and `skip_verify = true`. Also copy the CA into the VM's trust store if the VM will push over https (`DEST_TLS_VERIFY="true"`).

**L3. Define it in `config.env`** — this *is* the "values.yaml" step; nothing else is edited by hand:
```
export IMAGE_MODE="registry"
export REGISTRY="harbor.etisalat.com/tokenfactory"      # host[:port][/project], NO https://, NO trailing slash
export REGISTRY_USER="robot$tokenfactory"                # leave empty for an anonymous registry
export REGISTRY_PASS="<password or robot token>"
export DEST_TLS_VERIFY="true"                            # "false" only for a self-signed/http registry
```
`deploy-all.sh render` turns `REGISTRY` into the image prefix in every chart: `global.imageRegistry` and `global.image.registry` in `rendered/umbrella.yaml` (the tf-* images, Keycloak, Redis, MinIO, OpenFGA, Postgres helpers), plus the explicit image fields of Envoy data plane, MinIO chown init, OpenMeter, NGINX ingress and the Envoy/AI-gateway controllers. See it for yourself after rendering: `cd ~/etisalat && airgap/deploy-all.sh render && grep -rn "$REGISTRY" rendered/ | head -20`. `REGISTRY_USER/PASS` become the pull secret `registry-pull` (created in all six namespaces, also set on each namespace's `default` ServiceAccount) by the `ns` phase; `imagePullSecrets` in the values already point at it.

**L4. Tag + push** — nothing to tag by hand: `skopeo` copies each tar straight to its final name (the "tag" step):
| Image (from `airgap/images.txt`) | Lands in the registry as |
|---|---|
| `ghcr.io/infinia-technology/ai-gateway-platform/tf-accounts:0.17.2-356be61` | `$REGISTRY/infinia-technology/ai-gateway-platform/tf-accounts:0.17.2-356be61` |
| `docker.io/library/redis:7-alpine` | `$REGISTRY/redis:7-alpine` |
| `quay.io/keycloak/keycloak@sha256:37dbaf…` (digest-pinned) | `$REGISTRY/keycloak/keycloak:pinned-37dbaf…` (digest preserved, so the chart's `@sha256` reference resolves) |
| `ghcr.io/zalando/spilo-17:4.0-p2` | `$REGISTRY/zalando/spilo-17:4.0-p2` |
Run it as part of the normal flow or alone:
```
cd ~/etisalat
airgap/deploy-all.sh images          # IMAGE_MODE=registry -> airgap/02-push-registry.sh (38 images)
```
It ends with `registry push complete` after proving that the three `@sha256` images (Keycloak, busybox 1.36, OpenMeter) resolve **by digest**. Plain `docker pull/tag/push` would change those digests and the pods would never start — always push with this script.
Harbor: the project must exist first (`unauthorized`/`project not found` otherwise), and the three digest-pinned images need the project to allow tags that look like `pinned-<digest>` (no tag-immutability rule that blocks them).

**L5. Verify the registry before deploying**
```
curl -u "$REGISTRY_USER:$REGISTRY_PASS" https://harbor.etisalat.com/v2/_catalog               # lists repositories (Harbor: use its UI/API per project)
skopeo inspect --creds "$REGISTRY_USER:$REGISTRY_PASS" docker://$REGISTRY/infinia-technology/ai-gateway-platform/tf-auth:0.17.2-356be61 | head -5
# from a node: it can really pull
sudo crictl pull --creds "$REGISTRY_USER:$REGISTRY_PASS" $REGISTRY/redis:7-alpine
```
**L6. Deploy** — the same one command; the `images` phase now pushes instead of loading tars:
```
airgap/deploy-all.sh dry-run
airgap/deploy-all.sh all 2>&1 | tee ~/etisalat-deploy.log
```
Afterwards every running image must come from the registry: `kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u | grep -v "^$REGISTRY/"` (only Kubernetes system images may remain).

**L7. Switching and troubleshooting**
| Situation | Do |
|---|---|
| back to tars | `IMAGE_MODE="tar"`, `REGISTRY="registry.etisalat.local"`, `airgap/deploy-all.sh images render app` (the bundle is the same) |
| new image version | rebuild the bundle (Part A), copy it, `airgap/deploy-all.sh images render app` (push is repeatable) |
| pod `ErrImagePull`: `x509: certificate signed by unknown authority` | the node does not trust the registry CA (L2) |
| pod `ErrImagePull`: `http: server gave HTTP response to HTTPS client` | plain-http registry: `server = "http://…"` + `skip_verify = true` in `hosts.toml` (L2) |
| pod `ErrImagePull`: `401 Unauthorized` | wrong `REGISTRY_USER/PASS`, or the robot lacks pull on the project; fix and `airgap/deploy-all.sh ns` (re-creates `registry-pull`), then delete the pod |
| `02-push-registry.sh`: `unauthorized` / `project not found` | create the project (L1) and check the robot has **push** |
| `02-push-registry.sh`: `INDEX has no path column` | the bundle was built by an older `01`; re-run `airgap/01-bundle-connected.sh` on the Mac (finished tars are skipped) and copy it again |
| pod `ErrImagePull` on `@sha256` images only | they were pushed by something other than this script; re-run `airgap/deploy-all.sh images` |

## What was verified in the lab (5 Nov 2026)
Run on `aks-etisalat-test` (1 node, no internet) exactly as above: all 38 images loaded from tars (`ALL 38 IMAGES PRESENT`), Postgres Patroni leader Running, Keycloak 3/3 with one Infinispan cluster of 3 members, 3× Envoy, all tf-* services Ready, OpenMeter (Kafka 3, API 2, ClickHouse, Redis) Running; `www`, `portal`, `admin` → HTTP 200 through the NGINX ingress, Keycloak issuer `https://auth.etisalat.lab/auth/realms/master`, `api` via Envoy → 401 without a key (correct). Digest-pinned images (`@sha256`) start from the node tars.
Known gaps: (1) no Etisalat-branded `tf-docs-web` image exists, so the default-brand image is stored under the branded tag (legal pages show default-brand text; docs site stays off, `DOCS_WEB=no`) — ask the developer to run the Etisalat docs build; (2) Postgres runs 1 instance in the lab (`SINGLE_NODE=yes`), HA needs ≥ 3 nodes; (3) MinIO has no public source any more (A7).

> Status of this document: image loading from a tar into the lab node was proven with a test image; the steps above were run end to end in the lab. Report the first failing step with its output.
