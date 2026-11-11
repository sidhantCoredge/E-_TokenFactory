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
2. Two image tags, both in `config.env`: `TF_TAG` (release **0.17.7** = `0.17.7-160792b`, chart 0.17.7 from branch `stage`) and `BRAND_TAG` (the **Etisalat-branded** web images, `<version>-etisalat-<7-char sha>`). Today the only Etisalat-branded web build in GHCR is `0.17.0-etisalat-6b27a33` (checked 10 Nov 2026), so `BRAND_TAG` stays on it: the portal/admin/site UIs are the 0.17.0 branded build running against 0.17.7 services. When the developer builds `0.17.7-etisalat-<sha>`, put it in `BRAND_TAG` and rebuild the bundle. Step A4 checks both tags exist.
3. Lab only: the cluster exists (`~/etisalat.kubeconfig` on the install VM works: `kubectl --kubeconfig ~/etisalat.kubeconfig get nodes` shows 1 Ready node).

---
## PART A — [MAC] build the bundle (needs internet)
This git repo holds scripts, values and docs only. Two things are **not** in git (private or huge) and are created here, git-ignored: `ai-gateway-platform/` (the chart checkout, pinned to one commit) and `bundle/` (image tars, charts, CRDs, Keycloak jar, linux `helm`/`kubectl`). Both are copied to the install VM in A6.

**Where to run Part A.** Everything in Part A runs **on your Mac, in a terminal, from the package root**: the folder that contains `config.env`, `airgap/`, `values/` and `DEPLOY.md`. Do **not** `cd` into `airgap/`, and never run `airgap/env.sh` on its own: it only loads the settings for the other scripts. The Mac's default shell (zsh) is fine; every script starts with its own `bash`.

**Step 0: the package folder must have the name this guide uses: `~/Downloads/E-_TokenFactory`.** Every command below starts with `cd ~/Downloads/E-_TokenFactory`. Look at what you have:
```
ls -d ~/Downloads/E-_TokenFactory ~/Downloads/E-_TokenFactory-upload 2>/dev/null
```
| What the command prints | What to do (once) |
|---|---|
| `/Users/<you>/Downloads/E-_TokenFactory` | nothing: the name already matches |
| only `.../E-_TokenFactory-upload` (your working copy, with `bundle/` if you built it) | rename it so the guide's paths work: `mv ~/Downloads/E-_TokenFactory-upload ~/Downloads/E-_TokenFactory` |
| nothing | clone it: `git clone git@github.com:sidhantCoredge/E-_TokenFactory.git ~/Downloads/E-_TokenFactory`. A fresh clone has **no** `bundle/` and no `ai-gateway-platform/` (they are not in git): build them in the next step |
Then check you are in the right place:
```
cd ~/Downloads/E-_TokenFactory
pwd                                        # /Users/<you>/Downloads/E-_TokenFactory
ls config.env airgap values zalando        # the four names, no error
```

**A0. Do you already have the bundle? Check each line first.** The bundle (`bundle/`, about 5.8 GB) and the chart checkout (`ai-gateway-platform/`) are **not in GitHub**: they are built on your Mac and stay in the package folder (git-ignored). If all seven checks are fine, skip to Part B. If any check fails, do the steps named in the last column (they are A1 - A5 below), then run the seven checks again.
```
cd ~/Downloads/E-_TokenFactory
```
| # | Check (run it) | You must see | If not: create it with |
|---|---|---|---|
| 1 | `ls config.env airgap values zalando` | the four names, no error | you are in the wrong folder: `cd` to the folder where you cloned the repository |
| 2 | `grep -E '^export (TF_TAG\|CHART_REF)=' config.env \| cut -c1-70` | `TF_TAG="0.17.7-73caf32"` and `CHART_REF="58577e2d2bd5b051745e741aa48a882462360e4d"` | the settings are old: `git pull`, then do A3 - A5 |
| 3 | `git -C ai-gateway-platform rev-parse HEAD` | `58577e2d2bd5b051745e741aa48a882462360e4d` | missing or another commit: **A1, A2, A3** (then A5, to re-vendor the chart dependencies) |
| 4 | `ls bundle/tars/*.tar \| wc -l` | `56` | fewer, or no `bundle/`: **A1, A2, A5** |
| 5 | `wc -l < bundle/tars/INDEX` | `56` | same as 4 |
| 6 | `ls bundle/charts` | 7 files: `ai-gateway-crds-helm-v1.0.0.tgz ai-gateway-helm-v1.0.0.tgz gateway-helm-v1.8.1.tgz hpe-csi-driver-3.2.0.tgz nginx-ingress-1.3.2.tgz secrets-store-csi-driver-1.5.6.tgz vault-0.32.0.tgz` | one is missing: **A5** |
| 7 | `ls bundle/jars bundle/tools` | the Keycloak jar `keycloak-2fa-email-authenticator-26.6.1-KC26.8.0.jar`, and `helm kubectl` | **A5** |
Order when you must create things: **A1 (tools) -> A2 (logins) -> A3 (chart checkout) -> A4 (tag check) -> A5 (bundle)**. Do not run A3 while A5 is running (A3 replaces the checkout that A5 uses).

**A1. Tools**
```
brew install skopeo crane helm git
```
**A2. Log in** (Docker Hub avoids rate limits; ghcr needs your PAT as the password). You also need git access (SSH key) to `Infinia-Technology/ai-gateway-platform`
```
skopeo login docker.io
skopeo login ghcr.io -u <your-github-username>
```
**A3. Fetch the chart checkout** (pinned: `CHART_REPO` / `CHART_REF` in `config.env` = branch `stage`, chart 0.17.7). It also refuses a `TF_TAG` that does not start with the chart version
```
cd ~/Downloads/E-_TokenFactory
airgap/00-fetch-chart.sh                  # ends with: ok: chart checkout complete
```
**A4. Check the two image tags exist** (nothing to edit unless you move to a newer release: then change `TF_TAG`, `BRAND_TAG` and `CHART_REF` together in `config.env`). The check needs the settings loaded in the same command, so it runs inside `bash -c`:
```
cd ~/Downloads/E-_TokenFactory
bash -c '. airgap/env.sh; echo "TF_TAG=$TF_TAG BRAND_TAG=$BRAND_TAG"; skopeo inspect --no-tags docker://ghcr.io/infinia-technology/ai-gateway-platform/tf-accounts:$TF_TAG >/dev/null && echo "TF_TAG ok"; skopeo inspect --no-tags docker://ghcr.io/infinia-technology/ai-gateway-platform/tf-portal-web:$BRAND_TAG >/dev/null && echo "BRAND_TAG ok"'
```
It must print the two tags, then `TF_TAG ok` and `BRAND_TAG ok`. (`invalid reference format` with an empty tag means the settings were not loaded: run the command exactly as written, from the package root.) `unauthorized` means `skopeo login ghcr.io` (A2) is missing or the token cannot read `infinia-technology` packages.
**A5. Build the bundle** (≈ 5 GB, 20–60 min, safe to re-run if it stops: finished images are skipped)
```
cd ~/Downloads/E-_TokenFactory
airgap/01-bundle-connected.sh
```
It ends with `== done. total size:`, `image tars: 56 of 56` and `bundle COMPLETE`. If A3 just fetched a new chart commit, run A5 again: it re-vendors the chart dependencies (finished image tars are skipped). Anything listed as `FAILED images` is a real error: fix it and re-run (finished images are skipped). Every image the chart renders is in `airgap/images.txt` (checked by rendering all releases with `helm template`).
Result: `bundle/tars/*.tar`, `bundle/charts`, `bundle/crds`, `bundle/jars` (the Keycloak plugin jar, see B4), `bundle/tools/helm` and `bundle/tools/kubectl` (Linux binaries for the air-gap side).

**A6. Copy everything to the install VM** (resumable; the folder includes the git-ignored `ai-gateway-platform/` and `bundle/`). First time as written; when you copy again later add `--exclude config.env` so your filled-in file on the VM is not overwritten
```
cd ~/Downloads/E-_TokenFactory                 # `ls bundle/tars/*.tar | wc -l` must print 56 before you copy
rsync -avP --exclude .git --exclude Real-values-of-tf-prod.yaml ./ <vm-user>@<VM-IP>:~/etisalat/
# lab: see DEPLOY-LAB.md 1.3
# no network path Mac -> VM (real air-gap)? copy the folder on a USB disk / approved transfer, then `tar -xf` it as ~/etisalat on the VM
```
(MinIO needs no special step any more: since chart 0.17.x its image is Infinia's own build on GHCR and is bundled like the tf-* images.)

---
## PART B — [VM] deploy on the real Etisalat cluster (every command, in order)
Run everything below **on the install VM**, as the user that owns `~/etisalat`. Lab differences (Azure jumphost, 1 node) are in Part B-LAB at the end of this part.

### B0. The cluster this package targets
**The cluster** (7 VMs; subnet `172.22.100.0/22`, gateway `172.22.100.254`). Kubernetes API VIP **`172.22.100.240`** (the `server:` of the kubeconfig). **MetalLB pool `172.22.100.241-250`**; the cluster's **Ingress-NGINX controller is already running on `172.22.100.241`**. Images are loaded on the 4 workers; Postgres (3), Keycloak (3), Kafka (3) and Envoy (6) spread over them:
| IP | Name | Role |
|---|---|---|
| 172.22.100.21 | ed-kca-inf-tf-cn-01 | master-1 (control plane) |
| 172.22.100.22 | ed-kca-inf-tf-cn-02 | master-2 (control plane) |
| 172.22.100.23 | ed-kca-inf-tf-cn-03 | master-3 (control plane) |
| 172.22.100.24 | ed-kca-inf-tf-cpu-wrk-001 | worker-1 |
| 172.22.100.25 | ed-kca-inf-tf-cpu-wrk-002 | worker-2 |
| 172.22.100.26 | ed-kca-inf-tf-cpu-wrk-003 | worker-3 |
| 172.22.100.27 | ed-kca-inf-tf-cpu-wrk-004 | worker-4 |
Check which nodes accept pods with `kubectl get nodes` and `kubectl describe node <n> | grep Taints`; load images on every node that can run pods (normally only the 4 workers).

* Needed from Etisalat before you start: the cluster admin kubeconfig, SSH access from the install VM to the 4 workers with passwordless `sudo`, the **X10000 storage details** (STORAGE-HPE-CSI.md section 2) and `nfs-common` on the 4 workers, the TLS certificate + key (PEM) that cover `portal. admin. www. auth. api.<DOMAIN>` (wildcard), the Resend API key (`SMTP_PASSWORD`), and the DNS names of B8.
* **Firewall (outbound from the workers):** `tcp/443` to the X10000 management address and `tcp/2049` to its data IPs (storage, `STORAGE-HPE-CSI.md`); `tcp/465` to `smtp.resend.com` (mail) and `https` to `api.resend.com`. Nothing else leaves the cluster: GeoIP downloads are off, Persona KYC is off, no image is ever pulled from the Internet (images are loaded from the tars).
* **Traffic path: MetalLB direct (no Cloudflare).** `portal. admin. www. auth.<DOMAIN>` → the existing Ingress-NGINX on `172.22.100.241`; `api.<DOMAIN>` → Envoy on `172.22.100.242` (`ENVOY_LB_IP`, a free IP of the pool `172.22.100.241-250`). Envoy terminates TLS itself, so the certificate must also cover `api.<DOMAIN>` (a wildcard `*.<DOMAIN>` does). Create the DNS records in B8. (A Cloudflare tunnel is optional and not used: Part M.)

### B1. Log in and enter the package
```
ssh <vm-user>@<VM-IP>
cd ~/etisalat
ls                                  # must show: airgap  ai-gateway-platform  bundle  config.env  values  zalando  DEPLOY.md
```
### B2. Check prerequisites (nothing has to be installed on this VM except the few standard tools below: `kubectl` and `helm` come inside the bundle)
**B2a. The tools this VM needs.** Run this block as written. It prints `ok` or `MISSING` for every tool:
```
for t in bash perl python3 openssl tar awk sed grep base64 ssh scp; do command -v $t >/dev/null && echo "ok $t" || echo "MISSING $t"; done
```
| Tool | Used for | Ubuntu 24.04 package | If it prints `MISSING` |
|---|---|---|---|
| `bash` | every script | `bash` (always there) | the VM is not a normal Linux server: use another VM |
| `perl` | fills the templates, patches charts | `perl-base` (always there) / `perl` | **install it** (below) |
| `python3` | key generation, Vault init/unseal, JSON | `python3` (there on every Ubuntu server image) | **install it** (below) |
| `openssl` | random keys, certificate checks | `openssl` | **install it** (below) |
| `tar` | chart patching | `tar` (always there) | **install it** (below) |
| `awk`, `sed`, `grep`, `base64` | text and encoding | `gawk`/`mawk`, `sed`, `grep`, `coreutils` (always there) | **install it** (below) |
| `ssh`, `scp` | loading the image tars on the workers (`NODE_LOAD_MODE="ssh"`) | `openssh-client` | **install it** (below) |
`kubectl` and `helm` are **not** in this list: they are in `bundle/tools/` and the scripts put them on the PATH themselves. `make`, `envsubst` and `skopeo` are NOT needed here. `airgap/deploy-all.sh check` (and `dry-run`) repeats this test and names every missing tool and its Ubuntu package at once.

**If a tool is missing** (an air-gapped VM has no internet, so use one of these):
1. **The VM's own OS media or internal package mirror** (normal for an Etisalat server): `sudo apt-get install -y <package>` (or `sudo dnf install <package>` on RHEL).
2. **Offline `.deb` files** (no mirror): on **any machine with internet that runs Ubuntu 24.04** (a VM or a container is fine), download the packages together with their dependencies, copy the folder to the install VM (USB / scp), and install them there:
   ```
   mkdir -p ~/os-debs && cd ~/os-debs
   apt-get update
   apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances perl python3 openssl tar gawk openssh-client | grep '^\w' | sort -u)
   tar -czf ~/os-debs.tgz -C ~ os-debs                       # copy os-debs.tgz to the install VM
   # on the install VM:
   tar -xzf os-debs.tgz && cd os-debs && sudo dpkg -i *.deb        # packages that are already installed are simply updated
   ```
   Run the `for t in ...` block again: every line must say `ok`.
3. The VM is not Ubuntu (for example RHEL): the same tools exist there under the same names (`perl`, `python3`, `openssl`, `tar`, `gawk`, `openssh-clients`); install them from the RHEL media.

**B2b. Package, cluster and storage checks.**
```
ls ai-gateway-platform/helm/tokenfactory/templates/ingress.yaml bundle/tars/INDEX bundle/tools/helm bundle/tools/kubectl bundle/jars/*.jar
ls bundle/tars/*.tar | wc -l                      # must print 56
ls bundle/charts/hpe-csi-driver-3.2.0.tgz         # the HPE CSI chart (storage)
cp <path-of-the-cluster-admin-kubeconfig> ~/etisalat.kubeconfig && chmod 600 ~/etisalat.kubeconfig
export PATH=~/etisalat/bundle/tools:$PATH
kubectl --kubeconfig ~/etisalat.kubeconfig get nodes -o wide        # all 7 Ready (3 masters .21-.23, 4 workers .24-.27); the API answers on the VIP 172.22.100.240
kubectl --kubeconfig ~/etisalat.kubeconfig get ingressclass           # the existing controller's class (INGRESS_CLASS in config.env)
kubectl --kubeconfig ~/etisalat.kubeconfig get svc -A | grep -i ingress        # its Service: EXTERNAL-IP 172.22.100.241 (MetalLB)
kubectl --kubeconfig ~/etisalat.kubeconfig -n metallb-system get ipaddresspool 2>/dev/null       # pool 172.22.100.241-250
kubectl --kubeconfig ~/etisalat.kubeconfig get nodes --no-headers | grep -c ' Ready'      # >= 3
kubectl --kubeconfig ~/etisalat.kubeconfig get sc                    # existing StorageClasses (the storage for TokenFactory comes from the HPE X10000: STORAGE-HPE-CSI.md)
kubectl --kubeconfig ~/etisalat.kubeconfig describe node <worker> | grep -i taints     # workers must accept normal pods (Taints: <none>)
```
### B3. SSH from the VM to every worker (the image loader uses it) — passwordless `sudo` is required
```
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519      # only if the VM has no key yet
for ip in 172.22.100.24 172.22.100.25 172.22.100.26 172.22.100.27; do ssh-copy-id <ssh-user>@$ip; done
for ip in 172.22.100.24 172.22.100.25 172.22.100.26 172.22.100.27; do ssh -o BatchMode=yes <ssh-user>@$ip 'sudo -n true && which ctr && echo "$(hostname): ok"'; done
```
Every line must end with `<hostname>: ok`. If `ctr` is not found, containerd's CLI is missing: install `containerd` tools on that node or use another way to import the tars (B6b).
### B4a. TLS certificate and key
Your own files (PEM, certificate chain first): copy them to the VM and verify before you continue.
```
mkdir -p ~/etisalat-tls && cp <etisalat.crt> ~/etisalat-tls/tls.crt && cp <etisalat.key> ~/etisalat-tls/tls.key && chmod 600 ~/etisalat-tls/tls.key
openssl x509 -in ~/etisalat-tls/tls.crt -noout -subject -enddate                         # not expired
openssl x509 -in ~/etisalat-tls/tls.crt -noout -ext subjectAltName                       # must cover portal. admin. www. auth. api.<DOMAIN> (or *.<DOMAIN>)
[ "$(openssl x509 -in ~/etisalat-tls/tls.crt -noout -pubkey | openssl sha256)" = "$(openssl pkey -in ~/etisalat-tls/tls.key -pubout | openssl sha256)" ] && echo "cert and key match"
```
### B4b. Keycloak plugin jar — nothing to download, it is inside the bundle
* **What it is:** `keycloak-2fa-email-authenticator-26.6.1-KC26.8.0.jar` (Maven Central, `mesutpiskin`): the chart default (`keycloak.providers.plugins` in the chart's `values.yaml`). `tf-auth` needs it (it wires the email-OTP step and refuses to start without it). We do not build it. *Pairing rule:* the jar must match the Keycloak version of the chart you deploy. Chart 0.17.7 runs Keycloak **26.8.2** (image digest `sha256:3879c623…`), so the 26.8 jar above is the right one; the old `26.5.0-KC26.7.3` jar belongs to Keycloak 26.7 and must NOT be used. When you move to a newer chart, take the jar URL from that chart's `values.yaml` and put that file in `bundle/jars/` (the newest version in `bundle/jars/` is used).
* **Where it comes from:** step A5 downloads it on the Mac into `bundle/jars/`; the whole `bundle/` folder reaches the VM with A6. It is **not in the git repo** (the repo has no `bundle/`).
* **Check it on the VM** (size 92437 bytes):
  ```
  cd ~/etisalat/bundle/jars && ls -l *.jar && sha256sum *.jar
  # 0185f6ead8913792fdb4045cc0aef2753feb5cb71b9204372bf0d882f9435eb4  keycloak-2fa-email-authenticator-26.6.1-KC26.8.0.jar
  ```
  If the folder is empty (the download in A5 failed), open this URL on any machine with internet and put the file into `bundle/jars/`:
  `https://repo1.maven.org/maven2/io/github/mesutpiskin/keycloak-2fa-email-authenticator/26.6.1-KC26.8.0/keycloak-2fa-email-authenticator-26.6.1-KC26.8.0.jar`
  Without the jar `airgap/deploy-all.sh check` stops with *"no Keycloak jar in …/jars"*.
* **How Keycloak gets it in the air-gap:** `KEYCLOAK_JAR_URL` is **empty** in `config.env` (leave it empty; the Maven Central URL only works with internet). Phase `jar` of B7 puts the file into ConfigMap `keycloak-spi-jar` and serves it with **2 tiny busybox `httpd` pods behind Service `keycloak-spi`** in namespace `tokenfactory`. Every Keycloak pod (all 3 of the HA set) downloads it from there in its init container `fetch-providers` when it starts.
* **HA behaviour:** two jar pods, so one can fail. Running Keycloak pods are never affected. Only if **both** jar pods are down *and* a Keycloak pod restarts at that moment, that pod waits (`Init`) until a jar pod is back.
* **Your own server instead:** put its URL in `KEYCLOAK_JAR_URL` (it must serve that same file and be reachable from inside a pod); the `jar` phase then does nothing.
* **After B7** confirm: `kubectl -n tokenfactory get pods -l app.kubernetes.io/name=keycloak-spi` shows 2 pods Running (this in-cluster server has not yet been run on the real cluster — report it if not).


### B5. Fill in `config.env` (the ONLY file you edit)
```
nano config.env
```
Set exactly these lines (everything else already has the right default; the other variables are explained in `VALUES-GUIDE.md`):
```
export KUBECONFIG_FILE="/home/<vm-user>/etisalat.kubeconfig"
export NAMESPACE="tokenfactory"
export SINGLE_NODE="no"
export EXPOSE="loadbalancer"                   # MetalLB direct
export LB_INTERNAL="no"                        # (Azure-only flag)
export ENVOY_LB_IP="172.22.100.242"            # api. LoadBalancer IP: any FREE IP of the pool 172.22.100.241-250 (.241 = ingress controller). Check: kubectl get svc -A | grep 172.22.100.24
export BEHIND_CLOUDFLARE="no"                  # no Cloudflare: Envoy (api.) terminates TLS with TLS_CERT/TLS_KEY
export INGRESS_TLS="yes"                       # must stay yes
export INGRESS_TLS_SECRET="tf-etisalat-ingress-tls"
export INGRESS_CONTROLLER="existing"            # the cluster already runs Ingress-NGINX on 172.22.100.241: this package installs no controller
export INGRESS_CLASS="nginx"                    # kubectl get ingressclass  -> use the class name shown there
export TLS_CERT="/home/<vm-user>/etisalat-tls/tls.crt"
export TLS_KEY="/home/<vm-user>/etisalat-tls/tls.key"
export DOMAIN="<the Etisalat domain, e.g. tokenfactory.etisalat.ae>"
export STORAGE_BACKEND="hpe-x10000"            # storage = HPE Alletra Storage MP X10000 over NFSv4.1; the package installs the HPE CSI driver and creates the StorageClass. Read STORAGE-HPE-CSI.md first
export STORAGE_CLASS="hpe-standard-file"
export X10000_MGMT="<X10000 management IP or FQDN>"
export X10000_CLIENT_ID="<CSP client id from the storage admin>"
export X10000_ACL="172.22.100.24,172.22.100.25,172.22.100.26,172.22.100.27"    # clients allowed to mount the exports: the 4 workers
export X10000_ALLOW_EXPANSION="false"
export SECRETS_BACKEND="vault"                # secrets live in a DEDICATED HashiCorp Vault inside this cluster (installed by the package, like prod). VAULT-SECRETS.md. "kubernetes" = no Vault
export VAULT_STORAGE_SIZE="10Gi"
export VAULT_UI="true"                         # open the Vault web UI at https://vault.<DOMAIN> (needs DNS + a certificate that covers it); "false" = no UI. VAULT-SECRETS.md section 2b
export VAULT_UI_ALLOW="172.22.100.0/22"         # networks allowed to open the UI
export NODE_LOAD_MODE="ssh"
export NODES="<ssh-user>@172.22.100.24 <ssh-user>@172.22.100.25 <ssh-user>@172.22.100.26 <ssh-user>@172.22.100.27"
export SMTP_HOST="smtp.resend.com" ; export SMTP_PORT="465" ; export SMTP_USER="resend" ; export SMTP_SSL="true" ; export SMTP_STARTTLS="false"
export SMTP_PASSWORD="<the Resend API key>"
export SUPPORT_EMAIL="support@iamsaif.ai"      # the sender verified at Resend
```
**Vault:** `SECRETS_BACKEND="vault"` installs the Vault and fills it in phases `vault` and `secrets`. After B7, **copy `~/.etisalat-vault-init.json` (the unseal keys and root token) to a safe offline place**; Vault starts sealed after every restart and `airgap/deploy-all.sh vault` unseals it again (`VAULT-SECRETS.md`).
The X10000 client **secret** is not written in `config.env`; give it in the shell right before B7 (and before any run of the `storage` phase): `read -rs X10000_CLIENT_SECRET; export X10000_CLIENT_SECRET`. The storage team must first provide the items of `STORAGE-HPE-CSI.md` section 2 (management address, client ID + secret, capacity, NFS access for the workers).
`TF_TAG`, `BRAND_TAG`, `CHART_REF` are already filled (Part A). Replicas, CPU/RAM, Keycloak, Postgres and Envoy sizing are the `SIZING & HA` lines of the same file: their defaults are the **live `xailon-tf-prod` values** (Part D) and normally need no change. Nothing may still say `REPLACE_`:
```
grep -n REPLACE_ config.env | grep -v '^[0-9]*:#' || echo "config.env complete"
```
### B6. Dry-run — renders every chart offline and changes nothing on the cluster
```
airgap/deploy-all.sh dry-run
```
It must end with `dry-run PASSED`. If it stops with a `FATAL:` line, fix what it says and run it again.

### B6b. Images reach the nodes (done by the `images` phase of B7; shown here so you know what happens)
In `ssh` mode (set in B5) the VM copies the 56 tars to every worker with `scp` and runs `sudo ctr -n k8s.io images import` there. **No container image and no registry are needed.** After the `images` phase, on any worker:
```
sudo ctr -n k8s.io images ls -q | grep -c registry.etisalat.local          # must print 56 or more (digest-pinned images appear twice)
```
No SSH to the workers at all? Copy `bundle/tars/` to each worker by hand (USB/scp) and on **every** worker run `cd <folder-with-tars> && for f in *.tar; do sudo ctr -n k8s.io images import --all-platforms $f; done`; **then also tag the digest-pinned images** (the loader normally does this): on the VM `awk -F'|' '$3!=""{r=$2; sub(/:pinned-.*/,"",r); print "sudo ctr -n k8s.io images tag --force " $2 " " r "@sha256:" $3}' bundle/tars/INDEX > ~/tag-pins.sh`, copy `tag-pins.sh` to every worker and run `bash tag-pins.sh` there (prefer fixing SSH instead). Then run B7 without the `images` phase: `airgap/deploy-all.sh check prepare render ns jar pg secrets controllers ingress openmeter app verify`.

### B7. Deploy everything (one command)
```
airgap/deploy-all.sh all 2>&1 | tee ~/etisalat-deploy.log
```
Order, with what each prints: `check` → `prepare` → `render` → `ns` → **`images`** (loads all tars into every worker; ends with `ALL 56 IMAGES PRESENT`) → **`jar`** (hosts the Keycloak plugin jar in the cluster) → **`storage`** (HPE CSI driver + StorageClass on the X10000, see `STORAGE-HPE-CSI.md`) → **`vault`** (dedicated in-cluster HashiCorp Vault + Secrets Store CSI driver, initialized and unsealed, see `VAULT-SECRETS.md`) → `pg` (Postgres HA, waits for Running) → `secrets` → `controllers` (Envoy Gateway + AI Gateway) → `ingress` → `openmeter` (slowest, up to 60 min) → `app` → `verify`. Total 40–90 min. If anything fails, fix the cause and continue where it stopped:
```
airgap/deploy-all.sh --from <phase>        # e.g. --from openmeter
```
Never delete `~/.etisalat-service-keys.env` (created by the `secrets` phase; every upgrade needs the same values). Back it up now: `cp ~/.etisalat-service-keys.env <safe place>`.

### B8. DNS records and first login
`verify` printed both addresses. Create these DNS records (internal DNS or `/etc/hosts` of the clients):
| Name | IP |
|---|---|
| `portal.<DOMAIN>`, `admin.<DOMAIN>`, `www.<DOMAIN>`, `auth.<DOMAIN>` | `172.22.100.241` (existing Ingress-NGINX) |
| `api.<DOMAIN>` | `172.22.100.242` (Envoy, `ENVOY_LB_IP`) |
| `vault.<DOMAIN>` (only if `VAULT_UI="true"`) | `172.22.100.241` (the same ingress controller) |
Check without DNS first (replace `<DOMAIN>`):
```
for h in www portal admin; do curl -sk -o /dev/null -w "$h %{http_code}\n" --resolve $h.<DOMAIN>:443:172.22.100.241 https://$h.<DOMAIN>/; done        # 200 200 200
curl -sk --resolve auth.<DOMAIN>:443:172.22.100.241 https://auth.<DOMAIN>/auth/realms/master/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
curl -sk -o /dev/null -w "api %{http_code}\n" --resolve api.<DOMAIN>:443:172.22.100.242 https://api.<DOMAIN>/v1/models        # 401 without an API key = correct
kubectl --kubeconfig ~/etisalat.kubeconfig -n tokenfactory get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy         # EXTERNAL-IP 172.22.100.242
```
Admin login: user `admin@<DOMAIN>` (`PLATFORM_ADMIN_EMAIL`), password:
```
kubectl --kubeconfig ~/etisalat.kubeconfig -n tokenfactory get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d; echo
```

### B9. Check it is healthy
```
export KUBECONFIG=~/etisalat.kubeconfig; export PATH=~/etisalat/bundle/tools:$PATH
kubectl get pods -A | grep -v -E 'Running|Completed'          # nothing important should be listed
kubectl -n tokenfactory get postgresql pgdb                    # Running
kubectl -n tokenfactory exec pgdb-0 -c postgres -- patronictl list      # 1 Leader + 2 Replicas
kubectl -n tokenfactory get sts keycloak                       # READY 3/3
kubectl -n tokenfactory get deploy                             # every tf-* READY 3/3 (docs/site 1/1), envoy 6/6
kubectl -n tokenfactory get ingress tokenfactory
kubectl -n tokenfactory get pods -l app.kubernetes.io/name=keycloak-spi      # 2 pods Running
kubectl -n tokenfactory logs deploy/tf-ledger --tail=200 | grep -i leader      # one replica logs "this replica is the tf-ledger singleton leader"
kubectl -n tokenfactory get secret tf-etisalat-ingress-tls
kubectl -n vault get pods                                      # vault-0 Running, vault-csi-provider pods Running
kubectl -n vault exec vault-0 -- vault status | grep -E "Initialized|Sealed"       # Initialized true, Sealed false
kubectl -n tokenfactory get secret tokenfactory-secrets        # synced from Vault (19 keys)
```
### B10. Etisalat brand + feature gate (the verification the developer's overlay asks for). The scripts are in the repo copy; they need `curl` and `python3`, and they read the release `tokenfactory` in namespace `tokenfactory`. The lab has no DNS, so first map the names on this VM (real Etisalat: DNS exists, skip these two lines):
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


### B-LAB. Only for the Azure lab (skip on the real cluster)
The lab (1 node, no internet, no X10000, no MetalLB) has its own step-by-step guide with exact commands: **`DEPLOY-LAB.md`**. Do not use the settings of this Part B there.

---
## PART D — Sizing and HA: all in `config.env` (section "SIZING & HA")
Layout is the same as `xailon-tf-prod`: **`tokenfactory`** = everything of TokenFactory incl. the Postgres cluster `pgdb`; **`postgres`** = Zalando operator only; **`openmeter`** = OpenMeter.
**Every default below is the live value of `xailon-tf-prod`** (read from that cluster on 10 Nov 2026: replicas, CPU/RAM, Keycloak, Envoy, Ingress), so Etisalat starts identical to Xailon. Postgres: Xailon uses Azure Postgres 16 (managed), Etisalat runs Zalando Patroni with the same major version 16.
| What | `config.env` variable | Default (= Xailon) |
|---|---|---|
| **Envoy** pods (all inference load) | `ENVOY_REPLICAS`, `ENVOY_PDB_MIN_AVAILABLE` | **6**, 1 PDB; **no CPU/RAM requests or limits** on the Envoy container (set in the template; change via `CUSTOM_VALUES_YAML`) |
| **Keycloak HA** | `KEYCLOAK_REPLICAS`, `KEYCLOAK_MEM_REQUEST/LIMIT`, `KEYCLOAK_HEAP`, `KEYCLOAK_ANTIAFFINITY` | **3**, 1Gi/2Gi (memory only), `-Xms512m -Xmx2g`, `required` (one pod per node; forced `preferred` when `SINGLE_NODE=yes`). Infinispan cache, PDB `maxUnavailable: 1` |
| **Postgres HA** (Zalando `pgdb`, external for the app) | `PG_VERSION`, `PG_INSTANCES`, `PG_VOLUME_SIZE`, `PG_CPU_REQUEST/LIMIT`, `PG_MEM_REQUEST/LIMIT`, `PG_MAX_CONNECTIONS` | 16, 3, 20Gi, 1/4, 2Gi/8Gi, 300 |
| **tf-\* services** (replicas + CPU/RAM, one line each) | `SVC_TF_ACCOUNTS`, `SVC_TF_ADMIN_WEB`, `SVC_TF_AUTH`, `SVC_TF_BABEL`, `SVC_TF_CONTROL`, `SVC_TF_DOCS_WEB`, `SVC_TF_LEDGER`, `SVC_TF_OPS`, `SVC_TF_PORTAL_WEB`, `SVC_TF_RELAY`, `SVC_TF_SHIM`, `SVC_TF_SITE_WEB`, `SVC_TF_WARDEN` | see the table below |
| OpenFGA / MinIO / Redis resources | `RES_OPENFGA`, `RES_MINIO`, `RES_REDIS` | `- 64Mi - 256Mi`, `50m 128Mi 300m 512Mi`, `100m 1Gi 1 4Gi` |
| ClickHouse disk | `CH_DATA_SIZE`, `CH_LOG_SIZE` | 50Gi, 5Gi |
| Ingress on/off, TLS secret | `INGRESS_ENABLED`, `INGRESS_TLS_SECRET` | true, `tf-etisalat-ingress-tls` |
| **anything else** (annotations, extra hosts, SMTP details, …) | `CUSTOM_VALUES_YAML` (raw YAML, last section of `config.env`) | empty |

Format of an `SVC_*` line: `"<replicas> <cpu-request> <mem-request> <cpu-limit> <mem-limit>"`; a `-` leaves that value out; `"<replicas> none"` means no requests and no limits at all. Defaults:
| Service | `SVC_*` default | Meaning (same as `xailon-tf-prod`) |
|---|---|---|
| tf-accounts | `3 50m 64Mi 200m 256Mi` | 3 pods, 50m/64Mi requests, 200m/256Mi limits |
| tf-admin-web, tf-auth, tf-control, tf-ledger, tf-relay, tf-warden | `3 none` | 3 pods, no requests/limits |
| tf-babel | `3 25m 32Mi 300m 256Mi` | |
| tf-ops | `3 20m 48Mi 250m 128Mi` | |
| tf-portal-web | `3 50m 32Mi 200m 1Gi` | |
| tf-shim | `3 25m 256Mi 1 1Gi` | |
| tf-docs-web | `1 50m 96Mi 300m 256Mi` | only deployed when `DOCS_WEB="yes"` |
| tf-site-web | `1 50m 64Mi 300m 256Mi` | |
tf-ledger runs 3 pods with leader election (one pod runs the singleton loops, chosen by a Postgres advisory lock), a PDB (`minAvailable: 1`) and a RollingUpdate strategy, as on Xailon. Ingress: class `nginx` (F5), annotations `client-max-body-size 128m`, `proxy-buffer-size 16k`, `proxy-buffers 8 16k`, connect/read/send timeouts `75s/600s/600s`, `ssl-redirect "false"` only when `BEHIND_CLOUDFLARE="yes"`, TLS from your certificate: the same as Xailon.
**How to change a value later:** edit the line in `config.env`, then `airgap/deploy-all.sh dry-run` and `airgap/deploy-all.sh render ns app` (Postgres lines: `airgap/deploy-all.sh pg`). Example, 4 relay pods with more memory: `export SVC_TF_RELAY="4 100m 512Mi 2 2Gi"`. Check what Helm will use: `grep -A6 '^tf-relay:' rendered/services.yaml`.

## PART E — If something goes wrong
| You see | Do |
|---|---|
| `01-bundle-connected.sh` prints nothing and exits | old `env.sh` (a failing `[ -d tools ] && …` under `set -e`). Use the current scripts; test with `bash -x airgap/01-bundle-connected.sh \| head -30` |
| `01`: `unauthorized` from ghcr.io | `skopeo login ghcr.io -u <user>` with a PAT that has `read:packages` for Infinia-Technology. The token saved by Docker on the Mac was invalid |
| `01`: `Docker references with both a tag and digest are not supported` | old script. Current one strips the tag for `@sha256` images |
| `01`: `FAILED images … minio` | the MinIO image is `ghcr.io/infinia-technology/ai-gateway-platform/minio@sha256:…`: same GHCR login/PAT as the tf-* images (A2) |
| `01`: `helm: cannot execute binary file` on the Mac | `bundle/tools/helm` is a Linux binary; current `env.sh` only puts it on PATH on Linux |
| `FATAL: missing tool: make` / `envsubst` / `skopeo` | old script versions. The current scripts need only `perl python3 openssl tar`; `kubectl` + `helm` come from `bundle/tools` |
| `FATAL: config.env still has REPLACE_` | fill that line |
| `check`: `no Keycloak jar in …/jars` | `bundle/jars/` is empty: download the jar (URL in B4) into it, or rebuild the bundle (A5) |
| `check`: `repo not found` / `prepare`: `ingress.yaml is missing` | the chart checkout is missing or not the pinned release: run `airgap/00-fetch-chart.sh` on the Mac and copy the folder again (A3, A6) |
| `check`: `INGRESS_TLS must be yes` | this package deploys the Ingress with TLS only; set `INGRESS_TLS="yes"` and give `TLS_CERT`/`TLS_KEY` |
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
| 4 | The Ingress template (Xailon PR #678) was missing on `develop` | merged since: chart 0.17.7 contains `templates/ingress.yaml`. It refuses an Ingress without `ingress.tls[]` (TOKE75R-1389), which is why this package is TLS-only; the old patch step was removed |
| 5 | Keycloak downloads its SPI jar from Maven Central on every start | the jar matching the chart's Keycloak (26.8.2 -> `26.6.1-KC26.8.0`) is bundled (`bundle/jars/`) and hosted inside the cluster by phase `jar` (ConfigMap + busybox httpd + Service `keycloak-spi`); `KEYCLOAK_JAR_URL` stays empty, or points to your own server |
| 6 | GeoIP sidecar downloads from GitHub, NGINX controller phones home | GeoIP off (`tf-ledger.geoip.enabled: false`), controller telemetry off |
| 7 | MinIO's official image no longer exists on Docker Hub/quay | chart 0.17.x uses Infinia's own MinIO image on GHCR (digest-pinned); bundled like the tf-* images, no workaround needed |
| 8 | No Etisalat-branded `tf-docs-web` image | default-brand image stored under the branded tag (needed by `tf-accounts` init `legal-src`); `DOCS_WEB=no`. **Ask the developer for an Etisalat docs build** |
| 9 | `preflight.sh`'s OpenMeter probe cannot pass on a NetworkPolicy-enforcing cluster | `deploy-all.sh app` runs its own checks and calls `install.sh` with `SKIP_PREFLIGHT=1` |
| 10 | `install.sh` prints the helm command (with `--set` secrets) into the log | service keys go in a 0600 values file (`rendered/service-keys.yaml`) |
| 11 | `make`, `envsubst`, `skopeo` are not on a fresh VM | not needed any more (perl-based `envsub`, `install.sh` called directly; `kubectl`/`helm` in `bundle/tools`) |
| 12 | A 1-node cluster cannot hold 3 Postgres instances (anti-affinity) | `SINGLE_NODE=yes` → 1 instance, node-count check skipped (lab only) |
| 13 | On AKS the LoadBalancer Services would get public IPs | `LB_INTERNAL=yes` adds the Azure internal-LB annotation to Envoy and NGINX |
| 14 | `tf-ledger` could not run >1 replica (no leader election, 5 unguarded loops) | fixed upstream in 0.17.4 (Postgres advisory-lock leader election). Fresh installs run `TF_LEDGER_REPLICAS=3` with PDB + RollingUpdate, as tf-stage and Xailon do |
| 15 | Postgres `pg_hba` allows `0.0.0.0/0 md5` (copied from prod) | tighten to the pod CIDR for production |
| 16 | No Postgres backup inside an air-gap | not configured — plan `pg_dump`/WAL-G to an internal object store before production |

## PART I — The developer's `values-tf-etisalat.yaml`: where each `TODO(owner)` is filled in this package
`ai-gateway-platform/helm/tokenfactory/values-tf-etisalat.yaml` (branch `stage`, pinned commit `CHART_REF`, chart 0.17.7) stays untouched. It is layer 1; our files are layer 2. Order Helm applies: chart `values.yaml` → `values-tf-etisalat.yaml` → `rendered/umbrella.yaml` → `rendered/lb-umbrella.yaml` → `rendered/service-keys.yaml`.

| `TODO(owner)` in the developer's file | Filled here by |
|---|---|
| `brandImages` (placeholder `0.17.0-etisalat-0000000`) | `config.env` → `BRAND_TAG` |
| `global.image.tag` (empty on purpose) | `config.env` → `TF_TAG` |
| `global.urls.*` (`etisalat.example.com`) | `config.env` → `DOMAIN` (creates `api. auth. portal. admin. www.`) |
| `supportEmail`, `platformAdminEmail`, SMTP host/port/user | `config.env` → `SUPPORT_EMAIL`, `PLATFORM_ADMIN_EMAIL`, `SMTP_HOST/PORT/USER/PASSWORD` |
| `stripePublishableKey` (empty) | leave empty — `billing.topup` is off in this brand |
| Persona CDD (KYC) | off: `global.cdd` stays disabled in this deployment (it would need Persona templates, API key, webhook and outbound `api.withpersona.com`) |
| datastores ("inherited: external") | set **explicitly** in `umbrella.values.yaml.tmpl` (`global.postgres`, `keycloak.postgres`, `openfga.postgres` → Zalando `pgdb`) |
| replicas / PDB / sizing | `umbrella.values.yaml.tmpl` (3 replicas, Keycloak HA, Envoy PDB) |
| `OPENMETER_URL` namespace | default `openmeter` is kept (our OpenMeter release uses it) |
| `tf-gateway-resources.tls` (wildcard + `tf-etisalat-tls`) + Envoy Service | `config.env` → `DOMAIN`, `TLS_CERT`, `TLS_KEY`; `LB_INTERNAL` for Azure |
| `storageClass` | `config.env` → `STORAGE_CLASS` |
| Ingress (not in the developer's file) | `umbrella.values.yaml.tmpl` → `ingress:` — see Part J |

**What comes unchanged from the developer's Etisalat overlay (we do not touch it):** the whole `brandPack` (Etisalat theme, copy, colours, feature ceiling: sign-up on, social login and top-up off), `keycloakSecrets.generate: true`, `secrets.existingSecret: tokenfactory-secrets`, Keycloak in-cluster TLS (`keycloak-tls`, `keycloak-ca`, HTTPS upstreams of the portal/admin pods), the complete `tf-ledger.env` list (OpenMeter URL, freshness, replay horizon), `tf-warden`/`tf-relay`/`tf-shim` sizing, Redis 10Gi/3gb, and the `tf-gateway-resources` TLS + Envoy LoadBalancer port patch.
**What this package adds on top (layer 2):** the **Ingress** (portal/admin/www/auth), **Keycloak HA** (3 replicas, Infinispan, PDB, anti-affinity), **Postgres** (Zalando `pgdb`, explicit external blocks for the app, Keycloak and OpenFGA), registry prefix / image tags, URLs from `DOMAIN`, SMTP, replicas and resources of every service, Envoy replicas + PDB, GeoIP off, and the lab flags.
The Ingress template (Xailon PR #678) is part of the chart since 0.17.x; the developer's Etisalat file still says "no Ingress objects", so this package adds the `ingress:` block in layer 2 (always with TLS, see Part J).
This package is pinned to chart **0.17.7** (`CHART_REF` in `config.env`, branch `stage`). To move to a newer release: change `TF_TAG`, `BRAND_TAG` and `CHART_REF` together, run `airgap/00-fetch-chart.sh`, rebuild the bundle (A5), run `dry-run` and fix whatever new validators ask for. Check that every image the new chart renders is in `airgap/images.txt` (render all releases with `helm template` and compare); a missing digest-pinned image would otherwise surface only as `ErrImagePull` in the air-gap.

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
| Different ingress controller | set `INGRESS_CLASS` in `config.env` (and `INGRESS_CONTROLLER`). The Ingress carries BOTH annotation sets (`nginx.org/*` for the F5 controller and `nginx.ingress.kubernetes.io/*` for the community Ingress-NGINX, each ignored by the other), so the body-size, buffer and timeout settings apply to either. Old note: community ingress-nginx needs its own `nginx.ingress.kubernetes.io/*` equivalents (`proxy-body-size`, `proxy-buffer-size`, `proxy-read-timeout`) |
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
| New image version | rebuild bundle with new `TF_TAG` (Part A: change `TF_TAG`, `BRAND_TAG`, `CHART_REF`), copy, then `airgap/deploy-all.sh images render app` |
| Envoy replicas / limits | template `tf-gateway-resources.envoyProxy…envoyDeployment` |
| Postgres size / instances / parameters | `zalando/charts/pgdb/values.yaml`, then `deploy-all.sh pg` (disk can only grow) |
| A value that has no key in the template yet | add the key exactly as it appears in the chart's `values.yaml` (see `ai-gateway-platform/helm/tokenfactory/values-tf-prod.yaml` for every available key and its comment); lists such as `tf-ledger.env` are **replaced wholesale** — copy the whole list from `values-tf-etisalat.yaml` and change the one entry |

## PART K — `tokenfactory-secrets`: what the developer's overlay requires, and what `deploy-all.sh secrets` creates
> With `SECRETS_BACKEND="vault"` (default) the values below are generated into the dedicated Vault (`secret/tokenfactory`) and synced into the Secret by the Secrets Store CSI driver: see `VAULT-SECRETS.md`. The key list and meanings are the same; "created by the script" means "written to Vault by the script".
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
| `persona-*`, `cdd-email-hmac-key` | only if Persona CDD (KYC) is turned on (off here) | no |
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
| `ghcr.io/infinia-technology/ai-gateway-platform/tf-accounts:0.17.7-160792b` | `$REGISTRY/infinia-technology/ai-gateway-platform/tf-accounts:0.17.7-160792b` |
| `docker.io/library/redis@sha256:c5d34a…` (digest-pinned) | `$REGISTRY/redis:pinned-c5d34a…` |
| `quay.io/keycloak/keycloak@sha256:3879c6…` (digest-pinned) | `$REGISTRY/keycloak/keycloak:pinned-3879c6…` (digest preserved, so the chart's `@sha256` reference resolves) |
| `ghcr.io/zalando/spilo-17:4.0-p2` | `$REGISTRY/zalando/spilo-17:4.0-p2` |
Run it as part of the normal flow or alone:
```
cd ~/etisalat
airgap/deploy-all.sh images          # IMAGE_MODE=registry -> airgap/02-push-registry.sh (56 images)
```
It ends with `registry push complete` after proving that the `@sha256` images (Keycloak, OpenFGA, Postgres, Redis, MinIO, curl, busybox 1.36, OpenMeter) resolve **by digest**. Plain `docker pull/tag/push` would change those digests and the pods would never start — always push with this script.
Harbor: the project must exist first (`unauthorized`/`project not found` otherwise), and the three digest-pinned images need the project to allow tags that look like `pinned-<digest>` (no tag-immutability rule that blocks them).

**L5. Verify the registry before deploying**
```
curl -u "$REGISTRY_USER:$REGISTRY_PASS" https://harbor.etisalat.com/v2/_catalog               # lists repositories (Harbor: use its UI/API per project)
skopeo inspect --creds "$REGISTRY_USER:$REGISTRY_PASS" docker://$REGISTRY/infinia-technology/ai-gateway-platform/tf-auth:0.17.7-160792b | head -5
# from a node: it can really pull
sudo crictl pull --creds "$REGISTRY_USER:$REGISTRY_PASS" $REGISTRY/alpine:3.22
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

## PART M — OPTIONAL: Cloudflare tunnel instead of MetalLB (not used for Etisalat)
> Etisalat uses **MetalLB direct** (B5/B8). Use this part only if you later put a Cloudflare tunnel in front: set `EXPOSE="clusterip"`, `BEHIND_CLOUDFLARE="yes"`, `ENVOY_LB_IP=""` and run `airgap/deploy-all.sh render ns app`.
Cloudflare terminates TLS and forwards plain HTTP through a `cloudflared` tunnel. **`cloudflared` is not part of this package or of the chart** (in prod it is "an out-of-band in-cluster install"); Etisalat installs it the same way as prod, with the public hostnames mapped to in-cluster Services. The tunnel pods need outbound access to Cloudflare. After `deploy-all.sh all`, the `verify` phase prints the exact targets; typically:
| Public hostname (Cloudflare) | Service URL for the tunnel | What answers |
|---|---|---|
| `api.<DOMAIN>` | `http://<envoy-service>.tokenfactory.svc.cluster.local:8080` | Envoy AI Gateway (inference API) |
| `portal.<DOMAIN>`, `admin.<DOMAIN>`, `www.<DOMAIN>`, `auth.<DOMAIN>` | `http://172.22.100.241:80` (the existing Ingress-NGINX on MetalLB; or its in-cluster Service `<svc>.<ns>.svc.cluster.local:80` from `kubectl get svc -A \| grep -i ingress`; with `INGRESS_CONTROLLER="install"` it is `http://nginx-ingress-controller.nginx-ingress.svc.cluster.local:80`) | NGINX Ingress → `tf-portal-web`, `tf-admin-web`, `tf-site-web`, `keycloak-edge` (routes by host name; the tunnel must keep the original `Host`, which is cloudflared's default) |
Find the Envoy Service name: `kubectl -n tokenfactory get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy`. (tokenfactory-prod maps each hostname straight to its Service, e.g. `www` → `tf-site-web:80`; mapping the four web hostnames to the ingress instead is equivalent and keeps the host routing in the chart.)
**With Ingress TLS** (default here) the portal/admin/www/auth targets can also be `https://172.22.100.241:443` (set the tunnel's `noTLSVerify` or `originServerName` because the in-cluster name is not in your certificate, and use Cloudflare SSL mode *Full*/*Full (strict)*); the plain `http://…:80` targets above keep working because the redirect is off.
Checks after the tunnel is up: `curl -s -o /dev/null -w '%{http_code}\n' https://portal.<DOMAIN>/` → 200; `curl -s https://auth.<DOMAIN>/auth/realms/master/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'` → `https://auth.<DOMAIN>/auth/realms/master`; `curl -s -o /dev/null -w '%{http_code}\n' https://api.<DOMAIN>/v1/models` → 401 without a key.
**`api.<DOMAIN>`** goes straight to Envoy over HTTP :8080 (like Xailon, where `api.` bypasses nginx).
The real client IP comes from Cloudflare's `Cf-Connecting-Ip` header, which is only trustworthy while Cloudflare is the **only** way into Envoy — do not expose the Envoy or ingress Services any other way (no NodePort/LoadBalancer) while `BEHIND_CLOUDFLARE="yes"`.

## What was verified in the lab (5 Nov 2026, chart 0.17.2)
Run on `aks-etisalat-test` (1 node, no internet) exactly as above: all 38 images loaded from tars (`ALL 38 IMAGES PRESENT`), Postgres Patroni leader Running, Keycloak 3/3 with one Infinispan cluster of 3 members, 3× Envoy, all tf-* services Ready, OpenMeter (Kafka 3, API 2, ClickHouse, Redis) Running; `www`, `portal`, `admin` → HTTP 200 through the NGINX ingress, Keycloak issuer `https://auth.etisalat.lab/auth/realms/master`, `api` via Envoy → 401 without a key (correct). Digest-pinned images (`@sha256`) start from the node tars.
**Chart 0.17.7 (10 Nov 2026):** verified OFFLINE only: `airgap/deploy-all.sh dry-run` passes (all releases render with `helm template`, TLS Ingress), every image the rendered releases reference is in `airgap/images.txt` and was checked to exist at its source. It has NOT yet been installed on a cluster; treat the first run as a test and report the first failing step.
Known gaps: (1) no Etisalat-branded `tf-docs-web` image exists, so the default-brand image is stored under the branded tag (legal pages show default-brand text; docs site stays off, `DOCS_WEB=no`) — ask the developer to run the Etisalat docs build; (2) Postgres runs 1 instance in the lab (`SINGLE_NODE=yes`), HA needs ≥ 3 nodes.

> Status of this document: image loading from a tar into the lab node was proven with a test image; the steps above were run end to end in the lab. Report the first failing step with its output.
