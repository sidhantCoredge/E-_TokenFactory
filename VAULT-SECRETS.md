# Secrets for TokenFactory: a dedicated HashiCorp Vault inside the Etisalat cluster

`tokenfactory-prod` and `tf-stage` keep their secrets in HashiCorp Vault and sync them into the Kubernetes Secret `tokenfactory-secrets` with the Secrets Store CSI driver. Etisalat works the same way, but with **its own Vault inside the Etisalat cluster**: nothing is shared with the Infinia production Vault and nothing leaves the cluster (no internet, no cloud key vault).

```
  Vault (pod vault-0, namespace vault, 1 pod, file storage on a PVC)
     ^  Kubernetes auth: role "tokenfactory" (ServiceAccount tf-vault-sync)
     |
  Secrets Store CSI driver + Vault CSI provider (DaemonSets)
     |  secretProviderClass vault-tokenfactory  (created by the TokenFactory chart: vaultSync)
     v
  Secret tokenfactory-secrets  ->  tf-* pods, Keycloak, OpenFGA, MinIO ... (same as in prod)
```
It is the same mechanism as prod (SecretProviderClass + the `vault-secret-syncer` Deployment), already part of the TokenFactory chart 0.17.7 (`vaultSync`). The package installs and configures everything: `config.env` `SECRETS_BACKEND="vault"` (default), phases `vault` and `secrets` of `airgap/deploy-all.sh`.
With `SECRETS_BACKEND="kubernetes"` the package creates the Secret directly (no Vault).

## 1. What is installed (all from the offline bundle)
| Component | Version | Where |
|---|---|---|
| HashiCorp Vault (server) | 1.21.2 (chart `vault` 0.32.0), standalone, file storage, 10Gi PVC on `STORAGE_CLASS` | namespace `vault` |
| Vault CSI provider | 1.7.0 | namespace `vault` (DaemonSet) |
| Secrets Store CSI driver | 1.5.6, secret sync + rotation (2 min) on | `kube-system` |
| 7 images | in `airgap/images.txt`; charts `vault-0.32.0.tgz`, `secrets-store-csi-driver-1.5.6.tgz` in `bundle/charts/` | |
Vault is **not exposed outside the cluster** unless you set `VAULT_UI="true"` (section 2b: Ingress with TLS and an IP allowlist). It is the same layout prod uses (one pod, file storage); production Vault there is also a single pod.

## 2. What you must do (and what the package does for you)
Nothing to type except the normal deployment: `airgap/deploy-all.sh all` runs:
1. phase `vault`: installs the CSI driver and Vault, **initializes** Vault (5 unseal keys, 3 needed), **unseals** it, enables KV v2 at `secret/`, enables Kubernetes auth, writes the policy and the role `tokenfactory`.
2. phase `secrets`: creates the ServiceAccount `tf-vault-sync`, generates the 19 TokenFactory secrets and stores them in Vault at `secret/tokenfactory` (from the `SMTP_PASSWORD` in `config.env` too), and the 5 service keys in `~/.etisalat-service-keys.env`.
3. phase `app`: the chart creates the SecretProviderClass and the syncer; the CSI driver creates the Secret `tokenfactory-secrets` from Vault.

### Back up these two files NOW (they are written on the install VM, mode 0600)
| File | Why |
|---|---|
| `~/.etisalat-vault-init.json` | the **5 unseal keys and the root token**. Without 3 of the keys Vault cannot be opened after a restart and the data in it is lost. Copy it to a safe **offline** place (and give the keys to different people if policy requires). Do not leave it as the only copy on the VM |
| `~/.etisalat-service-keys.env` | the 5 service keys; every upgrade needs the same values |
Also back up the Vault data: the PVC `data-vault-0` in namespace `vault` (the storage team's backup of the X10000 volume, or `kubectl -n vault exec vault-0 -- tar -C /vault -cf - data > vault-data.tar` while Vault is sealed or idle).

## 2b. Vault web UI (optional): you choose in `config.env`
```
export VAULT_UI="true"                  # "false" = no UI, no ingress (Vault is then reachable only with kubectl exec)
export VAULT_HOST=""                    # empty = vault.<DOMAIN>
export VAULT_UI_ALLOW="172.22.100.0/22" # networks allowed to open it (comma separated CIDRs)
```
With `VAULT_UI="true"` the `vault` phase also creates the TLS Secret (from `TLS_CERT`/`TLS_KEY`) and an Ingress in namespace `vault` on the cluster's Ingress-NGINX (`172.22.100.241`), host `vault.<DOMAIN>`, class `INGRESS_CLASS`.
What you must do around it:
1. **DNS:** `vault.<DOMAIN>` -> `172.22.100.241` (the same IP as portal/admin/www/auth).
2. **Certificate:** the TLS certificate must cover `vault.<DOMAIN>` (a wildcard `*.<DOMAIN>` does).
3. **Allowlist:** `VAULT_UI_ALLOW` is enforced by the community Ingress-NGINX annotation `whitelist-source-range`. If the controller on `172.22.100.241` is the F5 NGINX controller, that annotation is ignored: restrict the Vault Service with a NetworkPolicy instead.
4. Open `https://vault.<DOMAIN>`: when Vault is sealed the UI shows the **unseal** page (enter 3 of the 5 keys); otherwise sign in with **Token** (the root token from `~/.etisalat-vault-init.json`, or a limited token you create).
Turn it off again: `VAULT_UI="false"`, then `airgap/deploy-all.sh render vault` and `kubectl -n vault delete ingress vault`.
Security: Vault holds every TokenFactory secret. Keep `VAULT_UI_ALLOW` to the admin networks only, use TLS, do not share the root token, and prefer `VAULT_UI="false"` when the UI is not needed.

## 2c. Your own values for some secrets (optional): `secrets.local.env`
The 30 secrets are **not** in `config.env` (it is committed to git). By default the `secrets` phase generates them randomly; nothing needs to be typed. Most of them are internal keys that nobody ever types (`db-password`, `jwt-secret`, `encryption-key`, ...). The only values you normally supply from outside:
| Secret | Where it comes from |
|---|---|
| `smtp-password` (the Resend API key) | `SMTP_PASSWORD` in `config.env`, or `secrets.local.env` |
| the admin passwords (`kc-admin-password`, `platform-admin-password`, `platform-init-admin-password`) | random by default (read them with the command in `DEPLOY.md` B8); set your own in `secrets.local.env` if you want to choose them |
| `stripe-webhook-secret`, `stripe-secret-key` | empty on purpose (Stripe is off in this deployment) |
To choose values, **before the first run of the `secrets` phase** copy the example file and keep only the lines you want (the file is git-ignored; never commit it):
```
cd ~/Downloads/E-_TokenFactory
cp secrets.local.env.example secrets.local.env
nano secrets.local.env            # e.g.:  smtp-password=...   and   platform-admin-password=Etisalat#2026x
```
Format: `KEY=VALUE`, one per line. Only the 30 keys are accepted (a typo is an error, not ignored); the admin passwords must have at least 8 characters with upper case, lower case, a digit and a special character; `encryption-key` must be base64 of 32 bytes and **can never be rotated afterwards**, so leave it random unless you must. Copy `secrets.local.env` to the install VM together with the package (it is excluded from git, not from rsync) or create it there. The `secrets` phase prints `overrides from ...: <key names>` (never the values).
This is used **only when `secret/tokenfactory` does not exist yet** (first run). To change a value afterwards, use section 4 (`vault kv patch`), wait about 2 minutes, then restart the services that use it.

## 3. Important operating facts
1. **Vault starts SEALED after every restart** (pod restart, node reboot, upgrade). There is no cloud key to open it automatically in an air-gap. Unseal it with the init file:
   ```
   cd ~/etisalat
   airgap/deploy-all.sh vault          # unseals Vault again (idempotent; the Vault chart is upgraded in place)
   ```
   Check: `kubectl -n vault exec vault-0 -- vault status` shows `Sealed false`.
2. **While Vault is sealed the running TokenFactory keeps working**, because the Kubernetes Secret `tokenfactory-secrets` already exists. What stops: secret rotation, and any new pod that needs the CSI mount (a restart of the `vault-secret-syncer` pod). Unseal first, then restart.
3. A secret changed in Vault reaches the Kubernetes Secret within about 2 minutes (rotation poll). The services read the Secret as environment variables, so **restart the affected Deployments** to use the new value (`kubectl -n tokenfactory rollout restart deploy/tf-auth deploy/tf-accounts` and `sts/keycloak`).
4. Vault is one pod: while it is down nothing syncs. Moving to a 3-pod Raft Vault is a later step; it needs fast local disks (Raft is not recommended on NFS).
5. The root token in the init file is powerful. For daily use create a limited admin policy/token and keep the root token offline.

## 4. Common tasks
| Task | Commands (on the install VM) |
|---|---|
| Check status | `kubectl -n vault get pods` (vault-0 and the vault-csi-provider pods Running); `kubectl -n vault exec vault-0 -- vault status` |
| List the secret **names** (no values) | `TOKEN=$(python3 -c 'import json;print(json.load(open("'$HOME'/.etisalat-vault-init.json"))["root_token"])'); printf '%s\n' "$TOKEN" \| kubectl -n vault exec -i vault-0 -- sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; vault kv metadata get -mount=secret tokenfactory'` |
| Change one secret | open a shell: `kubectl -n vault exec -it vault-0 -- sh`, then `export VAULT_ADDR=http://127.0.0.1:8200; vault login` (paste the root token), `vault kv patch -mount=secret tokenfactory smtp-password='<new>'`; wait 2 minutes; restart the services that use it (see 3.3) |
| Is the Secret synced? | `kubectl -n tokenfactory get secret tokenfactory-secrets` (30 keys: `kubectl -n tokenfactory get secret tokenfactory-secrets -o json \| python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))'`); `kubectl -n tokenfactory get pods -l app=vault-secret-syncer` |
| Add a secret key later | add the key to `values/vaultsync.values.yaml.tmpl` (`keys:`), write it to Vault (`vault kv patch ...`), then `airgap/deploy-all.sh render app` |

## 5. Troubleshooting
| You see | Cause / fix |
|---|---|
| `vault` phase: `Vault is initialized but ~/.etisalat-vault-init.json is missing` | restore the init file from your backup. Without the unseal keys the Vault data cannot be opened (the only way out is a new empty Vault = new secrets) |
| `vault` phase: `Vault is still sealed` | the init file holds the wrong keys (a different Vault) |
| App pods `CreateContainerConfigError` for a few seconds at the first install | normal: the Secret appears when the syncer pod starts (about a minute) |
| Pods stay in `CreateContainerConfigError`, Secret `tokenfactory-secrets` missing | `kubectl -n tokenfactory describe pod -l app=vault-secret-syncer` and `kubectl -n vault logs ds/vault-csi-provider`: Vault sealed, role/ServiceAccount mismatch (`tf-vault-sync` in `tokenfactory`), or the key missing in `secret/tokenfactory` |
| `permission denied` in the CSI provider log | the policy/role: rerun `airgap/deploy-all.sh vault` (it rewrites policy `tokenfactory` and role `tokenfactory`) |
| An empty value (`stripe-webhook-secret`, `stripe-secret-key`) makes the mount fail | it is stored as an empty string (Stripe is off); if your CSI provider refuses empty values, set both to a placeholder such as `unused` with `vault kv patch` |
| Vault pod `Pending` | the PVC `data-vault-0` cannot bind: check the StorageClass (`kubectl -n vault get pvc`, `STORAGE-HPE-CSI.md`) |
| `ErrImagePull` in `vault` or `kube-system` | an image tar is missing on that node: `airgap/deploy-all.sh images`, delete the pod |

## 6. Status
Offline verification only: charts and images rendered (`airgap/deploy-all.sh dry-run` passes, all images are in the bundle) and the shell logic of the Vault configuration was tested against a mock `vault`. It has **not** been run against a real Vault and cluster yet. Report the first failing step with its output.
Not tested: the empty-value keys through the CSI provider (see the table above), and Vault on the X10000 NFS volume (file storage on NFS is common for small data but check latency with the storage team).
