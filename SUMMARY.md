# Etisalat air-gapped TokenFactory — status summary

> **Update 10 Nov 2026 — package moved to chart 0.17.7** (`TF_TAG=0.17.7-160792b`, chart commit pinned in `config.env`). Verified offline only (`deploy-all.sh dry-run` passes, every rendered image is in `airgap/images.txt`); not yet installed on a cluster. Changes vs the 5 Nov lab run: digest-pinned images for Keycloak 26.8.2 / OpenFGA / Postgres / Redis / curl / MinIO (GHCR) + new `ratelimit` image; Keycloak jar `26.6.1-KC26.8.0`; Ingress is TLS-only (`INGRESS_TLS=yes`); tf-ledger runs 3 replicas with leader election; `airgap/00-fetch-chart.sh` fetches the private chart at a pinned commit; the MinIO workaround and the PR #678 patch are gone. Details: `DEPLOY.md` Parts A, H, I. The sections below describe the 5 Nov lab run on chart 0.17.2.

## Lab run of 5 Nov 2026 (chart 0.17.2)

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
4. **MinIO's public images were removed** (Docker Hub / quay: access denied) — worked around then; since chart 0.17.x the image is Infinia's own build on GHCR and is bundled normally.
5. `tf-accounts` init `legal-src` needs the `tf-docs-web` image, and no Etisalat-branded one exists — default-brand image stored under the branded tag, `DOCS_WEB=no`.
6. `tf-ledger` crashed with `Dirty database version 5` (a pod was killed mid-migration) — fixed by undoing that migration (command in DEPLOY.md Part E); do not delete pods while a first start is migrating.
7. `preflight.sh`'s OpenMeter probe can never pass on a Cilium cluster (OpenMeter's NetworkPolicy blocks it) — `deploy-all.sh app` runs its own checks and uses `SKIP_PREFLIGHT=1`.
8. `install.sh` printed the helm command **including the service keys** into the log — keys now travel in a 0600 values file; old logs were scrubbed.
9. Fresh-VM readiness — `make`, `envsubst`, `skopeo` removed from the air-gap side (only `perl python3 openssl tar` needed; `kubectl` and `helm` ship in `bundle/tools`).
10. `pkill -f` killed the operator's own SSH session — replaced by port-based kill in the doc.
11. The AKS lab could not bootstrap ("Bootstrap Container Registry is not reachable") — the private-endpoint subnet NSG did not admit the new subnet; `Etisalat-aks.tf` now adds rule `Allow-Etisalat-AKS`.
12. Loader re-copied 4 GB on every run — it now skips images that are already on the node.

## Lab-only settings (set back for real Etisalat)
`SINGLE_NODE=yes` (→ `no`), `LB_INTERNAL=yes` (→ `no` outside Azure), `NODE_LOAD_MODE=pod` (→ `ssh` if nodes have SSH), self-signed `*.etisalat.lab` certificate, dummy SMTP host, Keycloak jar: lab used the jumphost; now `KEYCLOAK_JAR_URL` is empty and the jar is hosted in the cluster.

## Open items
- **Developer:** build the Etisalat-branded `tf-docs-web` image (then `DOCS_WEB=yes`); (tf-ledger leader election exists since 0.17.4; this package runs 3 replicas.)
- Postgres backups are not configured (no object store in the air-gap) — plan `pg_dump`/WAL-G before production.
- `pg_hba` is `0.0.0.0/0 md5` (copied from prod) — tighten to the pod CIDR.
- Real Etisalat: ≥ 3 nodes, two LoadBalancer IPs (Envoy for `api.`, ingress for `portal/admin/www/auth.`), real certificate, SMTP relay, DNS.
- Lab leftovers to remove after testing: see `DEPLOY.md` Part G (Terraform destroy command) and Part F.

## Where things are
- Runbook: `DEPLOY.md` (one document, top to bottom). Site values: `config.env`. Sizing: `values/*.tmpl`, `zalando/charts/pgdb/values.yaml`.
- Lab cluster definition: `jumphost:~/terraform_tokenfactory/Etisalat-aks.tf`.
- Repo: `sidhantCoredge/E-_TokenFactory` — this folder is the single source (push from `~/Downloads/E-_TokenFactory-upload`; `bundle/` and `ai-gateway-platform/` are git-ignored).
