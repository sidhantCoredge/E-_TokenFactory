# Lab deployment (Azure, single node, no internet) — follow top to bottom

The lab is the single-node AKS cluster `aks-etisalat-test`, driven from the jumphost `azureuser@10.40.1.4`. It has no internet, no HPE X10000, no MetalLB and no ingress controller of its own, so this guide differs from `DEPLOY.md` (real Etisalat) in a few settings. Everything else is the same package.

| Setting | Real Etisalat | This lab |
|---|---|---|
| Storage | HPE X10000 (NFS), `STORAGE_BACKEND=hpe-x10000` | the AKS disk class `default`, `STORAGE_BACKEND=existing` |
| Ingress controller | the cluster's existing one (`existing`) | installed by the package (F5 NGINX, `install`) |
| Exposure | MetalLB IPs | internal Azure load balancers (`LB_INTERNAL=yes`) |
| Nodes | 4 workers, images over SSH | 1 node, images loaded by a helper pod (`NODE_LOAD_MODE=pod`) |
| Secrets | in-cluster Vault | **in-cluster Vault (same as Etisalat: this lab tests it)** |
| Vault UI | on | off (the lab has no DNS) |
Every command below is meant to be copied as written. Lines starting with `#` are comments.

---
## PART 1 — On your Mac (needs the VPN to the jumphost)
All commands of this part run **on your Mac, in a terminal, from the package root** (the folder that contains `config.env`, `airgap/`, `values/`; below it is `~/Downloads/E-_TokenFactory`, on the author's Mac `~/Downloads/E-_TokenFactory-upload`). Do not `cd` into `airgap/`.

### 1.1 Do you already have the bundle? Check each line
The bundle (`bundle/`, 5.8 GB) and the chart checkout (`ai-gateway-platform/`) are **not in GitHub**: they are built on your Mac and stay in the package folder (git-ignored).
```
cd ~/Downloads/E-_TokenFactory
pwd
```
| # | Check (run it) | You must see | If not: what to do |
|---|---|---|---|
| 1 | `ls config.env airgap values zalando` | the four names, no error | you are in the wrong folder: `cd` to the folder where you cloned the repository |
| 2 | `git -C ai-gateway-platform rev-parse HEAD` | `58577e2d2bd5b051745e741aa48a882462360e4d` | missing or another commit: **create the checkout** (box A below) |
| 3 | `ls bundle/tars/*.tar \| wc -l` | `56` | fewer or no `bundle/`: **create the bundle** (box A below) |
| 4 | `wc -l < bundle/tars/INDEX` | `56` | same as 3 |
| 5 | `ls bundle/charts` | 7 files: `ai-gateway-crds-helm-v1.0.0.tgz ai-gateway-helm-v1.0.0.tgz gateway-helm-v1.8.1.tgz hpe-csi-driver-3.2.0.tgz nginx-ingress-1.3.2.tgz secrets-store-csi-driver-1.5.6.tgz vault-0.32.0.tgz` | one is missing: **create the bundle** (box A) |
| 6 | `ls bundle/jars bundle/tools` | the Keycloak jar `...26.6.1-KC26.8.0.jar`, and `helm kubectl` | **create the bundle** (box A) |
| 7 | `grep -E '^export (TF_TAG\|CHART_REF)=' config.env \| cut -c1-70` | `TF_TAG="0.17.7-73caf32"` and the `CHART_REF` above | the tag/commit in `config.env` is old: `git pull` (or edit the two lines), then box A |
If **all seven** are fine, go to 1.3. If any one is not, do box A first.

### 1.2 Box A: create the checkout and the bundle (only if a check above failed; needs internet)
```
cd ~/Downloads/E-_TokenFactory
brew install skopeo crane helm git                         # once per Mac
skopeo login docker.io                                     # Docker Hub account
skopeo login ghcr.io -u <your-github-username>             # password = a GitHub token with read:packages on Infinia-Technology
airgap/00-fetch-chart.sh                                   # ends with: ok: chart checkout complete   (needs your git access to Infinia-Technology/ai-gateway-platform)
bash -c '. airgap/env.sh; echo "TF_TAG=$TF_TAG BRAND_TAG=$BRAND_TAG"; skopeo inspect --no-tags docker://ghcr.io/infinia-technology/ai-gateway-platform/tf-accounts:$TF_TAG >/dev/null && echo "TF_TAG ok"; skopeo inspect --no-tags docker://ghcr.io/infinia-technology/ai-gateway-platform/tf-portal-web:$BRAND_TAG >/dev/null && echo "BRAND_TAG ok"'
airgap/01-bundle-connected.sh                              # 20-60 min; safe to run again if it stops (finished images are skipped)
```
The last script must end with `image tars: 56 of 56` and `bundle COMPLETE`. Anything listed as `FAILED images` is a real error: fix it and run the script again. If the chart checkout was changed (`00-fetch-chart.sh` fetched a new commit), run `airgap/01-bundle-connected.sh` again afterwards: it re-vendors the chart dependencies. **Do not run `00-fetch-chart.sh` while `01-bundle-connected.sh` is running** (it replaces the checkout the other script is using).
Then run the seven checks of 1.1 again.

### 1.3 Copy the package to the jumphost
This copies the whole package folder, including the git-ignored `bundle/` and `ai-gateway-platform/` (≈ 6 GB; unchanged files are skipped, old tars that are no longer used are removed; the jumphost has ~16 GB free). **Do not type a path to the package: `cd` into it and copy "the current folder" (`./`).** First prove that you are in the right folder and that the bundle is complete (the seven checks of 1.1):
```
cd ~/Downloads/E-_TokenFactory           # YOUR package folder (on the author's Mac: ~/Downloads/E-_TokenFactory-upload)
ls config.env airgap values zalando      # the four names, no error
ls bundle/tars/*.tar | wc -l             # must print 56 (if it prints 0 or an error, the bundle is not built: do box A of 1.2 first)
```
Then copy (the trailing `./` is the current folder; `--delete` makes the jumphost folder an exact mirror, so run it only from the package folder):
```
rsync -avP --delete --exclude .git --exclude Real-values-of-tf-prod.yaml -e "ssh -i ~/.ssh/id_rsa_jumphost" ./ azureuser@10.40.1.4:~/etisalat/
```
`Real-values-of-tf-prod.yaml` (real production values, kept only on the author's Mac, never in git) is excluded so that it never reaches the jumphost.
It must end without errors. Then log in:
```
ssh -i ~/.ssh/id_rsa_jumphost azureuser@10.40.1.4
```

---
## PART 2 — On the jumphost
### 2.1 Check the tools and the cluster
```
cd ~/etisalat
export KUBECONFIG=~/etisalat.kubeconfig
export PATH=~/etisalat/bundle/tools:$PATH
for t in bash perl python3 openssl tar; do command -v $t >/dev/null && echo "ok $t" || echo "MISSING $t"; done
ls ai-gateway-platform/helm/tokenfactory/templates/ingress.yaml bundle/tars/INDEX bundle/tools/helm bundle/tools/kubectl bundle/jars/*.jar
ls bundle/tars/*.tar | wc -l                                  # 56
kubectl get nodes                                             # 1 node Ready
kubectl get sc                                                # the class "default" must exist (azure disk, expansion true)
```
If `kubectl get nodes` fails: `az aks get-credentials -g rg-tokenfactory -n aks-etisalat-test --admin --file ~/etisalat.kubeconfig --overwrite-existing`.

### 2.2 Reset the lab (only if the lab is not clean)
Check first (it is clean when only the `default` and `kube-*` namespaces exist and there are no pods outside `kube-system`):
```
export KUBECONFIG=~/etisalat.kubeconfig
kubectl get ns
kubectl get pods -A | grep -v kube-system
kubectl get pv
```
Clean (nothing listed except the four system namespaces): skip to 2.3. Otherwise run the reset script that came with the package. It refuses to run unless the cluster is the lab (exactly one node `aks-sys1-*`), and it removes only the objects of this stack (namespaces and their volumes, the CRDs and cluster roles of the stack, the cached images, and the Etisalat files in the home directory; never the AKS add-ons or any Xailon file):
```
cd ~/etisalat
airgap/lab-reset.sh --dry-run --images     # shows what would be removed, changes nothing
airgap/lab-reset.sh --images               # asks you to type RESET-LAB, then resets (5-15 min)
```
It ends with `LAB CLEAN`. Run it again if it says `NOT clean` (a namespace can need a minute to terminate).

### 2.3 TLS certificate (self-signed wildcard for the lab)
```
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout ~/wild.key -out ~/wild.crt -subj "/CN=*.etisalat.lab" -addext "subjectAltName=DNS:*.etisalat.lab,DNS:etisalat.lab"
chmod 600 ~/wild.key
openssl x509 -in ~/wild.crt -noout -subject -enddate
```

### 2.4 Lab settings (one block, copy as written)
This appends the lab overrides to `config.env`; later lines win over the defaults above them.
```
cd ~/etisalat
cat >> config.env <<'EOF'

# ===== AZURE LAB OVERRIDES (single node, no internet): later lines win =====
export KUBECONFIG_FILE="/home/azureuser/etisalat.kubeconfig"
export SINGLE_NODE="yes"                      # 1 Postgres instance, Keycloak anti-affinity relaxed
export STORAGE_BACKEND="existing"             # no HPE X10000 in the lab
export STORAGE_CLASS="default"                # AKS disk class
export INGRESS_CONTROLLER="install"           # the package installs the F5 NGINX controller
export INGRESS_CLASS="nginx"
export EXPOSE="loadbalancer"
export LB_INTERNAL="yes"                      # Azure internal load balancers (no public IP)
export ENVOY_LB_IP=""
export BEHIND_CLOUDFLARE="no"
export DOMAIN="etisalat.lab"
export TLS_CERT="/home/azureuser/wild.crt"
export TLS_KEY="/home/azureuser/wild.key"
export NODE_LOAD_MODE="pod"
export NODES=""
export SMTP_HOST="smtp.etisalat.lab"
export SMTP_USER="lab"
export SECRETS_BACKEND="vault"                # the lab tests the in-cluster Vault
export VAULT_UI="false"                       # no DNS in the lab; the UI is tested on the real cluster
EOF
```
Check that nothing is left to fill (this reads the effective values):
```
bash -c '. airgap/env.sh; env | grep -E "^[A-Za-z0-9_]+=.*REPLACE_" | grep -v "^X10000_" || echo "config complete"'
```
It must print `config complete` (the `X10000_*` placeholders are ignored in the lab because `STORAGE_BACKEND=existing`).

### 2.4b Dry-run (renders every chart offline, changes nothing)
```
airgap/deploy-all.sh dry-run
```
Must end with `dry-run PASSED`. If it stops with `FATAL:`, read the message, fix it and run it again.

### 2.5 Deploy everything (one command, 40–90 min)
```
airgap/deploy-all.sh all 2>&1 | tee ~/etisalat-deploy.log
```
What happens, in order: `check` → `prepare` → `render` → `ns` → `images` (56 tars into the node; ends with `ALL 56 IMAGES PRESENT`) → `jar` → `storage` (skipped: lab) → **`vault`** (installs Vault, initializes it, unseals it) → `pg` → `secrets` (writes the secrets to Vault) → `controllers` → `ingress` → `openmeter` (slowest) → `app` → `verify`.
If it stops, fix the cause and continue where it stopped: `airgap/deploy-all.sh --from <phase>` (for example `--from openmeter`).

**Right after the `vault` phase, save the Vault init file** (unseal keys + root token). On your Mac, in another terminal:
```
scp -i ~/.ssh/id_rsa_jumphost azureuser@10.40.1.4:.etisalat-vault-init.json ~/etisalat-lab-vault-init.json
chmod 600 ~/etisalat-lab-vault-init.json
```
Also keep `~/.etisalat-service-keys.env` (same way). Without them a restart of the lab Vault cannot be reopened.

---
## PART 3 — Check that it works
### 3.1 Everything running
```
export KUBECONFIG=~/etisalat.kubeconfig; export PATH=~/etisalat/bundle/tools:$PATH
kubectl get pods -A | grep -v -E 'Running|Completed'          # nothing important listed
kubectl -n tokenfactory get postgresql pgdb                    # Running
kubectl -n tokenfactory get sts keycloak                       # 3/3
kubectl -n tokenfactory get deploy                             # tf-* 3/3 (docs/site 1/1), envoy 6/6
kubectl -n tokenfactory get ingress tokenfactory
kubectl -n vault get pods                                      # vault-0 + vault-csi-provider Running
kubectl -n vault exec vault-0 -- vault status | grep -E "Initialized|Sealed"       # true / false
kubectl -n tokenfactory get secret tokenfactory-secrets        # synced from Vault
kubectl -n tokenfactory get secret tokenfactory-secrets -o json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]),"keys")'    # 19 keys
kubectl -n tokenfactory logs deploy/tf-ledger --tail=300 | grep -i leader | tail -3     # one leader (3 ledger pods, leader election)
```
### 3.2 Open the portal (the lab has no DNS: use the addresses with --resolve)
```
ING=$(kubectl -n nginx-ingress get svc nginx-ingress-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo "ingress $ING"
API=$(kubectl -n tokenfactory get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'); echo "envoy   $API"
for h in www portal admin; do curl -sk -o /dev/null -w "$h %{http_code}\n" --resolve $h.etisalat.lab:443:$ING https://$h.etisalat.lab/; done      # 200 200 200
curl -sk --resolve auth.etisalat.lab:443:$ING https://auth.etisalat.lab/auth/realms/master/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
curl -sk -o /dev/null -w "api %{http_code}\n" --resolve api.etisalat.lab:443:$API https://api.etisalat.lab/v1/models        # 401 without a key = correct
```
Admin login: user `admin@etisalat.lab`, password:
```
kubectl -n tokenfactory get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d; echo
```

### 3.3 Test the Vault restart behaviour (recommended: this is what Etisalat will live with)
```
kubectl -n vault delete pod vault-0
kubectl -n vault wait --for=condition=ready pod/vault-0 --timeout=300s
kubectl -n vault exec vault-0 -- vault status | grep Sealed          # Sealed true (it starts sealed after a restart)
kubectl -n tokenfactory get pods | grep -v -E 'Running|Completed'   # TokenFactory keeps running: the Secret already exists
cd ~/etisalat && airgap/deploy-all.sh vault                           # unseals it again
kubectl -n vault exec vault-0 -- vault status | grep Sealed          # Sealed false
```

---
## PART 4 — If something fails
`DEPLOY.md` Part E has the common errors. Vault: `VAULT-SECRETS.md` section 5. Send the last 40 lines of `~/etisalat-deploy.log` and the failing command with its output.
Typical lab-only points:
| You see | Do |
|---|---|
| `images` phase: helper pod cannot start | the node must already have the `LOADER_DEBUG_IMAGE` (an MCR busybox); check `kubectl -n default get pods` and `kubectl -n default logs img-loader-*` |
| Pods `Pending` (no memory/CPU) | the node has 16 vCPU / 60 GiB; check `kubectl describe node` (Allocated resources). Lower a service with `SVC_*` in `config.env`, then `airgap/deploy-all.sh render app` |
| PVC `Pending` with class `default` | `kubectl get sc default` and `kubectl describe pvc <name>`; the class is `WaitForFirstConsumer`, so the PVC binds when its pod is scheduled |
| `vault` phase: `Vault is initialized but ~/.etisalat-vault-init.json is missing` | you skipped 2.2 (old Vault data) or deleted the file: delete the namespace `vault` (and its PVC) and run `airgap/deploy-all.sh --from vault` |

## Clean up after testing
```
export KUBECONFIG=~/etisalat.kubeconfig
for r in tokenfactory pgdb; do helm -n tokenfactory uninstall $r || true; done
helm -n openmeter uninstall openmeter || true; helm -n nginx-ingress uninstall nginx-ingress || true; helm -n postgres uninstall postgres-operator || true
helm -n vault uninstall vault || true; helm -n kube-system uninstall csi-secrets-store || true
kubectl delete ns tokenfactory openmeter nginx-ingress postgres vault envoy-ai-gateway-system envoy-gateway-system --wait=true --timeout=15m --ignore-not-found
rm -f ~/.etisalat-service-keys.env ~/.etisalat-vault-init.json
```
Delete the cluster itself with the `terraform destroy -target ...` list at the top of `Etisalat-aks.tf` (DEPLOY.md Part G).
