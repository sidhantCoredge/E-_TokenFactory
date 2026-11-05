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
It must end with `== done. total size:`. Result: `bundle/tars/*.tar` (38 images), `bundle/charts`, `bundle/crds`, `bundle/jars`, `bundle/tools/helm`.

**A6. Copy everything to the jumphost** (resumable)
```
rsync -avP --exclude .git -e "ssh -i ~/.ssh/id_rsa_jumphost" ~/Downloads/ethisalat/ azureuser@10.40.1.4:~/etisalat/
```

---
## PART B — [JUMPHOST] deploy

**B1. Log in**
```
ssh -i ~/.ssh/id_rsa_jumphost azureuser@10.40.1.4
cd ~/etisalat
```
**B2. Check prerequisites** (every line must print a path/OK)
```
ls ~/etisalat.kubeconfig && kubectl --kubeconfig ~/etisalat.kubeconfig get nodes
for t in kubectl make envsubst openssl perl python3; do command -v $t >/dev/null && echo "ok $t" || echo "MISSING $t"; done
ls ai-gateway-platform/helm/tokenfactory/templates/ingress.yaml bundle/tars/INDEX bundle/tools/helm
```
(If the kubeconfig is missing: `az aks get-credentials -g rg-tokenfactory -n aks-etisalat-test --admin --file ~/etisalat.kubeconfig`.)

**B3. TLS certificate.** Lab: make a self-signed wildcard. Real Etisalat: use their cert and key files instead.
```
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout ~/wild.key -out ~/wild.crt -subj "/CN=*.etisalat.lab" -addext "subjectAltName=DNS:*.etisalat.lab,DNS:etisalat.lab"
```
**B4. Serve the Keycloak plugin jar** (pods download it when Keycloak starts; keep this running during the whole deploy)
```
cd ~/etisalat/bundle/jars && nohup python3 -m http.server 8001 >/tmp/jar.log 2>&1 &
cd ~/etisalat
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

**B8. Open the portal.** The `verify` phase prints two private IPs. Lab (no DNS): put them in `/etc/hosts` of the jumphost —
```
echo "<ENVOY_IP>   api.etisalat.lab" | sudo tee -a /etc/hosts
echo "<INGRESS_IP> portal.etisalat.lab admin.etisalat.lab www.etisalat.lab auth.etisalat.lab" | sudo tee -a /etc/hosts
curl -sk -o /dev/null -w '%{http_code}\n' https://portal.etisalat.lab/      # 200
```
Admin login: user = `admin@etisalat.lab`, password:
```
kubectl --kubeconfig ~/etisalat.kubeconfig -n tokenfactory-etisalat get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d; echo
```
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
| `FATAL: config.env still has REPLACE_` | fill that line |
| `images` phase: `MISSING <image>` | the tar was not in the bundle → rebuild on the Mac (A5) and rsync again |
| pod `ErrImagePull` / `ImagePullBackOff` | the image is not on that node. Run `airgap/deploy-all.sh images`. For `@sha256` images (keycloak, busybox, openmeter) also check `kubectl describe pod` shows the exact reference |
| Keycloak not Ready | jar server (B4) stopped → restart B4; check `kubectl -n tokenfactory-etisalat logs keycloak-0 -c fetch-providers` |
| `pg` phase stuck | `kubectl -n tokenfactory-etisalat describe postgresql pgdb`; on a 1-node cluster SINGLE_NODE must be `yes` |
| anything else | send the last 40 lines of `~/etisalat-deploy.log` |

## PART F — Lab clean-up (after testing)
```
kubectl --kubeconfig ~/etisalat.kubeconfig delete pod img-loader-test use-tag use-digest --ignore-not-found     # leftovers from my earlier test
pkill -f "http.server 8000"; pkill -f "http.server 8001"; rm -rf ~/lab-tars
```
Delete the cluster: `terraform destroy` with the `-target` list written at the top of `Etisalat-aks.tf`.

> Status of this document: image loading from a tar into the lab node was proven with a test image; the full end-to-end run is exactly what you are testing now. Report the first failing step with its output.
