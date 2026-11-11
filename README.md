# E-_TokenFactory — TokenFactory for Etisalat (air-gapped, HA)

Deployment package for `tokenfactory` in namespace `tokenfactory` (chart **0.17.7**, branch `stage` of `Infinia-Technology/ai-gateway-platform`, overlay `values-tf-etisalat.yaml`): HA Postgres (Zalando), HA Keycloak,
NGINX Ingress (TLS), Envoy AI Gateway, OpenMeter — installed offline from one image/chart bundle, no internet and no registry inside the air-gap.

Start with **[DEPLOY.md](DEPLOY.md)** (real Etisalat cluster) or **[DEPLOY-LAB.md](DEPLOY-LAB.md)** (Azure single-node lab). Storage (HPE X10000 over NFSv4.1 via the HPE CSI driver): **[STORAGE-HPE-CSI.md](STORAGE-HPE-CSI.md)**. Secrets (dedicated in-cluster HashiCorp Vault, like prod): **[VAULT-SECRETS.md](VAULT-SECRETS.md)**. Site values: `config.env` (placeholders `REPLACE_*`, no secrets). Sizing: `values/` and `zalando/charts/*/values.yaml`. Every `config.env` variable: [VALUES-GUIDE.md](VALUES-GUIDE.md).

**One-go flow**
1. Mac (internet): `airgap/00-fetch-chart.sh` then `airgap/01-bundle-connected.sh` (creates the git-ignored `ai-gateway-platform/` and `bundle/`).
2. Copy this whole folder to the install VM (DEPLOY.md A6).
3. VM (no internet): fill `config.env`, `airgap/deploy-all.sh dry-run`, `airgap/deploy-all.sh all`.

**Not in git (generated, git-ignored):** `ai-gateway-platform/` (private chart checkout, pinned by `CHART_REF`), `bundle/` (image tars, charts, CRDs, Keycloak jar, linux helm/kubectl), `rendered/`, `Real-values-of-tf-prod.yaml`.
