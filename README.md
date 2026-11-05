# E-_TokenFactory — TokenFactory for Etisalat (air-gapped, HA)

Deployment package for `tokenfactory` in namespace `tokenfactory-etisalat`: HA Postgres (Zalando), HA Keycloak,
NGINX Ingress, Envoy AI Gateway, OpenMeter — installed offline from one image/chart bundle.

Start with **[DEPLOY.md](DEPLOY.md)**. Site values: `config.env` (placeholders `REPLACE_*`, no secrets). Sizing: `values/` and `zalando/charts/*/values.yaml`.

**Not included (private Infinia source):** the `ai-gateway-platform` chart checkout. Place it in this folder as `ai-gateway-platform/`
(release commit that contains PR #678, the Ingress template) before running `airgap/01-bundle-connected.sh`.
