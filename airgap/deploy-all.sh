#!/usr/bin/env bash
# One-command, resumable, idempotent deploy of the Etisalat air-gapped stack.
#   ./deploy-all.sh check            preflight only (read-only)
#   ./deploy-all.sh dry-run          render EVERY chart offline with helm template (no cluster needed) - run this first
#   ./deploy-all.sh all              check -> prepare -> render -> ns -> images -> pg -> secrets -> controllers -> ingress -> openmeter -> app -> verify
#   ./deploy-all.sh <phase> [...]    run specific phases;   ./deploy-all.sh --from <phase>   resume from a phase
# Phases: check prepare render ns images jar storage vault pg secrets controllers ingress openmeter app verify   (push = optional, only if you DO have a registry)
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
PHASES=(check prepare render ns images jar storage vault pg secrets controllers ingress openmeter app verify)
ALLPH=(push "${PHASES[@]}")
OUT="$ROOT/rendered"; KEYFILE="${KEYFILE:-$HOME/.etisalat-service-keys.env}"
C="$BUNDLE_DIR/charts"; ZC="$ROOT/zalando/charts"
log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
wait_for(){ # desc timeout_s cmd...
  local d="$1" t="$2"; shift 2; local s=$SECONDS
  until "$@" >/dev/null 2>&1; do [ $((SECONDS-s)) -gt "$t" ] && die "timeout (${t}s) waiting for: $d"; sleep 5; done; echo "  ok: $d"; }
VARS='REGISTRY TF_TAG BRAND_TAG DOMAIN SUPPORT_EMAIL STORAGE_CLASS PLATFORM_ADMIN_EMAIL SMTP_HOST SMTP_PORT SMTP_USER KEYCLOAK_JAR_URL DOCS_WEB_ENABLED ENVOY_REPLICAS ENVOY_PDB_MIN_AVAILABLE KEYCLOAK_REPLICAS KEYCLOAK_MEM_REQUEST KEYCLOAK_MEM_LIMIT KEYCLOAK_HEAP INGRESS_ENABLED SMTP_SSL SMTP_STARTTLS INGRESS_TLS_SECRET TF_LEDGER_REPLICAS INGRESS_CLASS X10000_ACL X10000_ALLOW_EXPANSION VAULT_NAMESPACE VAULT_STORAGE_SIZE VAULT_UI VAULT_HOST VAULT_UI_ALLOW'
# Keycloak SPI jar: empty KEYCLOAK_JAR_URL = host the bundled jar inside the cluster (phase `jar`)
JAR_FILE="$(ls "$BUNDLE_DIR"/jars/*.jar 2>/dev/null | sort -V | tail -1 || true)"   # newest version if several jars are present; JAR_INCLUSTER=0
if [ -z "${KEYCLOAK_JAR_URL:-}" ]; then JAR_INCLUSTER=1; KEYCLOAK_JAR_URL="http://keycloak-spi.${NAMESPACE}.svc.cluster.local:8080/$(basename "${JAR_FILE:-keycloak-2fa-email-authenticator.jar}")"; fi
export KEYCLOAK_JAR_URL
# defaults keep an older config.env working
: "${ENVOY_REPLICAS:=6}" "${ENVOY_PDB_MIN_AVAILABLE:=1}" "${KEYCLOAK_REPLICAS:=3}" "${KEYCLOAK_MEM_REQUEST:=1Gi}" "${KEYCLOAK_MEM_LIMIT:=2Gi}"
: "${KEYCLOAK_HEAP:=-Xms512m -Xmx2g -XX:+UseContainerSupport}" "${INGRESS_ENABLED:=true}"
: "${SMTP_SSL:=true}" "${SMTP_STARTTLS:=false}" "${EXPOSE:=loadbalancer}" "${BEHIND_CLOUDFLARE:=no}" "${INGRESS_TLS:=yes}" "${INGRESS_TLS_SECRET:=tf-etisalat-tls}"   # older config.env keeps the old behaviour
: "${PLATFORM_ADMIN_EMAIL:=admin@${DOMAIN}}" "${VAULT_UI:=false}" "${VAULT_HOST:=vault.${DOMAIN:-}}" "${VAULT_UI_ALLOW:=172.22.100.0/22}" "${SECRETS_BACKEND:=kubernetes}" "${VAULT_NAMESPACE:=vault}" "${VAULT_STORAGE_SIZE:=10Gi}" "${VAULT_INIT_FILE:=$HOME/.etisalat-vault-init.json}" "${STORAGE_BACKEND:=existing}" "${X10000_ACL:=}" "${X10000_ALLOW_EXPANSION:=false}" "${INGRESS_CONTROLLER:=install}" "${INGRESS_CLASS:=nginx}" "${ENVOY_LB_IP:=}" "${PG_VERSION:=16}" "${KEYCLOAK_ANTIAFFINITY:=required}" "${PG_INSTANCES:=3}" "${PG_VOLUME_SIZE:=20Gi}" "${PG_CPU_REQUEST:=1}" "${PG_MEM_REQUEST:=2Gi}" "${PG_CPU_LIMIT:=4}" "${PG_MEM_LIMIT:=8Gi}" "${PG_MAX_CONNECTIONS:=300}"
export INGRESS_CLASS ENVOY_REPLICAS ENVOY_PDB_MIN_AVAILABLE KEYCLOAK_REPLICAS KEYCLOAK_MEM_REQUEST KEYCLOAK_MEM_LIMIT KEYCLOAK_HEAP INGRESS_ENABLED SMTP_SSL SMTP_STARTTLS INGRESS_TLS_SECRET
# per-service replicas + CPU/RAM (defaults = live xailon-tf-prod values; an older config.env without these lines still works)
: "${SVC_TF_ACCOUNTS:=3 50m 64Mi 200m 256Mi}" "${SVC_TF_ADMIN_WEB:=3 none}" "${SVC_TF_AUTH:=3 none}" "${SVC_TF_BABEL:=3 25m 32Mi 300m 256Mi}" "${SVC_TF_CONTROL:=3 none}"
: "${SVC_TF_DOCS_WEB:=1 50m 96Mi 300m 256Mi}" "${SVC_TF_LEDGER:=3 none}" "${SVC_TF_OPS:=3 20m 48Mi 250m 128Mi}" "${SVC_TF_PORTAL_WEB:=3 50m 32Mi 200m 1Gi}" "${SVC_TF_RELAY:=3 none}"
: "${SVC_TF_SHIM:=3 25m 256Mi 1 1Gi}" "${SVC_TF_SITE_WEB:=1 50m 64Mi 300m 256Mi}" "${SVC_TF_WARDEN:=3 none}"
: "${RES_OPENFGA:=- 64Mi - 256Mi}" "${RES_MINIO:=50m 128Mi 300m 512Mi}" "${RES_REDIS:=100m 1Gi 1 4Gi}"
INST_DEF="$PG_INSTANCES"; [ "${SINGLE_NODE:-no}" = yes ] && INST_DEF=1
PG_SET=(--set registry="$REGISTRY" --set-string postgresVersion="$PG_VERSION" --set volume.storageClass="$STORAGE_CLASS" --set numberOfInstances="$INST_DEF" --set-string volume.size="$PG_VOLUME_SIZE"
        --set-string resources.requests.cpu="$PG_CPU_REQUEST" --set-string resources.requests.memory="$PG_MEM_REQUEST"
        --set-string resources.limits.cpu="$PG_CPU_LIMIT" --set-string resources.limits.memory="$PG_MEM_LIMIT" --set-string parameters.max_connections="$PG_MAX_CONNECTIONS")
DRY=0
export DOCS_WEB_ENABLED=$([ "${DOCS_WEB:-no}" = yes ] && echo true || echo false)
kc(){ if [ $DRY = 1 ]; then echo "  [dry-run] kubectl $*"; else kubectl "$@"; fi; }

phase_check(){
  log "check"
  # Tools this machine needs. kubectl and helm come from bundle/tools; the rest are standard on Ubuntu 24.04 server. Checked together, so ONE message lists every missing tool.
  local miss="" t pk="" REQ="kubectl helm openssl perl python3 tar awk sed grep base64"
  [ "${IMAGE_MODE:-tar}" = tar ] && [ "${NODE_LOAD_MODE:-}" = ssh ] && REQ="$REQ ssh scp"
  for t in $REQ; do command -v "$t" >/dev/null 2>&1 || { miss="$miss $t"; case "$t" in
      perl) pk="$pk perl";; python3) pk="$pk python3";; openssl) pk="$pk openssl";; tar) pk="$pk tar";; awk) pk="$pk gawk";;
      sed|grep|base64) pk="$pk coreutils/sed/grep";; ssh|scp) pk="$pk openssh-client";; esac; }; done
  [ -z "$miss" ] || die "missing tools on this machine:$miss
   Ubuntu packages:$pk   (install them from the machine's OS media / internal mirror: DEPLOY.md B2, 'If a tool is missing').
   kubectl and helm are NOT packages: they come with the bundle (bundle/tools), so a missing kubectl/helm means the bundle was not copied completely."
  [ -f "$KUBECONFIG_FILE" ] || die "KUBECONFIG_FILE=$KUBECONFIG_FILE not found"
  if [ "${IMAGE_MODE:-tar}" = registry ]; then need skopeo; case "$REGISTRY" in registry.etisalat.local*) die "IMAGE_MODE=registry but REGISTRY is still the placeholder name";; esac; fi
  local bad; bad=$(env | grep -E '^[A-Za-z0-9_]+=.*REPLACE_' || true)   # EFFECTIVE values: a later line in config.env (or an override block) wins over an earlier REPLACE_ line
  [ "$STORAGE_BACKEND" = hpe-x10000 ] || bad=$(echo "$bad" | grep -v '^X10000_' || true)
  case "$SECRETS_BACKEND" in vault|kubernetes) ;; *) die "SECRETS_BACKEND must be vault or kubernetes";; esac
  case "$STORAGE_BACKEND" in hpe-x10000|existing) ;; *) die "STORAGE_BACKEND must be hpe-x10000 or existing";; esac
  [ -z "$bad" ] || die "config.env still has REPLACE_ values (name=value):"$'\n'"$bad"
  for v in REGISTRY NAMESPACE DOMAIN TF_TAG BRAND_TAG STORAGE_CLASS SMTP_HOST SMTP_PORT SMTP_USER CH_DATA_SIZE CH_LOG_SIZE; do [ -n "${!v:-}" ] || die "config.env: $v is empty"; done
  case "$REGISTRY" in *://*) die "REGISTRY must be host[:port] without scheme";; esac
  [ "$INGRESS_TLS" = yes ] || die "INGRESS_TLS must be yes: this package deploys the Ingress with TLS only (chart >= 0.17 refuses a plain-HTTP Ingress)"
  if true; then   # TLS certificate is always required (Ingress TLS Secret, and Envoy TLS when BEHIND_CLOUDFLARE=no)
    [ -f "${TLS_CERT:-}" ] && [ -f "${TLS_KEY:-}" ] || die "a TLS certificate is needed (INGRESS_TLS=yes or BEHIND_CLOUDFLARE=no): TLS_CERT / TLS_KEY files not found"
    openssl x509 -in "$TLS_CERT" -noout -checkend 0 >/dev/null || die "TLS certificate is expired"
    [ "$(openssl x509 -in "$TLS_CERT" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$TLS_KEY" -pubout 2>/dev/null | openssl sha256)" ] || die "TLS_CERT and TLS_KEY do not belong together"
  fi
  if [ "$NODE_LOAD_MODE" = ssh ] && [ "${IMAGE_MODE:-tar}" = tar ]; then [ -n "${NODES// /}" ] || die "NODE_LOAD_MODE=ssh needs NODES in config.env"; fi
  [ -d "$REPO/helm/tokenfactory" ] || die "repo not found at $REPO (run airgap/00-fetch-chart.sh on the Mac and copy the whole folder to the VM)"
  if [ "$SECRETS_BACKEND" = vault ]; then for f in vault-0.32.0 secrets-store-csi-driver-1.5.6; do [ -f "$BUNDLE_DIR/charts/$f.tgz" ] || die "bundle file missing: charts/$f.tgz (re-run airgap/01-bundle-connected.sh on the Mac)"; done; fi
  if [ "$STORAGE_BACKEND" = hpe-x10000 ]; then [ -f "$BUNDLE_DIR/charts/hpe-csi-driver-3.2.0.tgz" ] || die "bundle file missing: charts/hpe-csi-driver-3.2.0.tgz (re-run airgap/01-bundle-connected.sh on the Mac)"; fi
  for f in charts/gateway-helm-v1.8.1.tgz charts/ai-gateway-crds-helm-v1.0.0.tgz charts/ai-gateway-helm-v1.0.0.tgz charts/nginx-ingress-1.3.2.tgz crds/gateway-api-standard-install-v1.3.0.yaml; do [ -f "$BUNDLE_DIR/$f" ] || die "bundle file missing: $f"; done
  if [ $DRY = 0 ]; then
    kubectl version --request-timeout=10s >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
    local n; n=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true); echo "  ready nodes: $n"
    if [ "${SINGLE_NODE:-no}" = yes ]; then echo "  SINGLE_NODE=yes (lab): Postgres will run 1 instance"; else [ "$n" -ge 3 ] || die "need >=3 Ready nodes (pgdb has 3 instances with anti-affinity); for a 1-node lab set SINGLE_NODE=yes"; fi
    if [ "$STORAGE_BACKEND" = existing ]; then
      kubectl get sc "$STORAGE_CLASS" >/dev/null 2>&1 || die "StorageClass '$STORAGE_CLASS' not found (kubectl get sc)"
      [ "$(kubectl get sc "$STORAGE_CLASS" -o jsonpath='{.allowVolumeExpansion}')" = "true" ] || echo "  WARNING: StorageClass $STORAGE_CLASS has allowVolumeExpansion!=true"
    else echo "  StorageClass $STORAGE_CLASS will be created by phase storage (HPE X10000)"; fi
    if [ "$PG_OPERATOR_MODE" = existing ]; then kubectl get crd postgresqls.acid.zalan.do >/dev/null 2>&1 || die "PG_OPERATOR_MODE=existing but no postgresqls.acid.zalan.do CRD"; fi
    [ -s "$BUNDLE_DIR/tars/INDEX" ] || die "image tars missing: $BUNDLE_DIR/tars (copy the bundle)"
  fi
  case "$INGRESS_CONTROLLER" in install|existing) ;; *) die "INGRESS_CONTROLLER must be install or existing";; esac
  if [ $DRY = 0 ] && [ "$INGRESS_CONTROLLER" = existing ]; then kubectl get ingressclass "$INGRESS_CLASS" >/dev/null 2>&1 || die "INGRESS_CONTROLLER=existing but no IngressClass '$INGRESS_CLASS' (kubectl get ingressclass): set INGRESS_CLASS to the class of the cluster's ingress controller, or INGRESS_CONTROLLER=install"; fi
  if [ $JAR_INCLUSTER = 1 ]; then [ -s "$JAR_FILE" ] || die "no Keycloak jar in $BUNDLE_DIR/jars (rebuild the bundle) and KEYCLOAK_JAR_URL is empty"; fi
  if [ "${SMTP_USER:-}" = resend ] && [ -z "${SMTP_PASSWORD:-}" ]; then echo "  WARNING: SMTP_USER=resend but SMTP_PASSWORD (the Resend API key) is empty - no mails will be sent (sign-up/OTP/reset)"; fi
  echo "  check passed"
}

phase_push(){ log "push images -> $REGISTRY (only for registry setups)"; ./02-push-registry.sh; }
phase_images(){
  if [ "${IMAGE_MODE:-tar}" = registry ]; then log "push image tars -> $REGISTRY (IMAGE_MODE=registry)"; ./02-push-registry.sh
  else log "load image tars into every node ($NODE_LOAD_MODE)"; ./load-images.sh "$NODE_LOAD_MODE"; fi
}

phase_prepare(){
  log "prepare (patch hardcoded images, ingress template, vendor subcharts)"
  REPO="$REPO" REGISTRY="$REGISTRY" STORAGE_CLASS="$STORAGE_CLASS" CH_DATA_SIZE="$CH_DATA_SIZE" CH_LOG_SIZE="$CH_LOG_SIZE" ./03-patch-hardcoded-images.sh
  [ -f "$REPO/helm/tokenfactory/templates/ingress.yaml" ] || die "helm/tokenfactory/templates/ingress.yaml is missing in $REPO: the chart checkout is not the pinned release (run airgap/00-fetch-chart.sh on the Mac and copy the folder again)"
  echo "  ingress template present"
  (cd "$REPO/helm/tokenfactory" && helm dependency build >/dev/null) && echo "  umbrella subcharts vendored (file:// only)"
}


# ---- rendered/services.yaml: replicas + CPU/RAM of every tf-* service and of openfga/minio/redis, Keycloak anti-affinity (all from config.env) ----
res_yaml(){ # INDENT CPU_REQ MEM_REQ CPU_LIM MEM_LIM | INDENT none     ("-" = leave that value out)
  local i="$1"; shift
  if [ "${1:-}" = none ]; then printf '%sresources:\n%s  requests: null\n%s  limits: null\n' "$i" "$i" "$i"; return; fi
  [ $# -eq 4 ] || die "bad resources spec '$*' (need: cpu-request mem-request cpu-limit mem-limit, or none)"
  local rq="" lm=""
  [ "$1" = - ] || rq="cpu: \"$1\""; [ "$2" = - ] || rq="${rq:+$rq, }memory: \"$2\""
  [ "$3" = - ] || lm="cpu: \"$3\""; [ "$4" = - ] || lm="${lm:+$lm, }memory: \"$4\""
  printf '%sresources:\n' "$i"
  printf '%s  requests: { %s }\n' "$i" "$rq"; printf '%s  limits: { %s }\n' "$i" "$lm"
}
gen_services(){
  local f="$OUT/services.yaml" n var spec rep
  { echo "# generated by deploy-all.sh render from config.env (SVC_* / RES_* / KEYCLOAK_ANTIAFFINITY). Do not edit: change config.env."
    for n in tf-accounts tf-admin-web tf-auth tf-babel tf-control tf-docs-web tf-ledger tf-ops tf-portal-web tf-relay tf-shim tf-site-web tf-warden; do
      var="SVC_$(echo "$n" | tr 'a-z-' 'A-Z_' | sed 's/^TF_/TF_/')"; spec="${!var}"
      set -- $spec; [ $# -ge 2 ] || die "$var='$spec': need '<replicas> none' or '<replicas> cpu-req mem-req cpu-lim mem-lim'"
      rep="$1"; shift; case "$rep" in ''|*[!0-9]*) die "$var: replicas '$rep' is not a number";; esac
      echo "$n:"; [ "$n" = tf-docs-web ] && echo "  enabled: $DOCS_WEB_ENABLED"
      echo "  replicas: $rep"; res_yaml "  " "$@"
    done
    for n in openfga minio redis; do var="RES_$(echo $n | tr a-z A-Z)"; set -- ${!var}; echo "$n:"; res_yaml "  " "$@"; done
    local mode="$KEYCLOAK_ANTIAFFINITY"; [ "${SINGLE_NODE:-no}" = yes ] && mode=preferred
    echo "keycloak:"; echo "  affinity:"; echo "    podAntiAffinity:"
    if [ "$mode" = required ]; then
      echo "      requiredDuringSchedulingIgnoredDuringExecution:"
      echo "        - topologyKey: kubernetes.io/hostname"; echo "          labelSelector:"; echo "            matchLabels: { app.kubernetes.io/name: keycloak }"
    else
      echo "      preferredDuringSchedulingIgnoredDuringExecution:"
      echo "        - weight: 100"; echo "          podAffinityTerm:"; echo "            topologyKey: kubernetes.io/hostname"; echo "            labelSelector:"; echo "              matchLabels: { app.kubernetes.io/name: keycloak }"
    fi
  } > "$f"
  echo "  services.yaml generated (replicas/CPU/RAM from config.env, Keycloak anti-affinity: $mode)"
}

phase_render(){
  log "render values -> $OUT"
  umask 077; mkdir -p "$OUT"
  for n in umbrella openmeter nginx-ingress envoy-gateway ai-gateway; do
    envsub $VARS < "$ROOT/values/$n.values.yaml.tmpl" > "$OUT/$n.yaml"
    ! grep -q '\${' "$OUT/$n.yaml" || die "unreplaced \${VAR} in $OUT/$n.yaml: $(grep -n '\${' "$OUT/$n.yaml" | head -2)"
  done
  gen_services
  if [ "$STORAGE_BACKEND" = hpe-x10000 ]; then
    for n in hpe-csi:values/hpe-csi.values.yaml.tmpl storageclass-hpe-x10000:values/storageclass-hpe-x10000.yaml.tmpl; do
      envsub $VARS < "$ROOT/${n#*:}" > "$OUT/${n%%:*}.yaml"; ! grep -q '\${' "$OUT/${n%%:*}.yaml" || die "unreplaced \${VAR} in $OUT/${n%%:*}.yaml"
    done
    echo "  hpe-csi.yaml and storageclass-hpe-x10000.yaml rendered"
  fi
  echo '{}' > "$OUT/vaultsync.yaml"
  if [ "$SECRETS_BACKEND" = vault ]; then
    for n in vault:vault.values.yaml.tmpl secrets-store-csi:secrets-store-csi.values.yaml.tmpl vaultsync:vaultsync.values.yaml.tmpl; do
      envsub $VARS < "$ROOT/values/${n#*:}" > "$OUT/${n%%:*}.yaml"; ! grep -q '\${' "$OUT/${n%%:*}.yaml" || die "unreplaced \${VAR} in $OUT/${n%%:*}.yaml"
    done
    if [ "$VAULT_UI" = true ]; then
      [ -n "${VAULT_HOST:-}" ] || die "VAULT_UI=true needs VAULT_HOST in config.env"
      envsub $VARS < "$ROOT/values/vault-ingress.yaml.tmpl" > "$OUT/vault-ingress.yaml"; ! grep -q '\${' "$OUT/vault-ingress.yaml" || die "unreplaced \${VAR} in $OUT/vault-ingress.yaml"
    fi
    echo "  vault.yaml, secrets-store-csi.yaml and vaultsync.yaml rendered (SECRETS_BACKEND=vault, UI=$VAULT_UI)"
  fi
  if [ "${XAILON_INTEGRATIONS:-no}" = yes ]; then cp "$ROOT/values/xailon-integrations.yaml" "$OUT/integrations.yaml"; echo "  xailon-tf-prod integrations layer ON (Persona CDD, Zendesk, Google/Microsoft ids, PKCE)"; else echo '{}' > "$OUT/integrations.yaml"; fi
  if [ -n "${CUSTOM_VALUES_YAML//[[:space:]]/}" ]; then printf '%s\n' "$CUSTOM_VALUES_YAML" > "$OUT/custom.yaml"; echo "  custom values from config.env CUSTOM_VALUES_YAML applied"; else echo '{}' > "$OUT/custom.yaml"; fi
  if [ "$EXPOSE" = clusterip ]; then cp "$ROOT/values/expose-clusterip.umbrella.yaml" "$OUT/lb-umbrella.yaml"; cp "$ROOT/values/expose-clusterip.nginx.yaml" "$OUT/lb-nginx.yaml"
  elif [ "${LB_INTERNAL:-no}" = yes ]; then cp "$ROOT/values/lb-internal.umbrella.yaml" "$OUT/lb-umbrella.yaml"; cp "$ROOT/values/lb-internal.nginx.yaml" "$OUT/lb-nginx.yaml"
  else cp "$ROOT/values/lb-none.yaml" "$OUT/lb-umbrella.yaml"; cp "$ROOT/values/lb-none.yaml" "$OUT/lb-nginx.yaml"; fi
  echo '{}' > "$OUT/lb-envoyip.yaml"
  if [ "$EXPOSE" = loadbalancer ] && [ -n "${ENVOY_LB_IP:-}" ]; then   # MetalLB (or any LB): fixed IP for api.
    { echo "tf-gateway-resources:"; echo "  envoyProxy:"; echo "    spec:"; echo "      provider:"; echo "        kubernetes:"; echo "          envoyService:"; echo "            loadBalancerIP: $ENVOY_LB_IP"; } > "$OUT/lb-envoyip.yaml"
    echo "  Envoy (api.) Service LoadBalancer IP: $ENVOY_LB_IP"
  fi
  if [ "$BEHIND_CLOUDFLARE" = yes ]; then cp "$ROOT/values/edge-cloudflare.yaml" "$OUT/edge.yaml"; else echo '{}' > "$OUT/edge.yaml"; fi
  echo '{}' > "$OUT/tlsmode.yaml"   # Ingress is always TLS (INGRESS_TLS=yes is enforced in `check`)
  echo "  rendered values (no secrets inside); LB_INTERNAL=${LB_INTERNAL:-no}"
}

phase_ns(){
  log "namespaces, pull secrets, TLS"
  local NSLIST="postgres $NAMESPACE openmeter envoy-gateway-system envoy-ai-gateway-system nginx-ingress"; [ "$STORAGE_BACKEND" = hpe-x10000 ] && NSLIST="$NSLIST hpe-storage"; [ "$SECRETS_BACKEND" = vault ] && NSLIST="$NSLIST $VAULT_NAMESPACE"
  for ns in $NSLIST; do
    kubectl create ns "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kubectl -n "$ns" create secret docker-registry registry-pull --docker-server="$REGISTRY" \
      --docker-username="${REGISTRY_USER:-anonymous}" --docker-password="${REGISTRY_PASS:-anonymous}" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kubectl -n "$ns" patch sa default -p '{"imagePullSecrets":[{"name":"registry-pull"}]}' >/dev/null   # also covers ad-hoc pods (preflight probe, hooks)
    echo "  $ns: ready"
  done
  if [ "$INGRESS_TLS" = yes ]; then
    kubectl -n "$NAMESPACE" create secret tls "$INGRESS_TLS_SECRET" --cert="$TLS_CERT" --key="$TLS_KEY" --dry-run=client -o yaml | kc apply -f - >/dev/null
    echo "  $INGRESS_TLS_SECRET: applied (Ingress TLS)"
  else echo "  INGRESS_TLS=no: Ingress without TLS"; fi
  if [ "$BEHIND_CLOUDFLARE" != yes ]; then
    kubectl -n "$NAMESPACE" create secret tls tf-etisalat-tls --cert="$TLS_CERT" --key="$TLS_KEY" --dry-run=client -o yaml | kc apply -f - >/dev/null
    echo "  tf-etisalat-tls: applied (Envoy Gateway TLS)"
  fi
}

phase_jar(){
  log "Keycloak SPI jar server"
  if [ $JAR_INCLUSTER = 0 ]; then echo "  using your own URL: $KEYCLOAK_JAR_URL (nothing to host)"; return 0; fi
  local name; name="$(basename "$JAR_FILE")"
  kubectl -n "$NAMESPACE" create configmap keycloak-spi-jar --from-file="$JAR_FILE" --dry-run=client -o yaml | kc apply -f - >/dev/null
  cat <<YAML | kc apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: keycloak-spi, namespace: $NAMESPACE, labels: { app.kubernetes.io/name: keycloak-spi } }
spec:
  replicas: 2
  selector: { matchLabels: { app.kubernetes.io/name: keycloak-spi } }
  template:
    metadata: { labels: { app.kubernetes.io/name: keycloak-spi } }
    spec:
      containers:
      - name: httpd
        image: $REGISTRY/busybox:1.37.0
        imagePullPolicy: IfNotPresent
        command: ["httpd","-f","-p","8080","-h","/www"]
        ports: [ { containerPort: 8080 } ]
        securityContext: { runAsNonRoot: true, runAsUser: 65534, readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
        resources: { requests: { cpu: 5m, memory: 8Mi }, limits: { cpu: 50m, memory: 32Mi } }
        volumeMounts: [ { name: jar, mountPath: /www } ]
      volumes: [ { name: jar, configMap: { name: keycloak-spi-jar } } ]
---
apiVersion: v1
kind: Service
metadata: { name: keycloak-spi, namespace: $NAMESPACE }
spec:
  selector: { app.kubernetes.io/name: keycloak-spi }
  ports: [ { port: 8080, targetPort: 8080 } ]
YAML
  [ $DRY = 1 ] || wait_for "keycloak-spi ready" 300 kubectl -n "$NAMESPACE" rollout status deploy/keycloak-spi --timeout=10s
  echo "  jar URL for Keycloak: $KEYCLOAK_JAR_URL"
}

phase_storage(){
  if [ "$STORAGE_BACKEND" != hpe-x10000 ]; then log "storage: STORAGE_BACKEND=$STORAGE_BACKEND - nothing to install"; return 0; fi
  log "HPE CSI Driver 3.2.0 (X10000 NFS) + StorageClass $STORAGE_CLASS"
  helm upgrade --install hpe-csi "$C/hpe-csi-driver-3.2.0.tgz" -n hpe-storage -f "$OUT/hpe-csi.yaml" --wait --timeout 10m
  if [ $DRY = 1 ]; then echo "  [dry-run] would create Secret hpe-backend and StorageClass $STORAGE_CLASS"; return 0; fi
  : "${X10000_CLIENT_SECRET:?run first: read -rs X10000_CLIENT_SECRET; export X10000_CLIENT_SECRET   (the CSP client secret from the X10000 admin)}"
  local be="$X10000_MGMT"; case "$be" in *:*) ;; *) be="$be:443";; esac
  kubectl -n hpe-storage create secret generic hpe-backend --from-literal=serviceName=alletrastoragemp-x10000-nfs-csp-svc --from-literal=servicePort=8080 \
    --from-literal=backend="$be" --from-literal=username="$X10000_CLIENT_ID" --from-literal=password="$X10000_CLIENT_SECRET" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  Secret hpe-backend applied (backend $be)"
  kubectl apply -f "$OUT/storageclass-hpe-x10000.yaml" >/dev/null && echo "  StorageClass $STORAGE_CLASS applied"
  wait_for "HPE CSI controller Available" 300 kubectl -n hpe-storage rollout status deploy/hpe-csi-controller --timeout=10s
  wait_for "X10000 NFS CSP Available" 300 kubectl -n hpe-storage rollout status deploy/alletrastoragemp-x10000-nfs-csp --timeout=10s
  kubectl get sc "$STORAGE_CLASS"
}

# ---- Vault helpers: commands run INSIDE vault-0; the root token travels on stdin (never on a command line) ----
vtok(){ python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["root_token"])' "$VAULT_INIT_FILE"; }
vexec(){ { vtok; printf '%s\n' "$1"; } | kubectl -n "$VAULT_NAMESPACE" exec -i vault-0 -- sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; sh -s'; }
vstatus(){ kubectl -n "$VAULT_NAMESPACE" exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json' 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(("init=%s sealed=%s")%(str(d.get("initialized")).lower(),str(d.get("sealed")).lower()))' 2>/dev/null || echo "init=unknown sealed=unknown"; }

phase_vault(){
  if [ "$SECRETS_BACKEND" != vault ]; then log "vault: SECRETS_BACKEND=$SECRETS_BACKEND - nothing to install"; return 0; fi
  log "Secrets Store CSI driver + dedicated HashiCorp Vault (namespace $VAULT_NAMESPACE)"
  helm upgrade --install csi-secrets-store "$C/secrets-store-csi-driver-1.5.6.tgz" -n kube-system -f "$OUT/secrets-store-csi.yaml" --wait --timeout 10m
  helm upgrade --install vault "$C/vault-0.32.0.tgz" -n "$VAULT_NAMESPACE" -f "$OUT/vault.yaml" --timeout 10m
  [ $DRY = 1 ] && { echo "  [dry-run] would initialize, unseal and configure Vault"; return 0; }
  wait_for "vault-0 pod Running" 600 bash -c "[ \"\$(kubectl -n $VAULT_NAMESPACE get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null)\" = Running ]"
  wait_for "vault server answering" 180 bash -c "kubectl -n $VAULT_NAMESPACE exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' 2>&1 | grep -q 'Initialized'"
  local st; st=$(vstatus); echo "  vault: $st"
  case "$st" in
    *init=false*)
      [ ! -s "$VAULT_INIT_FILE" ] || die "Vault is not initialized but $VAULT_INIT_FILE already exists: move it away (stale file)"
      ( umask 077; kubectl -n "$VAULT_NAMESPACE" exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault operator init -key-shares=5 -key-threshold=3 -format=json' > "$VAULT_INIT_FILE" )
      python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert len(d["unseal_keys_b64"])==5 and d["root_token"]' "$VAULT_INIT_FILE" || die "vault operator init failed (see $VAULT_INIT_FILE)"
      echo "  initialized: 5 unseal keys (3 needed) and the root token are in $VAULT_INIT_FILE (0600) - COPY IT TO A SAFE OFFLINE PLACE NOW"; st=$(vstatus);;
    *init=true*) [ -s "$VAULT_INIT_FILE" ] || die "Vault is initialized but $VAULT_INIT_FILE is missing: restore the init file from your backup (without the unseal keys Vault cannot be opened)";;
    *) die "cannot read the Vault status";;
  esac
  case "$st" in *sealed=true*)
    local i k; for i in 0 1 2; do
      k=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["unseal_keys_b64"][int(sys.argv[2])])' "$VAULT_INIT_FILE" "$i")
      printf '%s\n' "$k" | kubectl -n "$VAULT_NAMESPACE" exec -i vault-0 -- sh -c 'IFS= read -r K; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$K"' >/dev/null
    done; echo "  vault: $(vstatus)";; esac
  case "$(vstatus)" in *sealed=false*) ;; *) die "Vault is still sealed";; esac
  vexec 'vault secrets list -format=json | grep -q "\"secret/\"" || vault secrets enable -path=secret kv-v2
vault auth list -format=json | grep -q "\"kubernetes/\"" || vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" >/dev/null
vault policy write tokenfactory - <<"POLICY"
path "secret/data/tokenfactory" { capabilities = ["read"] }
path "secret/metadata/tokenfactory" { capabilities = ["read", "list"] }
POLICY
vault write auth/kubernetes/role/tokenfactory bound_service_account_names=tf-vault-sync bound_service_account_namespaces='"$NAMESPACE"' policies=tokenfactory ttl=1h >/dev/null
echo configured' | tail -1
  echo "  Vault ready: KV v2 at secret/, Kubernetes auth, policy + role 'tokenfactory' (ServiceAccount tf-vault-sync in $NAMESPACE)"
  if [ "$VAULT_UI" = true ]; then
    kubectl -n "$VAULT_NAMESPACE" create secret tls "$INGRESS_TLS_SECRET" --cert="$TLS_CERT" --key="$TLS_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl apply -f "$OUT/vault-ingress.yaml" >/dev/null
    echo "  Vault UI: https://$VAULT_HOST  (allowed networks: $VAULT_UI_ALLOW; create DNS $VAULT_HOST -> the ingress controller IP)"
  fi
  kubectl -n "$VAULT_NAMESPACE" get pods
}

secrets_vault(){
  log "tokenfactory secrets -> Vault (secret/tokenfactory) + service keys"
  kubectl -n "$NAMESPACE" create serviceaccount tf-vault-sync --dry-run=client -o yaml | kubectl apply -f - >/dev/null; echo "  ServiceAccount tf-vault-sync: ready"
  if vexec 'vault kv get -mount=secret tokenfactory >/dev/null 2>&1 && echo EXISTS' | grep -q EXISTS; then
    [ -f "$KEYFILE" ] || die "Vault already holds secret/tokenfactory but $KEYFILE is missing (service keys must stay stable) - restore it from backup"
    echo "  secret/tokenfactory exists in Vault - keeping it (service keys: $KEYFILE)"; return 0; fi
  [ ! -e "$KEYFILE" ] || die "$KEYFILE exists but Vault has no secret/tokenfactory - remove the stale file or restore the Vault data"
  local json SF="${SECRETS_FILE:-$ROOT/secrets.local.env}"; json=$(SMTP_PASSWORD="${SMTP_PASSWORD:-}" SECRETS_FILE="$SF" python3 - <<'PY'
import json, os, secrets, base64
g=lambda: secrets.token_hex(32)
pw=lambda: "Aa1!"+secrets.token_hex(12)
jwt=g()
d={"db-password":g(),"jwt-secret":jwt,"portal-jwt-secret":jwt,"admin-api-key":g(),
   "encryption-key":base64.b64encode(secrets.token_bytes(32)).decode(),
   "ce-userinfo-signing-key":g(),"auth-state-signing-key":g(),
   "kc-admin-username":"admin","kc-admin-password":pw(),"kc-db-username":"keycloak","kc-db-password":g(),
   "openfga-db-password":g(),"s3-access-key":secrets.token_hex(10),"s3-secret-key":g(),
   "stripe-webhook-secret":"","stripe-secret-key":"","smtp-password":os.environ.get("SMTP_PASSWORD",""),
   "platform-admin-password":pw(),"platform-init-admin-password":pw(),
   "cdd-email-hmac-key":g(),"redis-password":base64.b64encode(secrets.token_bytes(32)).decode(),
   # external integrations: empty unless you give them in secrets.local.env
   "google-client-secret":"","microsoft-client-secret":"","persona-api-key":"","persona-webhook-secret":"",
   "zendesk-oauth-client-id":"","zendesk-oauth-client-secret":"","zendesk-signing-secret":"","cloudflare-tunnel-token":"","random-test-secret":""}
# optional overrides from secrets.local.env (git-ignored): one KEY=VALUE per line, only these keys
path=os.environ.get("SECRETS_FILE","")
if path and os.path.isfile(path):
    import re, sys
    over=[]
    for n,line in enumerate(open(path),1):
        line=line.strip()
        if not line or line.startswith("#"): continue
        if "=" not in line: sys.exit("%s line %d: expected KEY=VALUE"%(path,n))
        k,v=line.split("=",1); k=k.strip(); v=v.strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "\"'": v=v[1:-1]
        if k not in d: sys.exit("%s line %d: unknown key '%s' (allowed: %s)"%(path,n,k,", ".join(sorted(d))))
        if k in ("kc-admin-password","platform-admin-password","platform-init-admin-password"):
            if not(len(v)>=8 and re.search("[a-z]",v) and re.search("[A-Z]",v) and re.search("[0-9]",v) and re.search("[^A-Za-z0-9]",v)):
                sys.exit("%s: %s must have at least 8 characters with upper, lower, digit and special character (Keycloak policy)"%(path,k))
        if k=="encryption-key":
            try: ok=len(base64.b64decode(v,validate=True))==32
            except Exception: ok=False
            if not ok: sys.exit("%s: encryption-key must be base64 of exactly 32 bytes (openssl rand -base64 32)"%path)
        d[k]=v; over.append(k)
    if over: sys.stderr.write("  overrides from %s: %s\n"%(path,", ".join(over)))
print(json.dumps(d))
PY
) || die "could not prepare the secrets (see the message above)"
  vexec "vault kv put -mount=secret tokenfactory - <<'__JSON__'
$json
__JSON__
echo stored" | grep -q stored || die "could not write secret/tokenfactory to Vault"
  json=""
  local g; g(){ openssl rand -hex 32; }
  umask 077; { for k in ACCOUNTS LEDGER CONTROL RELAY WARDEN; do echo "SERVICE_KEY_TF_$k=$(g)"; done; } > "$KEYFILE"
  echo "  30 keys written to Vault secret/tokenfactory. Service keys saved to $KEYFILE (0600) - BACK IT UP, every upgrade needs the same values."
  echo "  The Secret tokenfactory-secrets appears in $NAMESPACE when the app is installed (the chart's vault-secret-syncer mounts it through the CSI driver)."
}

phase_pg(){
  log "Postgres HA (Zalando) - mode: $PG_OPERATOR_MODE"
  if [ "$PG_OPERATOR_MODE" = install ]; then
    helm upgrade --install postgres-operator "$ZC/postgres-operator" -n postgres --set registry="$REGISTRY" --wait --timeout 5m
    [ $DRY = 1 ] || wait_for "postgres-operator Available" 180 kubectl -n postgres rollout status deploy/postgres-operator --timeout=10s
    [ $DRY = 1 ] || wait_for "CRD postgresqls.acid.zalan.do" 120 kubectl get crd postgresqls.acid.zalan.do
  fi
  local INST="$INST_DEF"
  helm upgrade --install pgdb "$ZC/pgdb" -n "$NAMESPACE" "${PG_SET[@]}"
  [ $DRY = 1 ] && return 0
  wait_for "pgdb status Running" 900 bash -c "[ \"\$(kubectl -n $NAMESPACE get postgresql pgdb -o jsonpath='{.status.PostgresClusterStatus}')\" = Running ]"
  wait_for "$INST pgdb pods Ready" 600 bash -c "[ \"\$(kubectl -n $NAMESPACE get pods -l cluster-name=pgdb,application=spilo --no-headers | grep -c ' 2/2\\| 1/1')\" -ge $INST ]"
  wait_for "5 role secrets" 300 bash -c "[ \"\$(kubectl -n $NAMESPACE get secret --no-headers | grep -c 'pgdb.credentials.postgresql.acid.zalan.do')\" -ge 5 ]"
  kubectl -n "$NAMESPACE" exec pgdb-0 -c postgres -- patronictl list || true
}

phase_secrets(){
  if [ "$SECRETS_BACKEND" = vault ]; then secrets_vault; return; fi
  log "tokenfactory-secrets + service keys"
  if kubectl -n "$NAMESPACE" get secret tokenfactory-secrets >/dev/null 2>&1; then
    [ -f "$KEYFILE" ] || die "tokenfactory-secrets exists but $KEYFILE is missing (service keys must stay stable) - restore it from backup"
    echo "  exists - keeping (service keys: $KEYFILE)"; return 0; fi
  [ ! -e "$KEYFILE" ] || die "$KEYFILE exists but no tokenfactory-secrets in the cluster - remove the stale file or restore the Secret"
  local g pw JWT; g(){ openssl rand -hex 32; }; pw(){ printf 'Aa1!%s' "$(openssl rand -hex 12)"; }; JWT=$(g)
  kubectl -n "$NAMESPACE" create secret generic tokenfactory-secrets \
    --from-literal=db-password="$(g)" --from-literal=jwt-secret="$JWT" --from-literal=portal-jwt-secret="$JWT" \
    --from-literal=admin-api-key="$(g)" --from-literal=encryption-key="$(openssl rand -base64 32)" \
    --from-literal=ce-userinfo-signing-key="$(g)" --from-literal=auth-state-signing-key="$(g)" \
    --from-literal=kc-admin-username=admin --from-literal=kc-admin-password="$(pw)" \
    --from-literal=kc-db-username=keycloak --from-literal=kc-db-password="$(g)" --from-literal=openfga-db-password="$(g)" \
    --from-literal=s3-access-key="$(openssl rand -hex 10)" --from-literal=s3-secret-key="$(g)" \
    --from-literal=stripe-webhook-secret='' --from-literal=stripe-secret-key='' \
    --from-literal=smtp-password="${SMTP_PASSWORD:-}" \
    --from-literal=platform-admin-password="$(pw)" --from-literal=platform-init-admin-password="$(pw)" >/dev/null
  umask 077; { for k in ACCOUNTS LEDGER CONTROL RELAY WARDEN; do echo "SERVICE_KEY_TF_$k=$(g)"; done; } > "$KEYFILE"
  echo "  created. Service keys saved to $KEYFILE (0600) - BACK IT UP, every upgrade needs the same values."
}

phase_controllers(){
  log "Gateway API CRDs + Envoy Gateway v1.8.1 + Envoy AI Gateway v1.0.0"
  kc apply --server-side -f "$BUNDLE_DIR/crds/gateway-api-standard-install-v1.3.0.yaml" >/dev/null
  helm upgrade --install eg "$C/gateway-helm-v1.8.1.tgz" -n envoy-gateway-system \
    -f "$REPO/helm/setup/scripts/envoygateway-config.yaml" -f "$OUT/envoy-gateway.yaml" \
    --set config.envoyGateway.provider.kubernetes.deploy.type=GatewayNamespace --wait --timeout 10m
  helm upgrade --install aieg-crds "$C/ai-gateway-crds-helm-v1.0.0.tgz" -n envoy-ai-gateway-system --wait --timeout 5m
  helm upgrade --install aieg "$C/ai-gateway-helm-v1.0.0.tgz" -n envoy-ai-gateway-system -f "$OUT/ai-gateway.yaml" --wait --timeout 10m
}

phase_ingress(){
  if [ "$INGRESS_CONTROLLER" = existing ]; then
    log "Ingress controller: using the cluster's existing one (class $INGRESS_CLASS) - nothing installed"
    if [ $DRY = 0 ]; then kubectl get ingressclass "$INGRESS_CLASS"; echo "  controller Services:"; kubectl get svc -A 2>/dev/null | grep -i ingress | grep -v admission | sed 's/^/    /' || true; fi
    return 0
  fi
  log "F5 NGINX Ingress Controller 3.6.2"
  helm upgrade --install nginx-ingress "$C/nginx-ingress-1.3.2.tgz" -n nginx-ingress -f "$OUT/nginx-ingress.yaml" -f "$OUT/lb-nginx.yaml" --wait --timeout 10m
  [ $DRY = 1 ] || kubectl get ingressclass nginx
}

phase_openmeter(){
  log "OpenMeter (Kafka, ClickHouse, Redis, Svix; Postgres = pgdb)"
  local CH="$REPO/helm/infrastructure/openmeter"; ls "$CH"/charts/openmeter-*.tgz >/dev/null 2>&1 || die "OpenMeter chart not vendored - run the bundle step on the connected host"
  local OMPW SVPW
  if [ $DRY = 1 ]; then OMPW=dry; SVPW=dry; else
    OMPW=$(kubectl -n "$NAMESPACE" get secret openmeter.pgdb.credentials.postgresql.acid.zalan.do -o jsonpath='{.data.password}' | base64 -d)
    SVPW=$(kubectl -n "$NAMESPACE" get secret svix.pgdb.credentials.postgresql.acid.zalan.do -o jsonpath='{.data.password}' | base64 -d)
    kubectl -n openmeter get secret om-clickhouse-pw >/dev/null 2>&1 || kubectl -n openmeter create secret generic om-clickhouse-pw --from-literal=password="$(openssl rand -hex 24)" >/dev/null
  fi
  local H="pgdb.${NAMESPACE}.svc.cluster.local:5432"
  helm upgrade --install openmeter "$CH" -n openmeter -f "$OUT/openmeter.yaml" \
    --set openmeter.networkPolicy.appNamespace="$NAMESPACE" \
    --set openmeter.clickhouseCredentials.existingSecretName=om-clickhouse-pw \
    --set "openmeter.config.postgres.url=postgres://openmeter:${OMPW}@${H}/openmeter?sslmode=require" \
    --set "openmeter.svix.database.dsn=postgres://svix:${SVPW}@${H}/svix?sslmode=require" \
    --post-renderer "$CH/postrender/postrender.sh" --wait --timeout 60m
}

# the five service-identity keys go in a 0600 values file (never on a command line: install.sh prints the helm command into the log)
write_service_keys(){ mkdir -p "$OUT"; ( umask 077; cat > "$OUT/service-keys.yaml" <<YAML
global:
  secrets:
    serviceKeyTfAccounts: "$1"
    serviceKeyTfLedger: "$2"
    serviceKeyTfControl: "$3"
    serviceKeyTfRelay: "$4"
    serviceKeyTfWarden: "$5"
YAML
); }

phase_app(){
  log "TokenFactory umbrella (install.sh = what `make install-app` runs)"
  [ -f "$KEYFILE" ] || die "$KEYFILE missing (run phase secrets)"
  . "$KEYFILE"
  write_service_keys "$SERVICE_KEY_TF_ACCOUNTS" "$SERVICE_KEY_TF_LEDGER" "$SERVICE_KEY_TF_CONTROL" "$SERVICE_KEY_TF_RELAY" "$SERVICE_KEY_TF_WARDEN"
  # Own pre-install checks instead of preflight.sh: its OpenMeter probe pod runs in the `openmeter` namespace, and OpenMeter's NetworkPolicy
  # (openmeter-api-restrict, enforced by Cilium) admits ONLY tf-ledger, so that probe can never succeed on a policy-enforcing cluster.
  for crd in gateways.gateway.networking.k8s.io aigatewayroutes.aigateway.envoyproxy.io envoyproxies.gateway.envoyproxy.io; do kubectl get crd "$crd" >/dev/null 2>&1 || die "CRD $crd missing - run phase controllers"; done
  [ "$(kubectl -n openmeter get deploy openmeter-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null || die "OpenMeter API is not ready - run phase openmeter"
  if [ "$SECRETS_BACKEND" = vault ]; then kubectl -n "$NAMESPACE" get secret tf-etisalat-ingress-tls >/dev/null 2>&1 || kubectl -n "$NAMESPACE" get secret "$INGRESS_TLS_SECRET" >/dev/null || die "TLS Secret $INGRESS_TLS_SECRET missing in $NAMESPACE"; kubectl -n "$NAMESPACE" get sa tf-vault-sync >/dev/null || die "ServiceAccount tf-vault-sync missing in $NAMESPACE (run phase secrets)"
  else kubectl -n "$NAMESPACE" get secret tokenfactory-secrets >/dev/null || die "tokenfactory-secrets missing in $NAMESPACE"; fi
  if [ "$BEHIND_CLOUDFLARE" != yes ]; then kubectl -n "$NAMESPACE" get secret tf-etisalat-tls >/dev/null || die "tf-etisalat-tls missing in $NAMESPACE"; fi
  echo "  pre-install checks ok (CRDs, OpenMeter API, secrets)"
  SKIP_PREFLIGHT=1 CHART_DIR="$REPO/helm/tokenfactory" RELEASE=tokenfactory NAMESPACE="$NAMESPACE" VALUES="$REPO/helm/tokenfactory/values-tf-etisalat.yaml" \
    HELM_ARGS="-f $OUT/umbrella.yaml -f $OUT/services.yaml -f $OUT/vaultsync.yaml -f $OUT/integrations.yaml -f $OUT/lb-umbrella.yaml -f $OUT/lb-envoyip.yaml -f $OUT/edge.yaml -f $OUT/tlsmode.yaml -f $OUT/custom.yaml -f $OUT/service-keys.yaml --timeout 30m" \
    "$REPO/helm/setup/scripts/install.sh"
}

phase_verify(){
  log "verify"
  local fail=0
  kubectl -n "$NAMESPACE" get postgresql pgdb
  echo "-- pods not Ready:"; kubectl get pods -A --no-headers | grep -vE 'Running|Completed' | grep -E "$NAMESPACE|openmeter|envoy|nginx-ingress|postgres" || echo "  none"
  echo "-- images NOT from $REGISTRY (expect none):"
  kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' | sort -u | grep -vE "^$REGISTRY/|^registry.k8s.io/pause|^$" | grep -vE "kube-|calico|flannel|cilium|coredns|etcd|csi|metrics-server" || echo "  none"
  if [ "$SECRETS_BACKEND" = vault ]; then echo "-- vault: $(vstatus)"; kubectl -n "$NAMESPACE" get secret tokenfactory-secrets >/dev/null 2>&1 && echo "   Secret tokenfactory-secrets synced from Vault: $(kubectl -n "$NAMESPACE" get secret tokenfactory-secrets -o json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))') keys" || echo "   WARNING: Secret tokenfactory-secrets not present yet (kubectl -n $NAMESPACE get pods -l app=vault-secret-syncer)"; fi
  echo "-- keycloak HA:"; kubectl -n "$NAMESPACE" get sts keycloak; kubectl -n "$NAMESPACE" get pdb | grep -i keycloak || true
  echo "-- ingress:"; kubectl -n "$NAMESPACE" get ingress tokenfactory
  local ING_SVC ING_IP
  if [ "$INGRESS_CONTROLLER" = existing ]; then
    ING_SVC=$(kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}.{.items[0].metadata.namespace}.svc.cluster.local' 2>/dev/null || true)
    ING_IP=$(kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$ING_SVC" ] || ING_SVC="<the ingress controller Service: kubectl get svc -A | grep -i ingress>"
  else
    ING_SVC="nginx-ingress-controller.nginx-ingress.svc.cluster.local"; ING_IP=$(kubectl -n nginx-ingress get svc nginx-ingress-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
  if [ "$EXPOSE" = clusterip ]; then
    echo "-- Cloudflare tunnel targets (ClusterIP Services; map the public hostnames to these):"
    echo "   portal./admin./www./auth.${DOMAIN}  ->  http://${ING_SVC}:80   (the Ingress routes by host name${ING_IP:+; same controller is on $ING_IP})"
    echo "   api.${DOMAIN}                        ->  http://$(kubectl -n "$NAMESPACE" get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null).${NAMESPACE}.svc.cluster.local:8080"
  else
    echo "-- LB addresses (create DNS):"
    echo "   api.${DOMAIN}                      -> $(kubectl -n "$NAMESPACE" get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    echo "   portal./admin./www./auth.${DOMAIN} -> ${ING_IP}"
  fi
  echo "-- admin login: kubectl -n $NAMESPACE get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d"
}

phase_dryrun(){
  DRY=1; export DRY
  phase_check; phase_prepare; phase_render
  log "dry-run: helm template of every release"
  T(){ helm template "$@" >/dev/null && echo "  ok: $1"; }
  T postgres-operator "$ZC/postgres-operator" -n postgres --set registry="$REGISTRY"
  T pgdb "$ZC/pgdb" -n "$NAMESPACE" "${PG_SET[@]}"
  T eg "$C/gateway-helm-v1.8.1.tgz" -n envoy-gateway-system -f "$REPO/helm/setup/scripts/envoygateway-config.yaml" -f "$OUT/envoy-gateway.yaml" --set config.envoyGateway.provider.kubernetes.deploy.type=GatewayNamespace
  T aieg "$C/ai-gateway-helm-v1.0.0.tgz" -n envoy-ai-gateway-system -f "$OUT/ai-gateway.yaml"
  T nginx-ingress "$C/nginx-ingress-1.3.2.tgz" -n nginx-ingress -f "$OUT/nginx-ingress.yaml" -f "$OUT/lb-nginx.yaml"
  T openmeter "$REPO/helm/infrastructure/openmeter" -n openmeter -f "$OUT/openmeter.yaml" --set openmeter.clickhouseCredentials.existingSecretName=om-clickhouse-pw --set openmeter.config.postgres.url=x --set openmeter.svix.database.dsn=x
  write_service_keys dryrun dryrun dryrun dryrun dryrun
  [ "$SECRETS_BACKEND" = vault ] && { T csi-secrets-store "$C/secrets-store-csi-driver-1.5.6.tgz" -n kube-system -f "$OUT/secrets-store-csi.yaml"; T vault "$C/vault-0.32.0.tgz" -n "$VAULT_NAMESPACE" -f "$OUT/vault.yaml"; }
  [ "$STORAGE_BACKEND" = hpe-x10000 ] && { T hpe-csi "$C/hpe-csi-driver-3.2.0.tgz" -n hpe-storage -f "$OUT/hpe-csi.yaml"; grep -q "provisioner: csi.hpe.com" "$OUT/storageclass-hpe-x10000.yaml" && grep -q "vers=4.1" "$OUT/storageclass-hpe-x10000.yaml" && echo "  ok: StorageClass manifest"; }
  T tokenfactory "$REPO/helm/tokenfactory" -n "$NAMESPACE" -f "$REPO/helm/tokenfactory/values-tf-etisalat.yaml" -f "$OUT/umbrella.yaml" -f "$OUT/services.yaml" -f "$OUT/vaultsync.yaml" -f "$OUT/integrations.yaml" -f "$OUT/lb-umbrella.yaml" -f "$OUT/lb-envoyip.yaml" -f "$OUT/edge.yaml" -f "$OUT/tlsmode.yaml" -f "$OUT/custom.yaml" -f "$OUT/service-keys.yaml" \
    --set-file keycloak.theme.archive="$REPO/brands/etisalat/keycloak/theme.tar.gz.b64"
  log "dry-run PASSED - safe to run: ./deploy-all.sh all"
}

[ $# -ge 1 ] || { sed -n 2,8p "$0"; exit 1; }
case "$1" in
  dry-run) phase_dryrun; exit 0;;
  all) run=("${PHASES[@]}");;
  --from) [ -n "${2:-}" ] || die "--from <phase>"; run=(); on=0; for p in "${PHASES[@]}"; do [ "$p" = "$2" ] && on=1; [ $on = 1 ] && run+=("$p"); done; [ ${#run[@]} -gt 0 ] || die "unknown phase $2";;
  *) run=("$@");;
esac
for p in "${run[@]}"; do
  case " ${ALLPH[*]} " in *" $p "*) ;; *) die "unknown phase: $p";; esac
  "phase_$p"
done
log "done: ${run[*]}"
