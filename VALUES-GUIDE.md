# VALUES-GUIDE — which value lives where, and which file/section to edit

## 0. Where are the files?
| Place | Path |
|---|---|
| Mac (package) | `~/Downloads/ethisalat/config.env` and `~/Downloads/ethisalat/values/umbrella.values.yaml.tmpl` |
| Install VM (lab: jumphost) | `~/etisalat/config.env` and `~/etisalat/values/umbrella.values.yaml.tmpl` |
| Git repo | `config.env`, `values/umbrella.values.yaml.tmpl` |
| Developer's overlay (**never edit**) | `ai-gateway-platform/helm/tokenfactory/values-tf-etisalat.yaml` |

The values are **rendered at deploy time**, they are not baked into the bundle. Only `TF_TAG` and `BRAND_TAG` must be decided before building the bundle (they name the image tars). Everything else you can edit on the Mac and rsync (`--exclude config.env` if the jumphost copy is already filled in), or edit directly on the VM, then run the apply command from §4.

Two layers are applied by Helm, later wins: **(1)** developer's `values-tf-etisalat.yaml` → **(2)** our `values/umbrella.values.yaml.tmpl` (which gets its `${...}` placeholders from `config.env`). So to change something: look in §2 for it, edit the file named there; if the developer's file has it but we do not override it, copy that key into the template (§3 shows exactly where).

## 1. `config.env` — one line per value (line numbers as in the file today)
| Line | Variable | Controls | Developer-overlay key it fills |
|---|---|---|---|
| 8 | `TF_TAG` | tf-* image tag (`0.17.2-<sha>`) | `global.image.tag` |
| 9 | `BRAND_TAG` | Etisalat web image tag (`…-etisalat-<7-hex>`) | `global.brandImages.*.tag` |
| 13 | `REGISTRY` | name prefix of every image (no real registry) | `global.image.registry` |
| 17–20 | `NODE_LOAD_MODE`, `NODES`, … | how tars are loaded on nodes | – |
| 23 | `KUBECONFIG_FILE` | kubeconfig the scripts use | – |
| 24 | `NAMESPACE` | app + Postgres namespace | – |
| 25 | `SINGLE_NODE` | `yes` = 1-node lab (1 Postgres instance) | – |
| 26 | `LB_INTERNAL` | `yes` = Azure private LoadBalancers | – |
| 27 | `STORAGE_CLASS` | PVC class (must allow expansion) | `global.storageClass` |
| 31 | `DOMAIN` | creates `api. auth. portal. admin. www.<DOMAIN>` | `global.urls.*` |
| 32 | `SUPPORT_EMAIL` | sender / site contact | `global.supportEmail`, `tf-auth…smtp.from` |
| 33 | `PLATFORM_ADMIN_EMAIL` | bootstrap super-admin login | `tf-auth.config.keycloak.platformAdminEmail` |
| 34–35 | `TLS_CERT`, `TLS_KEY` | wildcard cert files → secret `tf-etisalat-tls` | `tf-gateway-resources.tls.certSecretName` |
| 38–41 | `SMTP_HOST/PORT/USER/PASSWORD` | mail relay | `tf-auth.config.keycloak.smtp.*` |
| 44 | `KEYCLOAK_JAR_URL` | internal URL of the Keycloak plugin jar | – (air-gap only) |
| 47–48 | `CH_DATA_SIZE`, `CH_LOG_SIZE` | ClickHouse disks | – |
| 54 | `DOCS_WEB` | `no` until an Etisalat docs image exists | `global.brandImages.docs` |
| 60 | `PG_OPERATOR_MODE` | `install` / `existing` | – |

## 2. `values/umbrella.values.yaml.tmpl` — sections (line numbers as in the file today)
| Lines | Section | What is in it | Typical edit |
|---|---|---|---|
| 5–10 | `global.imageRegistry`, `global.image` | registry prefix, tag, pullPolicy | normally none (come from `config.env`) |
| 13–17 | `global.brandImages` | web image tags | none (`BRAND_TAG`) |
| 18–24 | `global.urls` | the 5 public URLs | custom host names instead of the `api./portal./…` pattern |
| 25–26 | `supportEmail`, `storageClass` | | none |
| 28–40 | `global.postgres` | app → Zalando `pgdb` | only if Postgres is somewhere else |
| 43–61 | **`ingress:`** | `className` (46), `annotations` (47–53), `tls` (54–56), `hosts` (57–61) | upload size/timeouts (47–53), extra host (57–61 + 56), `auth.` → `keycloak` (61) |
| 64–83 | `tf-gateway-resources` | Envoy TLS (65–67), replicas (73), CPU/RAM (76–78), PDB (82–83) | Envoy size / replicas |
| 86–98 | `tf-auth` | replicas/resources (87–90), admin email + SMTP (93–98) | SMTP `ssl`/`starttls` (add under `smtp`, line 94) |
| 100–137 | **`keycloak:`** | replicas (101), CPU/RAM (102–104), heap (105), cache (108–109), HA/PDB (110–113), anti-affinity (114–121), Postgres (122–132), plugin jar (133–137) | Keycloak size, `required` anti-affinity on ≥3 nodes |
| 139–151 | `openfga` | Postgres wiring (141–148), resources (149–151) | – |
| 153–158 | `minio` | resources | disk: add `persistence: { size: 20Gi }` |
| 160–163 | `redis` | resources | add `persistence: { size: … }`, `maxmemory: "3gb"` if needed |
| 165–171 | `tf-ledger` | replicas **must stay 1**, resources, `geoip.enabled: false` | – |
| 173–184 | **S2 services** | one line per service: `replicas` + `resources` | raise replicas / CPU / RAM |

## 3. The developer's overlay, key by key → what to do
Format: `values-tf-etisalat.yaml` key → where to change it.

| Developer-overlay key | Change it in |
|---|---|
| `global.brand`, `global.brandPack.*` (theme, copy, colours, feature ceiling) | **do not edit** — generated from `brands/etisalat/` by brandgen; change the brand package in the repo and regenerate. Not an env value |
| `global.brandImages.{portal,admin,site,docs}.tag` | `config.env` line 9 (template lines 13–17 consume it) |
| `global.image.tag` | `config.env` line 8 |
| `global.image.registry` / `repository` | `config.env` line 13 (repository stays `infinia-technology/ai-gateway-platform`) |
| `global.image.requireImmutableTag` | leave `true` |
| `global.urls.api/auth/portal/admin/site/adminApi` | `config.env` line 31; custom names → template lines 18–24 (and Ingress 54–61, see J1 in `DEPLOY.md`) |
| `global.supportEmail` | `config.env` line 32 |
| `global.keycloakSecrets.generate` | developer's file; to override add `global: { keycloakSecrets: { generate: false } }` to the template (not recommended) |
| `global.secrets.existingSecret: tokenfactory-secrets` | developer's file. Secret contents are made by `deploy-all.sh secrets` (or pre-create the Secret yourself). Change a value later: `kubectl patch secret` + `rollout restart` (see `DEPLOY.md` J2) |
| `keycloak.tls`, `keycloak.config.httpEnabled` | developer's file (we only add `config.cache`); to flip `httpEnabled` add it under `keycloak.config` at template line 108 |
| `tf-auth.config.keycloak.platformAdminEmail` | `config.env` line 33 |
| `tf-auth.config.keycloak.smtp.from` | `config.env` line 32 |
| `tf-auth.config.keycloak.smtp.host/port/user` (+ password) | `config.env` lines 38–41 |
| `tf-auth.config.keycloak.url`, `caSecret`, `…ServiceClientId` | developer's file — leave |
| `tf-accounts.config.stripePublishableKey` | empty (top-up off). To set: turn template line 174 into a block and add `config: { stripePublishableKey: "pk_…" }` |
| `tf-accounts.config.emailFrom`, `keycloak.*` | developer's file — leave |
| `tf-portal-web` / `tf-admin-web` `resources.limits`, `upstreams.keycloak` | resources → template lines 181–182 (ours replaces requests + limits); `upstreams` → leave |
| datastores (Postgres external; Redis/S3 bundled) | template lines 28–40 (`global.postgres`), 122–132 (`keycloak.postgres`), 141–148 (`openfga.postgres`) |
| `tf-ledger.env` (the whole list: OpenMeter URL, freshness, replay horizon …) | developer's file. **Helm replaces lists whole**: to change one entry copy the *entire* `env:` list from the developer's file into the template under `tf-ledger:` (after line 171) and edit that one line |
| `tf-warden` / `tf-relay` / `tf-shim` replicas + resources | template lines 175, 177, 180 |
| `tf-gateway-resources.tls.hostname` / `certSecretName` / `listenerPort` | hostname from `config.env` line 31, cert from lines 34–35 (template 65–67); `listenerPort` leave |
| `tf-gateway-resources.envoyProxy…envoyService` (LoadBalancer + port 443→8443 patch) | developer's file; Azure private IP → `config.env` line 26 |
| `redis.persistence.size`, `redis.maxmemory` | developer's file (10Gi, 3gb); `redis.resources` → template lines 160–163 |
| Persona CDD (`global.cdd`, `tf-accounts.config.persona`) | not in the chart on `develop` yet — nothing to set |
| **Ingress** (not in the developer's file; Xailon PR #678) | template lines 43–61 |
| **Keycloak HA / Postgres / sizing** (not in the developer's file) | template lines 100–137 / 28–40, 122–148 / 173–184 |

## 4. After editing — apply
```
cd ~/etisalat
airgap/deploy-all.sh dry-run                 # must end with "dry-run PASSED"
airgap/deploy-all.sh render ns app           # config.env or umbrella.values.yaml.tmpl  (ns re-applies the TLS secret)
```
| You edited | Run |
|---|---|
| `zalando/charts/pgdb/values.yaml` | `airgap/deploy-all.sh pg` |
| `values/openmeter.values.yaml.tmpl` | `airgap/deploy-all.sh render openmeter` |
| `values/nginx-ingress.values.yaml.tmpl` | `airgap/deploy-all.sh render ingress` |
| `values/envoy-gateway…` / `ai-gateway…` | `airgap/deploy-all.sh render controllers` |
| `TF_TAG` / `BRAND_TAG` | rebuild the bundle on the Mac (`DEPLOY.md` Part A), copy it, then `airgap/deploy-all.sh images render app` |

Undo any app change: `helm -n tokenfactory-etisalat history tokenfactory`, then `helm -n tokenfactory-etisalat rollback tokenfactory <revision>`.

Line numbers drift when someone edits the files; the key names (`ingress:`, `keycloak:`, `tf-relay:` …) are the reliable anchors — search for them.
