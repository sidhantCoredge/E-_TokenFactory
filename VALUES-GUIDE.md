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
| `TF_TAG` | `0.17.2-356be61` | tf-* image tag | `global.image.tag` |
| `BRAND_TAG` | `0.17.0-etisalat-6b27a33` | Etisalat web images | `global.brandImages.*.tag` |
| `IMAGE_MODE`, `REGISTRY`, `REGISTRY_USER/PASS` | `tar`, `registry.etisalat.local` | how images reach nodes / registry prefix | `global.image.registry` |
| `NODE_LOAD_MODE`, `NODES` | `pod` (lab) / `ssh` (real) | tar loading | – |
| `KUBECONFIG_FILE`, `NAMESPACE` | `~/etisalat.kubeconfig`, `tokenfactory` | cluster access, namespace | – |
| `SINGLE_NODE`, `LB_INTERNAL` | `no`, `no` | 1-node lab (1 Postgres instance) / Azure private LBs | – |
| `STORAGE_CLASS` | – | PVC class | `global.storageClass` |
| `DOMAIN` | – | creates `api. auth. portal. admin. www.<DOMAIN>` | `global.urls.*` |
| `SUPPORT_EMAIL`, `PLATFORM_ADMIN_EMAIL` | `support@`/`admin@<DOMAIN>` | sender, super-admin login | `global.supportEmail`, `tf-auth…smtp.from`, `…platformAdminEmail` |
| `TLS_CERT`, `TLS_KEY` | – | wildcard cert → secret `tf-etisalat-tls` | `tf-gateway-resources.tls.certSecretName` |
| `SMTP_HOST/PORT/USER/PASSWORD` | – | mail relay | `tf-auth.config.keycloak.smtp.*` |
| `KEYCLOAK_JAR_URL` | empty | empty = the installer hosts the bundled jar inside the cluster (recommended); or your own internal URL | `keycloak.providers.plugins[0].url` |
| `CH_DATA_SIZE`, `CH_LOG_SIZE` | `50Gi`, `5Gi` | ClickHouse disks | – |
| `DOCS_WEB` | `no` | docs site (no Etisalat docs image yet) | `global.brandImages.docs` |
| `PG_OPERATOR_MODE` | `install` | install the Zalando operator or reuse an existing one | – |
| **`ENVOY_REPLICAS`** | **`6`** | Envoy data-plane pods (**minimum 6**; prod runs 10). Envoy has **no CPU/RAM requests or limits** (same as prod — it takes all the inference load) | `tf-gateway-resources.envoyProxy…replicas` |
| `ENVOY_PDB_MIN_AVAILABLE` | `1` | Envoy PodDisruptionBudget | `…envoyPDB.minAvailable` |
| **`KEYCLOAK_REPLICAS`** | **`3`** | Keycloak HA pods (Infinispan cluster) | `keycloak.replicaCount` |
| `KEYCLOAK_MEM_REQUEST/LIMIT`, `KEYCLOAK_HEAP` | `1Gi`/`8Gi`, `-Xms512m -Xmx2g …` | as tokenfactory-prod (memory only) | `keycloak.resources`, `jvmHeapOpts` |
| **`PG_INSTANCES`** | **`3`** | Postgres HA instances (forced to 1 by `SINGLE_NODE=yes`) | – (pgdb chart) |
| `PG_VOLUME_SIZE`, `PG_CPU_REQUEST/LIMIT`, `PG_MEM_REQUEST/LIMIT`, `PG_MAX_CONNECTIONS` | `20Gi`, `1`/`4`, `2Gi`/`8Gi`, `300` | as tokenfactory-prod | – (pgdb chart) |
| `TF_REPLICAS` | `3` | replicas of accounts, auth, relay, babel, shim, control, ops, warden, portal-web, admin-web (`tf-ledger` is always 1) | `tf-*.replicas` |
| `SITE_DOCS_REPLICAS` | `1` | `tf-site-web`, `tf-docs-web` (1 in prod) | `tf-site-web.replicas` … |
| `INGRESS_ENABLED` | `true` | create the Ingress for portal/admin/www/auth | (Xailon PR #678 `ingress.enabled`) |
| **`CUSTOM_VALUES_YAML`** | empty | **any other value** (see §3) | any |

Per-service CPU/RAM of the tf-* pods are the **tokenfactory-prod live values** (accounts 50m/64Mi–200m/256Mi, relay/warden/shim up to 1 CPU/1Gi, …). They live in `values/umbrella.values.yaml.tmpl` (the `tf-*:` one-liners at the end); change one through `CUSTOM_VALUES_YAML`, not by editing the template.

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
| **Ingress** (Xailon PR #678, not in the developer's file) | `INGRESS_ENABLED`; hosts/annotations/class → `CUSTOM_VALUES_YAML` or `DEPLOY.md` J1 |

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
