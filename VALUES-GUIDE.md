# VALUES-GUIDE — where every value is set (everything comes from `config.env`)

## 0. The one rule
**All site-specific and sizing values are set in `config.env`.** You do not edit a template for normal changes.
For anything `config.env` has no variable for, put raw YAML into **`CUSTOM_VALUES_YAML`** (last section of `config.env`). It is applied as the last values layer of the TokenFactory release.

| File | Role | Edit it? |
|---|---|---|
| `config.env` | **all** custom values (tags, domain, SMTP, cert, replicas, Keycloak/Postgres/Envoy sizing, namespace, `CUSTOM_VALUES_YAML`) | **yes — this is the only file you edit** |
| `values/umbrella.values.yaml.tmpl` | wires `config.env` into the chart; holds the tokenfactory-prod per-service CPU/RAM | only to change a fixed default permanently |
| `ai-gateway-platform/helm/tokenfactory/values-tf-etisalat.yaml` | the developer's Etisalat overlay (brand, features, Keycloak TLS, tf-ledger env …) | **never** |

Order Helm applies (later wins): chart `values.yaml` → developer's `values-tf-etisalat.yaml` → `rendered/umbrella.yaml` (from our template + `config.env`) → `rendered/lb-umbrella.yaml` → **`rendered/custom.yaml` (= `CUSTOM_VALUES_YAML`)** → `rendered/service-keys.yaml`.
Location: Mac `~/Downloads/ethisalat/config.env`; install VM `~/etisalat/config.env`. Values are rendered at deploy time, so editing the VM copy directly is fine.

## 1. Namespaces (as in tokenfactory-prod)
| Namespace | Contains |
|---|---|
| `tokenfactory` (`NAMESPACE`) | everything of TokenFactory: tf-* services, Keycloak (HA), Redis, MinIO, OpenFGA, the Ingress, the Secrets, and the Postgres cluster **`pgdb`** (external Postgres for the app, 3 instances) |
| `postgres` | the Zalando operator only |
| `openmeter` | OpenMeter (Kafka, ClickHouse, Redis, Svix, API) — uses `pgdb` (databases `openmeter`, `svix`) |
| `envoy-gateway-system`, `envoy-ai-gateway-system`, `nginx-ingress` | Envoy / AI Gateway controllers, NGINX ingress controller |

## 2. `config.env` — every variable
| Variable | Default | Sets | Developer-overlay key |
|---|---|---|---|
| `TF_TAG` | `0.17.7-160792b` | tf-* image tag (`<chart version>-<sha>`) | `global.image.tag` |
| `CHART_REPO`, `CHART_REF` | `Infinia-Technology/ai-gateway-platform`, commit `644da68…` (branch `stage`, chart 0.17.7) | which chart checkout `airgap/00-fetch-chart.sh` fetches; bump together with `TF_TAG` | – |
| `BRAND_TAG` | `0.17.0-etisalat-6b27a33` | Etisalat web images | `global.brandImages.*.tag` |
| `IMAGE_MODE`, `REGISTRY`, `REGISTRY_USER/PASS` | `tar`, `registry.etisalat.local` | how images reach nodes / registry prefix | `global.image.registry` |
| `NODE_LOAD_MODE`, `NODES` | `pod` (lab) / `ssh` (real) | tar loading | – |
| `KUBECONFIG_FILE`, `NAMESPACE` | `~/etisalat.kubeconfig`, `tokenfactory` | cluster access, namespace | – |
| `SINGLE_NODE`, `LB_INTERNAL` | `no`, `no` | 1-node lab (1 Postgres instance) / Azure private LBs | – |
| **`SECRETS_BACKEND`**, `VAULT_NAMESPACE`, `VAULT_STORAGE_SIZE`, `VAULT_INIT_FILE` | `vault`, `vault`, `10Gi`, `~/.etisalat-vault-init.json` | `vault` = a dedicated HashiCorp Vault inside the cluster holds the secrets and the Secrets Store CSI driver syncs them into `tokenfactory-secrets` (like prod); `kubernetes` = the package creates the Secret directly. The init file (unseal keys + root token) must be backed up offline | `vaultSync.*` |
| `VAULT_UI`, `VAULT_HOST`, `VAULT_UI_ALLOW` | `true`, empty (= `vault.<DOMAIN>`), `172.22.100.0/22` | `true` opens the Vault web UI at `https://vault.<DOMAIN>` through the cluster's Ingress-NGINX with TLS and an IP allowlist (DNS and a certificate covering the name are needed); `false` = no UI, no ingress | Ingress `vault` in namespace `vault` |
| **`STORAGE_BACKEND`**, `STORAGE_CLASS` | `hpe-x10000`, `hpe-standard-file` | `hpe-x10000` = the package installs the HPE CSI driver and creates the StorageClass on the Alletra X10000 (NFSv4.1); `existing` = use a StorageClass that already exists | `global.storageClass`, `pgdb volume.storageClass` |
| `X10000_MGMT`, `X10000_CLIENT_ID`, `X10000_ACL`, `X10000_ALLOW_EXPANSION` | – / – / the 4 worker IPs / `false` | X10000 management address, CSP client id (the **secret** is exported in the shell: `X10000_CLIENT_SECRET`), who may mount the exports, volume expansion | Secret `hpe-backend`, StorageClass parameters |
| `DOMAIN` | – | creates `api. auth. portal. admin. www.<DOMAIN>` | `global.urls.*` |
| `SUPPORT_EMAIL`, `PLATFORM_ADMIN_EMAIL` | `support@iamsaif.ai` (Resend-verified, as prod) / `admin@<DOMAIN>` | sender, super-admin login | `global.supportEmail`, `tf-auth…smtp.from`, `…platformAdminEmail` |
| **`BEHIND_CLOUDFLARE`** | `yes` | `yes` = like prod: Cloudflare terminates TLS, **no certificate**, plain HTTP inside, `Cf-Connecting-Ip` trusted (Envoy + warden); `no` = Envoy (api.) terminates TLS itself | `tf-gateway-resources.tls.enabled`, `clientIPHeader`, `tf-warden.trustedClientIPHeader`, `ingress.tls` |
| **`INGRESS_CONTROLLER`**, `INGRESS_CLASS` | `existing`, `nginx` | `existing` = the cluster already runs an Ingress-NGINX (Etisalat: MetalLB `172.22.100.241`), nothing is installed and `check` verifies the IngressClass; `install` = this package installs the F5 controller | `ingress.className`, `controller.ingressClass` |
| `ENVOY_LB_IP` | empty | fixed LoadBalancer IP for `api.` (only with `EXPOSE=loadbalancer` + MetalLB; Etisalat pool `172.22.100.241-250`) | `…envoyService.loadBalancerIP` |
| **`EXPOSE`** | `clusterip` | `clusterip` = Envoy and ingress Services are ClusterIP (the Cloudflare tunnel reaches them); `loadbalancer` = LoadBalancer Services | `…envoyService.type`, `controller.service.type` |
| **`INGRESS_TLS`**, `INGRESS_TLS_SECRET` | `yes`, `tf-etisalat-ingress-tls` | **must be `yes`**: the Ingress always gets a `tls:` block from your cert (Xailon style); chart >= 0.17 refuses a plain-HTTP Ingress, and `deploy-all.sh check` stops on `no` | `ingress.tls` |
| `TLS_CERT`, `TLS_KEY` | – | your PEM certificate + key → TLS Secret for the Ingress (and for Envoy when `BEHIND_CLOUDFLARE=no`) | `ingress.tls[].secretName`, `tf-gateway-resources.tls.certSecretName` |
| `SMTP_HOST/PORT/USER/SSL/STARTTLS/PASSWORD` | Resend as prod: `smtp.resend.com`/`465`/`resend`/`true`/`false` + the Resend API key | mail relay (needs outbound 465 to Resend) | `tf-auth.config.keycloak.smtp.*` |
| `KEYCLOAK_JAR_URL` | empty | empty = the installer hosts the bundled jar inside the cluster (recommended); or your own internal URL | `keycloak.providers.plugins[0].url` |
| `CH_DATA_SIZE`, `CH_LOG_SIZE` | `50Gi`, `5Gi` | ClickHouse disks | – |
| `DOCS_WEB` | `no` | docs site (no Etisalat docs image yet) | `global.brandImages.docs` |
| `PG_OPERATOR_MODE` | `install` | install the Zalando operator or reuse an existing one | – |
| **`ENVOY_REPLICAS`** | **`6`** | Envoy data-plane pods (**minimum 6**; prod runs 10). Envoy has **no CPU/RAM requests or limits** (same as prod — it takes all the inference load) | `tf-gateway-resources.envoyProxy…replicas` |
| `ENVOY_PDB_MIN_AVAILABLE` | `1` | Envoy PodDisruptionBudget | `…envoyPDB.minAvailable` |
| **`KEYCLOAK_REPLICAS`** | **`3`** | Keycloak HA pods (Infinispan cluster) | `keycloak.replicaCount` |
| `KEYCLOAK_MEM_REQUEST/LIMIT`, `KEYCLOAK_HEAP`, `KEYCLOAK_ANTIAFFINITY` | `1Gi`/`2Gi`, `-Xms512m -Xmx2g …`, `required` | as xailon-tf-prod (memory only; one pod per node) | `keycloak.resources`, `jvmHeapOpts`, `affinity` |
| `PG_VERSION`, **`PG_INSTANCES`** | `16`, **`3`** | Postgres major version (same as Xailon's Azure Postgres 16) and HA instances (forced to 1 by `SINGLE_NODE=yes`) | – (pgdb chart) |
| `PG_VOLUME_SIZE`, `PG_CPU_REQUEST/LIMIT`, `PG_MEM_REQUEST/LIMIT`, `PG_MAX_CONNECTIONS` | `20Gi`, `1`/`4`, `2Gi`/`8Gi`, `300` | Zalando pgdb sizing | – (pgdb chart) |
| **`SVC_TF_*`** (13 lines: `SVC_TF_ACCOUNTS`, `SVC_TF_ADMIN_WEB`, `SVC_TF_AUTH`, `SVC_TF_BABEL`, `SVC_TF_CONTROL`, `SVC_TF_DOCS_WEB`, `SVC_TF_LEDGER`, `SVC_TF_OPS`, `SVC_TF_PORTAL_WEB`, `SVC_TF_RELAY`, `SVC_TF_SHIM`, `SVC_TF_SITE_WEB`, `SVC_TF_WARDEN`) | the live `xailon-tf-prod` values, e.g. `"3 50m 64Mi 200m 256Mi"` or `"3 none"` | replicas + CPU/RAM of each service: `"<replicas> <cpu-req> <mem-req> <cpu-lim> <mem-lim>"`, `-` leaves one out, `none` = no requests/limits (tf-ledger = 3 with leader election) | `tf-*.replicas`, `tf-*.resources` |
| `RES_OPENFGA`, `RES_MINIO`, `RES_REDIS` | `- 64Mi - 256Mi`, `50m 128Mi 300m 512Mi`, `100m 1Gi 1 4Gi` | CPU/RAM of the single-instance infra (`<cpu-req> <mem-req> <cpu-lim> <mem-lim>`) | `openfga.resources`, `minio.resources`, `redis.resources` |
| `INGRESS_ENABLED` | `true` | create the Ingress for portal/admin/www/auth | (chart `ingress.enabled`) |
| **`CUSTOM_VALUES_YAML`** | empty | **any other value** (see §3) | any |

Per-service replicas and CPU/RAM are the `SVC_*` / `RES_*` lines above (defaults = live `xailon-tf-prod`); `airgap/deploy-all.sh render` turns them into `rendered/services.yaml`. Use `CUSTOM_VALUES_YAML` only for values that have no variable.

## 3. `CUSTOM_VALUES_YAML` — changing anything else from `config.env`
Raw YAML in a single-quoted shell string, two-space indentation, only the keys you change:
```
export CUSTOM_VALUES_YAML='
tf-relay:
  replicas: 4
  resources:
    requests: { cpu: 100m, memory: 512Mi }
    limits:   { cpu: 2000m, memory: 2Gi }
ingress:
  annotations:
    nginx.org/client-max-body-size: 256m
tf-auth:
  config:
    keycloak:
      smtp: { ssl: true, starttls: false }
'
```
Rules: keys are exactly those of the chart (`ai-gateway-platform/helm/tokenfactory/values-tf-prod.yaml` shows every key with a comment); maps are merged key by key; **lists are replaced whole** (e.g. `tf-ledger.env`: copy the entire list from the developer's `values-tf-etisalat.yaml`, then edit one entry); never put secrets here (they would appear in `rendered/custom.yaml`).

## 4. The developer's overlay, key by key → what to do
| Developer-overlay key | Change it in |
|---|---|
| `global.brand`, `global.brandPack.*` (theme, copy, feature ceiling) | **do not edit** (generated from `brands/etisalat/`; not an env value) |
| `global.brandImages.*.tag` / `global.image.tag` / `registry` | `config.env`: `BRAND_TAG` / `TF_TAG` / `REGISTRY` |
| `global.urls.*`, `supportEmail` | `config.env`: `DOMAIN`, `SUPPORT_EMAIL` (custom host names → `CUSTOM_VALUES_YAML` for `global.urls` **and** `ingress.hosts`/`ingress.tls`, see `DEPLOY.md` J1) |
| `tf-auth…platformAdminEmail`, SMTP | `config.env`: `PLATFORM_ADMIN_EMAIL`, `SMTP_*` |
| `keycloak.tls`, `keycloak.config.httpEnabled` | developer's file; to flip `httpEnabled`: `CUSTOM_VALUES_YAML` → `keycloak: { config: { httpEnabled: false } }` |
| `tf-accounts.config.stripePublishableKey` | empty (top-up off); to set: `CUSTOM_VALUES_YAML` → `tf-accounts: { config: { stripePublishableKey: "pk_…" } }` |
| `tf-ledger.env` | developer's list; to change one entry copy the whole list into `CUSTOM_VALUES_YAML` |
| `tf-warden`/`tf-relay`/`tf-shim` sizing | prod values (template); override via `CUSTOM_VALUES_YAML` |
| `tf-gateway-resources.tls`, Envoy Service LoadBalancer + 443→8443 patch | `DOMAIN`, `TLS_CERT/KEY`; Azure private IP → `LB_INTERNAL` |
| datastores (Postgres external, Redis/S3 bundled) | already set (Zalando `pgdb`); Postgres size/instances → `PG_*` |
| `redis` persistence / `maxmemory` | developer's file (10Gi / 3gb) |
| Persona CDD | not in the chart on `develop` yet |
| **Ingress** (chart `ingress:` block, not in the developer's file) | `INGRESS_ENABLED`; hosts/annotations/class → `CUSTOM_VALUES_YAML` or `DEPLOY.md` J1 |

## 5. After editing `config.env` — apply
```
cd ~/etisalat
airgap/deploy-all.sh dry-run                 # must end with "dry-run PASSED"
airgap/deploy-all.sh render ns app           # app values (replicas, URLs, SMTP, Keycloak, Envoy, CUSTOM_VALUES_YAML …)
airgap/deploy-all.sh pg                      # only after changing PG_*  (disk can only grow)
```
| You changed | Run |
|---|---|
| `PG_*`, `PG_INSTANCES` | `airgap/deploy-all.sh pg` |
| `values/openmeter.values.yaml.tmpl`, `CH_*` | `airgap/deploy-all.sh render openmeter` |
| `values/nginx-ingress.values.yaml.tmpl` | `airgap/deploy-all.sh render ingress` |
| `values/envoy-gateway…` / `ai-gateway…` | `airgap/deploy-all.sh render controllers` |
| `TF_TAG` / `BRAND_TAG` | rebuild the bundle on the Mac (`DEPLOY.md` Part A), copy it, `airgap/deploy-all.sh images render app` |

Undo an app change: `helm -n tokenfactory history tokenfactory`, then `helm -n tokenfactory rollback tokenfactory <revision>`.
