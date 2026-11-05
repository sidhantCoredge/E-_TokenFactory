# TokenFactory for Etisalat — air-gapped, HA, one-command deploy

Chart `helm/tokenfactory` **0.17.2**, brand `etisalat`. No internet is needed anywhere inside the air-gap: every image, chart, CRD and the Keycloak plugin jar travel in one bundle.

| Component | HA? | How |
|---|---|---|
| **Postgres** (TokenFactory + Keycloak + OpenFGA + **OpenMeter** + Svix) | **Yes** | Zalando postgres-operator, 1 `pgdb` cluster, 3 Patroni instances (leader + 2 replicas) |
| **Keycloak** | **Yes** | 3 replicas, Infinispan distributed cache, DNS_PING, PDB, anti-affinity |
| **Ingress** (portal / admin / www / auth) | **Yes** | F5 NGINX Ingress Controller, 2 replicas + PDB |
| **API gateway** (`api.`) | **Yes** | Envoy Gateway: 2 controllers, 3 data-plane pods + PDB |
| tf-* services | **Yes** | 3 replicas each, except `tf-ledger` (must be 1 — no leader election) |
| OpenMeter: Kafka 3, API 2 | Yes | ClickHouse, Svix, workers: single instance |
| Redis, MinIO, OpenFGA | **No** | single instance by chart design |

## 0. How traffic flows (read once)

```
api.<domain>                          ──► Envoy LoadBalancer IP   ──► tf-* inference
portal. admin. www. auth.<domain>     ──► NGINX-Ingress LB IP     ──► tf-portal-web / tf-admin-web / tf-site-web / keycloak-edge→keycloak
```
Two LoadBalancer IPs ⇒ your cluster needs a LoadBalancer implementation (MetalLB/F5/…) for both, **or** switch the two Services to NodePort/fixed IPs after install. The Ingress object comes from PR #678: the chart checkout you use must contain `templates/ingress.yaml` (`prepare` stops with a clear error otherwise).

## 1. What you must have / decide before starting

1. **Cluster:** ≥ 3 Ready nodes, Kubernetes ≥ 1.29, a **StorageClass with volume expansion**, a LoadBalancer provider, and your node container runtime must be able to pull from your registry (trust its CA).
2. **An internal container registry** (Harbor/Nexus/registry:2). If you have none: `airgap/02a-local-registry.sh` starts one from the bundle (needs docker/podman).
3. **Wildcard TLS cert** `*.<domain>` (PEM cert + key) — covers `api. auth. portal. admin. www.`
4. **Internal SMTP relay** reachable from the cluster.
5. **An internal HTTP(S) URL** serving the Keycloak plugin jar (see step 4.2). Keycloak never becomes Ready without it.
6. **Release identifiers** from CI: `TF_TAG` (`0.17.2-<sha>`) and `BRAND_TAG` (Etisalat-brand web images). *The placeholder `0.17.0-etisalat-0000000` in the repo does not exist.*
7. **Tools** on the install host: `kubectl helm(≥3.14) skopeo envsubst openssl perl python3 make` (+ `docker|podman` only for 02a). Connected host: the same + `curl tar`.

## 2. What is in this folder

```
config.env                  ◄── the ONLY file with site values (edit this)
DEPLOY.md                   this file
ai-gateway-platform/        NOT in the git repo (private Infinia source): checkout of the release commit that CONTAINS the Ingress template of PR #678
                            (helm/tokenfactory/templates/ingress.yaml + `ingress:` block in values.yaml). Put it next to config.env.
airgap/
  images.txt                every image (38): source → target path in your registry
  01-bundle-connected.sh    (internet host) build bundle/  : images, charts, CRDs, jar, repo snapshot
  02-push-registry.sh       bundle → your registry (digest-safe)
  02a-local-registry.sh     optional: run a registry from the bundle
  03-patch-hardcoded-images.sh   fixes 4 things no values key can reach (see §9)
  deploy-all.sh             ◄── the one-command installer (phases, resumable, has dry-run)
values/                     sizing + settings (edit CPU/RAM/replicas here)
  umbrella.values.yaml.tmpl  openmeter.values.yaml.tmpl  nginx-ingress.values.yaml.tmpl
  envoy-gateway.values.yaml.tmpl  ai-gateway.values.yaml.tmpl
zalando/charts/             postgres-operator/ (values.yaml)  pgdb/ (values.yaml: instances, CPU/RAM, disk, PG params)
```

## 3. On the internet-connected host

```sh
cd ethisalat
cp config.env config.env.bak
$EDITOR config.env                 # only TF_TAG, BRAND_TAG, PLATFORM need to be right here; rest can be filled later
docker login                       # docker.io: anonymous pulls are rate-limited (~25 images)
skopeo login ghcr.io               # READ token for the private tf-* images (infinia-technology)
airgap/01-bundle-connected.sh      # resumable. Produces ./bundle/
tar -cf etisalat-package.tar --exclude='*/.git' .      # whole folder incl. bundle/ -> transfer into the air-gap
```
If `helm pull oci://docker.io/envoyproxy/...` answers 401 (Docker Desktop creds), fetch the 3 chart blobs anonymously (curl + token) into `bundle/charts/` as `gateway-helm-v1.8.1.tgz`, `ai-gateway-crds-helm-v1.0.0.tgz`, `ai-gateway-helm-v1.0.0.tgz`. The same bundle contains `nginx-ingress-1.3.2.tgz`.

## 4. Inside the air-gap

### 4.1 Unpack and verify
```sh
mkdir etisalat && tar -xf etisalat-package.tar -C etisalat && cd etisalat
( cd bundle && sha256sum -c SHA256SUMS | grep -v ': OK$' || echo "bundle integrity OK" )
```

### 4.2 Host the Keycloak jar
```sh
# any internal web server works; quickest throw-away option on a host the pods can reach:
cd bundle/jars && python3 -m http.server 8000      # URL: http://<this-host>:8000/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar
```
Use a durable server (nginx/Nexus) in production — the jar is fetched on **every** Keycloak pod start.

### 4.3 Registry
Have one? `skopeo login <registry>`. None? `airgap/02a-local-registry.sh`, then use `REGISTRY=<ip>:5000`, `DEST_TLS_VERIFY=false`, and trust it on every node (containerd `certs.d/<ip>:5000/hosts.toml` → `server = "http://<ip>:5000"`).

### 4.4 Fill config.env
Every `REPLACE_` must go (the installer refuses otherwise). Meaning of each line is in the file. Keep `PG_OPERATOR_MODE=install` unless your cluster **already** runs a Zalando operator (then `existing`: it must watch `$NAMESPACE`; never run two operators on one cluster).

### 4.5 Dry-run (no cluster changes) — do this first
```sh
airgap/deploy-all.sh dry-run
```
Applies the patches, renders all values, and runs `helm template` on **all seven releases** (operator, pgdb, Envoy Gateway, AI Gateway, NGINX Ingress, OpenMeter, TokenFactory). It must end with `dry-run PASSED`.

### 4.6 Deploy everything
```sh
airgap/deploy-all.sh all           # push → check → prepare → ns → pg → secrets → controllers → ingress → openmeter → app → verify
```
Expect 30–60 min on a cold cluster (Kafka/ClickHouse first start is slow). It is **resumable and idempotent**: after a failure fix the cause and run `airgap/deploy-all.sh --from <phase>`. Images already pushed? `PUSH_IMAGES=no airgap/deploy-all.sh all`.

What each phase does:

| phase | action |
|---|---|
| push | `skopeo` copies `bundle/images/*` into `$REGISTRY` (digest-pinned images keep their digest) and verifies them |
| check | tools, config.env complete, TLS valid, bundle files, cluster reachable, ≥3 nodes, StorageClass, **every image present in the registry** |
| prepare | patches the hardcoded images + ClickHouse PVC (§9), applies the Ingress template, `helm dependency build` (file:// only) |
| render | `envsubst` config.env into `rendered/*.yaml` (no secrets inside) |
| ns | namespaces `postgres`, `$NAMESPACE`, `openmeter`, `envoy-gateway-system`, `envoy-ai-gateway-system`, `nginx-ingress`; `registry-pull` secret + default-SA pull secret in each; TLS secret `tf-etisalat-tls` |
| pg | operator (`postgres` ns) → `pgdb` cluster (3 instances) → waits for Running, 3 pods, 5 role secrets, prints `patronictl list` |
| secrets | `tokenfactory-secrets` (19 generated keys) + 5 service keys → `~/.etisalat-service-keys.env` (**back it up**) |
| controllers | Gateway API CRDs v1.3.0, Envoy Gateway v1.8.1, AI Gateway CRDs + controller v1.0.0 |
| ingress | F5 NGINX Ingress Controller 3.6.2, telemetry disabled |
| openmeter | OpenMeter on `pgdb` (own `openmeter`/`svix` DBs) with generated ClickHouse password |
| app | `make -C helm/setup install-app` (preflight + `helm upgrade --install`) |
| verify | pod health, images not from your registry (must be none), Keycloak/Ingress state, **the two LB IPs for DNS**, admin-password command |

### 4.7 DNS and first login
`verify` prints the two addresses. Create: `api.<domain>` → Envoy IP; `portal. admin. www. auth.<domain>` → Ingress IP. Admin console: `https://admin.<domain>`, user `PLATFORM_ADMIN_EMAIL`, password:
`kubectl -n $NAMESPACE get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d`

## 5. Sizing — everything is in values files

| What | File → key |
|---|---|
| tf-* services CPU/RAM/replicas | `values/umbrella.values.yaml.tmpl` → section S2 (`tf-accounts:` … `tf-site-web:`) |
| **Keycloak** replicas / CPU / RAM / JVM heap | same file → `keycloak:` (keep `-Xmx` ≈ ½–¾ of `limits.memory`) |
| Envoy data plane replicas / CPU / RAM / PDB | same file → `tf-gateway-resources.envoyProxy…envoyDeployment` |
| Redis, MinIO, OpenFGA | same file → `redis:`, `minio:`, `openfga:` |
| **Postgres** instances / CPU / RAM / disk / PG parameters | `zalando/charts/pgdb/values.yaml` (`numberOfInstances`, `resources`, `volume.size`, `parameters`) |
| Postgres operator | `zalando/charts/postgres-operator/values.yaml` |
| OpenMeter: API/workers, Svix, Kafka, Redis, ClickHouse CPU/RAM | `values/openmeter.values.yaml.tmpl` (sections M1–M5) |
| **ClickHouse disk** | `config.env` → `CH_DATA_SIZE`, `CH_LOG_SIZE` (the upstream chart hardcodes it; `prepare` patches it) |
| NGINX Ingress replicas / CPU / RAM | `values/nginx-ingress.values.yaml.tmpl` |
| Envoy Gateway / AI Gateway controllers | `values/envoy-gateway.values.yaml.tmpl`, `values/ai-gateway.values.yaml.tmpl` |

After editing: `airgap/deploy-all.sh render pg openmeter app` (or just the phase you changed: `pg` for Postgres, `ingress`, `controllers`, `openmeter`, `app`). Changing `volume.size` of an existing `pgdb` grows the volumes (StorageClass must allow expansion); lowering it is not possible.

## 6. Verify manually (after `verify`)
```sh
kubectl -n $NAMESPACE get postgresql pgdb ; kubectl -n $NAMESPACE exec pgdb-0 -c postgres -- patronictl list   # 1 Leader + 2 Replica, same timeline
kubectl -n $NAMESPACE get pods -l app.kubernetes.io/name=keycloak -o wide      # 3 pods, ideally on 3 nodes
kubectl -n $NAMESPACE logs keycloak-0 | grep -i "cluster view\|members"        # one merged view, 3 members
curl -sk https://auth.<domain>/auth/realms/master/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
kubectl -n $NAMESPACE get ingress tokenfactory                                 # 4 hosts, ADDRESS set, class nginx
# HA drill: kubectl -n $NAMESPACE delete pod keycloak-1 / pgdb-<leader>  → login keeps working, Patroni promotes a replica
cd ai-gateway-platform/test/e2e
KC=kubectl NS=$NAMESPACE PORTAL_URL=https://portal.<domain> ADMIN_URL=https://admin.<domain> SITE_URL=https://www.<domain> DOCS_URL=https://www.<domain>/docs \
  EXPECT_PRODUCT='Token Factory by etisalat' EXPECT_FAVICON=favicon.png EXPECT_THEME_POLICY=both EXPECT_DARK_TOKENS=yes EXPECT_SIGNUP=yes ./branding.sh
KC=kubectl NS=$NAMESPACE PORTAL_URL=https://portal.<domain> SITE_URL=https://www.<domain> ./features.sh   # socialLogin + topup OFF, signup ON
```

## 7. Upgrades
On the connected host build a new bundle with the new `TF_TAG`/`BRAND_TAG` (`01`), carry it over, update `config.env`, then:
`airgap/deploy-all.sh push check prepare render app`. The same `~/.etisalat-service-keys.env` is reused automatically. Never delete it; never regenerate `tokenfactory-secrets`.

## 8. Postgres notes
* Same `pgdb` serves TokenFactory, Keycloak, OpenFGA and OpenMeter/Svix (5 databases, 5 roles; passwords generated by the operator in Secrets `<role>.pgdb.credentials.postgresql.acid.zalan.do`).
* Connections: 3 Keycloak pods + 3 × tf-* services share `max_connections: 300` (in `pgdb/values.yaml`). After the first rollout check `kubectl -n $NAMESPACE exec pgdb-0 -c postgres -- psql -U postgres -c "select count(*) from pg_stat_activity"`.
* `pg_hba` allows `0.0.0.0/0 md5` (copied from prod); tighten to the pod CIDR if your policy requires.
* Your earlier AWS/EKS Zalando guide (spilo-15, PG15, 2 instances, master LB, Operator UI) is a different layout. Here: operator v1.14.0, spilo-17 / PG16, **3** instances, ClusterIP only (clients use Service `pgdb`), no UI, no LB. Operator UI is optional and not shipped.
* Backups are **not** configured (no object store inside the air-gap by default). Plan `pg_dump`/WAL-G to an internal S3 before production.

## 9. Things the bundle fixes for you (and why)
1. **tf-auth** `wait-for-keycloak` uses `busybox:1.36@sha256…` hardcoded in a template.
2. **OpenMeter chart** hardcodes `busybox:1.37.0` and `clickhouse/clickhouse-server:24.10`.
3. **ClickHouse PVC** is hardcoded 3Gi/1Gi with no StorageClass (→ filled disk / default class). Patched from `CH_*` and `STORAGE_CLASS`.
4. **Keycloak plugin jar** is downloaded from Maven Central on every pod start → `KEYCLOAK_JAR_URL`.
5. **GeoIP sidecar** downloads from GitHub → disabled (admin Geo Heatmap stays empty; host the `.mmdb` files internally to enable).
6. **NGINX controller telemetry** phones home by default → disabled.
7. **Envoy data-plane image** is in no chart → set in `umbrella.values.yaml.tmpl`.
8. `@sha256` images (Keycloak, busybox, OpenMeter) are copied with `skopeo --all --preserve-digests`; `docker pull/push` would change the digest and the pod would never start.
9. Chart 0.17.2 pins a different Keycloak digest than prod (0.16.2). Mirror what `images.txt` says.

## 10. Troubleshooting
| Symptom | Cause / fix |
|---|---|
| `check`: image MISSING | run `airgap/deploy-all.sh push`; for TLS/auth problems set `DEST_TLS_VERIFY`, `REGISTRY_USER/PASS` |
| `ImagePullBackOff` | node can't reach/trust the registry, or the image path differs from `images.txt`; `kubectl describe pod` shows the exact ref |
| Keycloak `Init:Error` / not Ready | `KEYCLOAK_JAR_URL` unreachable from pods: `kubectl -n $NAMESPACE logs keycloak-0 -c fetch-providers` |
| `auth.` or `portal.` serves a self-signed cert | `tf-etisalat-tls` missing/wrong namespace (nginx silently falls back to its default cert) |
| `portal.` 404 / no address on Ingress | nginx-ingress not running or `ingressClass` ≠ `nginx`; wrong DNS target |
| `api.` unreachable | Envoy Service has no LB IP (`kubectl -n $NAMESPACE get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy`) |
| `pgdb` pod Pending | fewer than 3 schedulable nodes, or StorageClass can't provision |
| tf-ledger can't reach OpenMeter | OpenMeter NetworkPolicy `appNamespace` ≠ `$NAMESPACE` (it is set automatically; don't override) |
| preflight blocks on OpenMeter | run phase `openmeter` first (`all` already does) |
| `--from` after partial failure | helm releases are idempotent; just rerun |

`DEPLOY.old.md` is the previous draft kept for reference only.
