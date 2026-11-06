# Etisalat air-gapped TokenFactory — lab run summary (5 Nov 2026)

A sample TokenFactory is **up in namespace `tokenfactory`** on the isolated single-node AKS lab `aks-etisalat-test` (no internet, no registry). It was deployed by following `DEPLOY.md` from the beginning; every problem found on the way was fixed in the scripts and written into `DEPLOY.md` (Parts E, G, H).

## What is running
| Area | State |
|---|---|
| Images | all 38 loaded from `.tar` files into the node's containerd (`ALL 38 IMAGES PRESENT`); digest-pinned (`@sha256`) images work |
| Postgres (Zalando) | Patroni leader `Running`; 1 instance in the lab (HA = 3 instances on ≥ 3 nodes) |
| Keycloak | 3/3 Ready, one Infinispan cluster of 3 members, PDB + anti-affinity |
| API gateway | 3× Envoy + Envoy Gateway / AI Gateway controllers; `api.` → HTTP 401 without a key (correct) |
| Web | NGINX ingress: `www`, `portal`, `admin` → HTTP 200; Keycloak issuer `https://auth.etisalat.lab/auth/realms/master` |
| tf-* services | all Ready (3 replicas each, `tf-ledger` = 1) |
| OpenMeter | Kafka ×3, API ×2, ClickHouse, Redis, Svix Running (uses the same `pgdb`) |

## What was wrong and is now fixed
1. `01-bundle-connected.sh` exited silently — `env.sh` ended with a failing `[ -d … ] && …` under `set -e`.
2. Mac PATH picked up the Linux `bundle/tools/helm` — tools are now added to PATH on Linux only.
3. skopeo rejects `tag@digest` references (busybox, openmeter) — the tag is stripped for digest images.
4. **MinIO's public images were removed** (Docker Hub / quay: access denied) — new `airgap/fetch-minio-from-acr.sh` builds the tar from the prod ACR (DEPLOY.md step A7).
5. `tf-accounts` init `legal-src` needs the `tf-docs-web` image, and no Etisalat-branded one exists — default-brand image stored under the branded tag, `DOCS_WEB=no`.
6. `tf-ledger` crashed with `Dirty database version 5` (a pod was killed mid-migration) — fixed by undoing that migration (command in DEPLOY.md Part E); do not delete pods while a first start is migrating.
7. `preflight.sh`'s OpenMeter probe can never pass on a Cilium cluster (OpenMeter's NetworkPolicy blocks it) — `deploy-all.sh app` runs its own checks and uses `SKIP_PREFLIGHT=1`.
8. `install.sh` printed the helm command **including the service keys** into the log — keys now travel in a 0600 values file; old logs were scrubbed.
9. Fresh-VM readiness — `make`, `envsubst`, `skopeo` removed from the air-gap side (only `perl python3 openssl tar` needed; `kubectl` and `helm` ship in `bundle/tools`).
10. `pkill -f` killed the operator's own SSH session — replaced by port-based kill in the doc.
11. The AKS lab could not bootstrap ("Bootstrap Container Registry is not reachable") — the private-endpoint subnet NSG did not admit the new subnet; `Etisalat-aks.tf` now adds rule `Allow-Etisalat-AKS`.
12. Loader re-copied 4 GB on every run — it now skips images that are already on the node.

## Lab-only settings (set back for real Etisalat)
`SINGLE_NODE=yes` (→ `no`), `LB_INTERNAL=yes` (→ `no` outside Azure), `NODE_LOAD_MODE=pod` (→ `ssh` if nodes have SSH), self-signed `*.etisalat.lab` certificate, dummy SMTP host, jar served from the jumphost (use an internal web server).

## Open items
- **Developer:** build the Etisalat-branded `tf-docs-web` image (then `DOCS_WEB=yes`); ticket for `tf-ledger` leader election (it must stay at 1 replica).
- Postgres backups are not configured (no object store in the air-gap) — plan `pg_dump`/WAL-G before production.
- `pg_hba` is `0.0.0.0/0 md5` (copied from prod) — tighten to the pod CIDR.
- Real Etisalat: ≥ 3 nodes, two LoadBalancer IPs (Envoy for `api.`, ingress for `portal/admin/www/auth.`), real certificate, SMTP relay, DNS.
- Lab leftovers to remove after testing: see `DEPLOY.md` Part G (Terraform destroy command) and Part F.

## Where things are
- Runbook: `DEPLOY.md` (one document, top to bottom). Site values: `config.env`. Sizing: `values/*.tmpl`, `zalando/charts/pgdb/values.yaml`.
- Lab cluster definition: `jumphost:~/terraform_tokenfactory/Etisalat-aks.tf`.
- Repo: `sidhantCoredge/E-_TokenFactory` — push from `~/Downloads/E-_TokenFactory-upload` (`git add -A && git commit && git push origin main`).
