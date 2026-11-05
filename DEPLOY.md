# TokenFactory – Etisalat air-gap deployment (ONE document, follow top to bottom)

No internet and **no registry** inside the air-gap: every image is a `.tar` file that gets loaded straight into each node.
Three places are involved. Every step below says where to run it:

| Tag | Where |
|---|---|
| **[MAC]** | your laptop WITH internet (builds the bundle) |
| **[JUMPHOST]** | `azureuser@10.40.1.4` = the air-gap side; it can reach the cluster |
| **[CLUSTER]** | the AKS lab `aks-etisalat-test` (real Etisalat: their cluster) |

What gets installed (HA): Postgres (Zalando, 3 instances) for TokenFactory + Keycloak + OpenFGA + OpenMeter · Keycloak (3 replicas) · NGINX Ingress (portal/admin/www/auth) · Envoy AI Gateway (api) · OpenMeter · all tf-* services.
Lab note: a 1-node cluster cannot hold 3 Postgres instances, so the lab uses `SINGLE_NODE=yes` (1 instance). Everything else is identical.

---
## STEP 0 — Things you need before starting
1. A **GitHub token (PAT) with `read:packages`** that can read `ghcr.io/infinia-technology/*` (the tf-* images are private). The token saved on your Mac is invalid.
2. Two image tags: `TF_TAG` (release `0.17.2` = `0.17.2-356be61`) and `BRAND_TAG` (the **Etisalat-branded** web images, looks like `0.17.2-etisalat-abc1234`; it MUST end in a 7-character git sha). Step A3 finds them. *If no `-etisalat-` tag exists, the images were never built — ask the developer to run the Etisalat brand build first; nothing can be deployed without them.*
3. Lab only: the cluster exists (`~/etisalat.kubeconfig` on the jumphost works: `kubectl --kubeconfig ~/etisalat.kubeconfig get nodes` shows 1 Ready node).

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
Result: `bundle/tars/*.tar`, `bundle/charts`, `bundle/crds`, `bundle/jars`, `bundle/tools/helm` and `bundle/tools/kubectl` (Linux binaries for the air-gap side).

**A6. Copy everything to the jumphost** (resumable). First time as written; when you copy again later add `--exclude config.env` so your filled-in file on the jumphost is not overwritten
```
rsync -avP --exclude .git --exclude E-_TokenFactory -e "ssh -i ~/.ssh/id_rsa_jumphost" ~/Downloads/ethisalat/ azureuser@10.40.1.4:~/etisalat/
```
**A7. [JUMPHOST] Create the MinIO tar** (the only image the Mac cannot fetch). The jumphost can reach the ACR `acrtokenfactory` that still holds it; the script talks to the ACR REST API, no docker/skopeo needed:
```
ssh -i ~/.ssh/id_rsa_jumphost azureuser@10.40.1.4
cd ~/etisalat && airgap/fetch-minio-from-acr.sh      # ends with: wrote .../minio_minio_RELEASE.2025-09-07T16-13-09Z.tar
ls bundle/tars/*.tar | wc -l                          # must print 38
```
(Real Etisalat: they have no ACR — run this on any host that can reach a registry holding `minio/minio:RELEASE.2025-09-07T16-13-09Z` (edit `MINIO_ACR`), or `docker save` the image on a connected host, and drop the file at that path with the image name `registry.etisalat.local/minio/minio:RELEASE.2025-09-07T16-13-09Z`.)

---
## PART B — [JUMPHOST] deploy

**B1. Log in**
```
ssh -i ~/.ssh/id_rsa_jumphost azureuser@10.40.1.4
cd ~/etisalat
```
**B2. Check prerequisites.** Nothing has to be installed on this machine: `kubectl` and `helm` come inside the bundle (`bundle/tools/`, the scripts put them on PATH automatically). The only other things needed are standard on every Ubuntu/RHEL server: `bash perl python3 openssl tar`. Verify:
```
ls ~/etisalat.kubeconfig && ~/etisalat/bundle/tools/kubectl --kubeconfig ~/etisalat.kubeconfig get nodes
for t in perl python3 openssl tar; do command -v $t >/dev/null && echo "ok $t" || echo "MISSING $t"; done
ls ai-gateway-platform/helm/tokenfactory/templates/ingress.yaml bundle/tars/INDEX bundle/tools/helm bundle/tools/kubectl
```
If a tool really is missing on a brand-new VM, install it from the OS media/package mirror of that VM (only `perl`/`python3`/`openssl` are ever needed). `make`, `envsubst` and `skopeo` are NOT needed in the air-gap.
(If the kubeconfig is missing: `az aks get-credentials -g rg-tokenfactory -n aks-etisalat-test --admin --file ~/etisalat.kubeconfig`.)

**B3. TLS certificate.** Lab: make a self-signed wildcard. Real Etisalat: use their cert and key files instead.
```
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout ~/wild.key -out ~/wild.crt -subj "/CN=*.etisalat.lab" -addext "subjectAltName=DNS:*.etisalat.lab,DNS:etisalat.lab"
```
**B4. Serve the Keycloak plugin jar** (pods download it when Keycloak starts; keep it running during the whole deploy). Do NOT use `pkill -f` here — it kills your own SSH session.
```
cd ~/etisalat/bundle/jars && (setsid nohup python3 -m http.server 8001 >/tmp/jar.log 2>&1 < /dev/null &)
cd ~/etisalat
curl -sI http://10.40.1.4:8001/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar | head -1      # must print: HTTP/1.0 200 OK
```
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
export KEYCLOAK_JAR_URL="http://10.40.1.4:8001/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar"
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

**B7. Deploy everything (one command)**
```
airgap/deploy-all.sh all 2>&1 | tee ~/etisalat-deploy.log
```
Order it runs, with what each prints: `check` → `prepare` → `render` → `ns` → **`images`** (loads all 38 tars into the node; ends with `ALL 38 IMAGES PRESENT`) → `pg` (Postgres, waits for Running) → `secrets` → `controllers` (Envoy) → `ingress` → `openmeter` (slowest, up to 60 min) → `app` → `verify`.
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
kubectl -n tokenfactory-etisalat get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d; echo
```
Real Etisalat: create DNS records instead (`api.<domain>` → Envoy IP, `portal. admin. www. auth.<domain>` → ingress IP).

**B9. Check it is healthy**
```
export KUBECONFIG=~/etisalat.kubeconfig
kubectl get pods -A | grep -v -E 'Running|Completed'          # nothing important should be listed
kubectl -n tokenfactory-etisalat get postgresql pgdb          # Running
kubectl -n tokenfactory-etisalat get sts keycloak             # READY 3/3
kubectl -n tokenfactory-etisalat get ingress tokenfactory
```

---
## PART C — Real Etisalat (instead of the lab)
Same steps, only these differences:
* B3: use the real wildcard certificate; B5: `SINGLE_NODE="no"`, `LB_INTERNAL="no"`, real `DOMAIN`, `SMTP_*`, `STORAGE_CLASS`, a jar URL on an internal web server (not your jumphost).
* Loading images: nodes usually have SSH, so set in `config.env`:
  `export NODE_LOAD_MODE="ssh"` and `export NODES="user@node1 user@node2 user@node3"` (passwordless sudo on each node). Or `pod` mode if SSH is not allowed.
* Etisalat has no ACR: do A7 with `docker save` of MinIO from any host that has the image, and ask the developer for the Etisalat-branded `tf-docs-web` build (then set `DOCS_WEB=yes` and change its line in `airgap/images.txt` to `${BRAND_TAG}`).
* Need ≥ 3 Ready nodes, a StorageClass with volume expansion, a LoadBalancer provider (two IPs: Envoy for `api.`, ingress for portal/admin/www/auth).

## PART D — Resource sizing (all in values files, nothing else to touch)
| What | Edit |
|---|---|
| tf-* services, Keycloak, Envoy data plane, Redis, MinIO | `values/umbrella.values.yaml.tmpl` |
| Postgres instances / CPU / RAM / disk | `zalando/charts/pgdb/values.yaml` |
| OpenMeter (Kafka, ClickHouse CPU/RAM, workers) | `values/openmeter.values.yaml.tmpl` |
| ClickHouse disk | `config.env` → `CH_DATA_SIZE`, `CH_LOG_SIZE` |
| NGINX Ingress / Envoy controllers | `values/nginx-ingress…tmpl`, `values/envoy-gateway…tmpl`, `values/ai-gateway…tmpl` |

After editing run only what changed, e.g. `airgap/deploy-all.sh render app`.

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
| `images` phase: `MISSING <image>` | the tar was not in the bundle → rebuild on the Mac (A5) and rsync again |
| pod `ErrImagePull` / `ImagePullBackOff` | the image is not on that node. Run `airgap/deploy-all.sh images`. For `@sha256` images (keycloak, busybox, openmeter) also check `kubectl describe pod` shows the exact reference |
| Keycloak not Ready | jar server (B4) stopped → restart B4; check `kubectl -n tokenfactory-etisalat logs keycloak-0 -c fetch-providers` |
| `pg` phase stuck | `kubectl -n tokenfactory-etisalat describe postgresql pgdb`; on a 1-node cluster SINGLE_NODE must be `yes` |
| `tf-accounts` stuck in `Init:ErrImagePull` on `tf-docs-web` | the docs image tar is missing on the node (its init container `legal-src` copies the legal pages out of it). `airgap/deploy-all.sh images`, then delete the pod |
| `tf-ledger` CrashLoop: `Dirty database version N` | a pod was killed in the middle of a DB migration. Lab-safe fix: undo that one migration and let it re-run, e.g. for 5: `kubectl -n tokenfactory-etisalat exec pgdb-0 -c postgres -- psql -U postgres -d tokenfactory -c "BEGIN; DROP TABLE IF EXISTS tf_credit_grants; UPDATE tf_ledger_schema_migrations SET version=4, dirty=false; COMMIT;"` then delete the tf-ledger pod. Do not delete pods while a first start is migrating |
| `app` phase: `HARD BLOCKERS` from preflight | not used any more: `preflight.sh`'s OpenMeter probe runs in the `openmeter` namespace and OpenMeter's NetworkPolicy (Cilium) blocks it, so it can never pass. `deploy-all.sh` runs its own checks and calls install.sh with `SKIP_PREFLIGHT=1` |
| `openmeter-billing-*-invoices-…` pods in `Error` | the first cron runs fired before OpenMeter finished starting; later runs show `Completed`. Ignore |
| ssh session dies when you start/stop the jar server | never `pkill -f 'http.server …'` — the pattern also matches your own shell. Start with `(setsid nohup … &)`, stop by port (see Part F) |
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
| 5 | Keycloak downloads its SPI jar from Maven Central on every start | jar is served internally (`KEYCLOAK_JAR_URL`, step B4) |
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

## What was verified in the lab (5 Nov 2026)
Run on `aks-etisalat-test` (1 node, no internet) exactly as above: all 38 images loaded from tars (`ALL 38 IMAGES PRESENT`), Postgres Patroni leader Running, Keycloak 3/3 with one Infinispan cluster of 3 members, 3× Envoy, all tf-* services Ready, OpenMeter (Kafka 3, API 2, ClickHouse, Redis) Running; `www`, `portal`, `admin` → HTTP 200 through the NGINX ingress, Keycloak issuer `https://auth.etisalat.lab/auth/realms/master`, `api` via Envoy → 401 without a key (correct). Digest-pinned images (`@sha256`) start from the node tars.
Known gaps: (1) no Etisalat-branded `tf-docs-web` image exists, so the default-brand image is stored under the branded tag (legal pages show default-brand text; docs site stays off, `DOCS_WEB=no`) — ask the developer to run the Etisalat docs build; (2) Postgres runs 1 instance in the lab (`SINGLE_NODE=yes`), HA needs ≥ 3 nodes; (3) MinIO has no public source any more (A7).

> Status of this document: image loading from a tar into the lab node was proven with a test image; the steps above were run end to end in the lab. Report the first failing step with its output.
