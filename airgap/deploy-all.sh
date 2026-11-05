#!/usr/bin/env bash
# One-command, resumable, idempotent deploy of the Etisalat air-gapped stack.
#   ./deploy-all.sh check            preflight only (read-only)
#   ./deploy-all.sh dry-run          render EVERY chart offline with helm template (no cluster needed) - run this first
#   ./deploy-all.sh all              push -> check -> prepare -> ns -> pg -> secrets -> controllers -> ingress -> openmeter -> app -> verify
#   ./deploy-all.sh <phase> [...]    run specific phases;   ./deploy-all.sh --from <phase>   resume from a phase
# Phases: push check prepare render ns pg secrets controllers ingress openmeter app verify
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
PHASES=(push check prepare render ns pg secrets controllers ingress openmeter app verify)
OUT="$ROOT/rendered"; KEYFILE="${KEYFILE:-$HOME/.etisalat-service-keys.env}"
C="$BUNDLE_DIR/charts"; ZC="$ROOT/zalando/charts"
log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
wait_for(){ # desc timeout_s cmd...
  local d="$1" t="$2"; shift 2; local s=$SECONDS
  until "$@" >/dev/null 2>&1; do [ $((SECONDS-s)) -gt "$t" ] && die "timeout (${t}s) waiting for: $d"; sleep 5; done; echo "  ok: $d"; }
VARS='${REGISTRY} ${TF_TAG} ${BRAND_TAG} ${DOMAIN} ${SUPPORT_EMAIL} ${STORAGE_CLASS} ${PLATFORM_ADMIN_EMAIL} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_USER} ${KEYCLOAK_JAR_URL}'
DRY=0
kc(){ if [ $DRY = 1 ]; then echo "  [dry-run] kubectl $*"; else kubectl "$@"; fi; }

phase_check(){
  log "check"
  for t in kubectl helm envsubst openssl perl python3 make; do need $t; done; [ $DRY = 1 ] || need skopeo
  local bad; bad=$(grep -nE 'REPLACE_' "$ROOT/config.env" | grep -v '^[0-9]*:\s*#' || true)
  [ -z "$bad" ] || die "config.env still has REPLACE_ values:\n$bad"
  for v in REGISTRY NAMESPACE DOMAIN TF_TAG BRAND_TAG STORAGE_CLASS SMTP_HOST SMTP_PORT SMTP_USER KEYCLOAK_JAR_URL TLS_CERT TLS_KEY CH_DATA_SIZE CH_LOG_SIZE; do [ -n "${!v:-}" ] || die "config.env: $v is empty"; done
  case "$REGISTRY" in *://*) die "REGISTRY must be host[:port] without scheme";; esac
  [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ] || die "TLS_CERT / TLS_KEY files not found"
  openssl x509 -in "$TLS_CERT" -noout -checkend 0 >/dev/null || die "TLS certificate is expired"
  [ -d "$REPO/helm/tokenfactory" ] || die "repo not found at $REPO (unpack bundle/repo/ai-gateway-platform.tgz next to config.env)"
  for f in charts/gateway-helm-v1.8.1.tgz charts/ai-gateway-crds-helm-v1.0.0.tgz charts/ai-gateway-helm-v1.0.0.tgz charts/nginx-ingress-1.3.2.tgz crds/gateway-api-standard-install-v1.3.0.yaml; do [ -f "$BUNDLE_DIR/$f" ] || die "bundle file missing: $f"; done
  if [ $DRY = 0 ]; then
    kubectl version --request-timeout=10s >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
    local n; n=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true); echo "  ready nodes: $n"; [ "$n" -ge 3 ] || die "need >=3 Ready nodes (pgdb has 3 instances with anti-affinity)"
    kubectl get sc "$STORAGE_CLASS" >/dev/null 2>&1 || die "StorageClass '$STORAGE_CLASS' not found"
    [ "$(kubectl get sc "$STORAGE_CLASS" -o jsonpath='{.allowVolumeExpansion}')" = "true" ] || echo "  WARNING: StorageClass $STORAGE_CLASS has allowVolumeExpansion!=true (Redis/Postgres cannot be grown later)"
    if [ "$PG_OPERATOR_MODE" = existing ]; then kubectl get crd postgresqls.acid.zalan.do >/dev/null 2>&1 || die "PG_OPERATOR_MODE=existing but no postgresqls.acid.zalan.do CRD"; fi
    echo "  checking images in $REGISTRY ..."
    local miss=0
    while IFS='|' read -r src dst mode; do
      dst=$(echo $dst); ref="$REGISTRY/$dst"; case "$dst" in *@sha256:*) ;; *) ;; esac
      skopeo inspect --tls-verify="${DEST_TLS_VERIFY}" ${REGISTRY_USER:+--creds "$REGISTRY_USER:$REGISTRY_PASS"} --raw "docker://$ref" >/dev/null 2>&1 || { case "$dst" in *@sha256:*) ;; *) echo "  MISSING $ref"; miss=1;; esac; }
    done < <(grep -vE '^\s*(#|$)' "$ROOT/airgap/images.txt" | envsubst '${TF_TAG} ${BRAND_TAG}')
    [ $miss = 0 ] || die "images missing in the registry - run: airgap/deploy-all.sh push"
  fi
  echo "  check passed"
}

phase_push(){ log "push images -> $REGISTRY"; ./02-push-registry.sh; }

phase_prepare(){
  log "prepare (patch hardcoded images, ingress template, vendor subcharts)"
  REPO="$REPO" REGISTRY="$REGISTRY" STORAGE_CLASS="$STORAGE_CLASS" CH_DATA_SIZE="$CH_DATA_SIZE" CH_LOG_SIZE="$CH_LOG_SIZE" ./03-patch-hardcoded-images.sh
  if [ -f "$REPO/helm/tokenfactory/templates/ingress.yaml" ]; then echo "  ingress template already present"
  elif [ -f "$ROOT/patches/0001-umbrella-ingress-template-pr678.patch" ]; then (cd "$REPO" && patch -p1 < "$ROOT/patches/0001-umbrella-ingress-template-pr678.patch") && echo "  ingress template applied (PR #678)"
  else die "helm/tokenfactory/templates/ingress.yaml is missing in $REPO. Use a checkout that contains PR #678 (Ingress template + values.yaml 'ingress:' block), or place the patch in $ROOT/patches/"; fi
  (cd "$REPO/helm/tokenfactory" && helm dependency build >/dev/null) && echo "  umbrella subcharts vendored (file:// only)"
}

phase_render(){
  log "render values -> $OUT"
  umask 077; mkdir -p "$OUT"
  for n in umbrella openmeter nginx-ingress envoy-gateway ai-gateway; do
    envsubst "$VARS" < "$ROOT/values/$n.values.yaml.tmpl" > "$OUT/$n.yaml"
    ! grep -q '\${' "$OUT/$n.yaml" || die "unreplaced \${VAR} in $OUT/$n.yaml: $(grep -n '\${' "$OUT/$n.yaml" | head -2)"
  done; echo "  rendered 5 files (no secrets inside)"
}

phase_ns(){
  log "namespaces, pull secrets, TLS"
  for ns in postgres "$NAMESPACE" openmeter envoy-gateway-system envoy-ai-gateway-system nginx-ingress; do
    kubectl create ns "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kubectl -n "$ns" create secret docker-registry registry-pull --docker-server="$REGISTRY" \
      --docker-username="${REGISTRY_USER:-anonymous}" --docker-password="${REGISTRY_PASS:-anonymous}" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kubectl -n "$ns" patch sa default -p '{"imagePullSecrets":[{"name":"registry-pull"}]}' >/dev/null   # also covers ad-hoc pods (preflight probe, hooks)
    echo "  $ns: ready"
  done
  kubectl -n "$NAMESPACE" create secret tls tf-etisalat-tls --cert="$TLS_CERT" --key="$TLS_KEY" --dry-run=client -o yaml | kc apply -f - >/dev/null
  echo "  tf-etisalat-tls: applied"
}

phase_pg(){
  log "Postgres HA (Zalando) - mode: $PG_OPERATOR_MODE"
  if [ "$PG_OPERATOR_MODE" = install ]; then
    helm upgrade --install postgres-operator "$ZC/postgres-operator" -n postgres --set registry="$REGISTRY" --wait --timeout 5m
    [ $DRY = 1 ] || wait_for "postgres-operator Available" 180 kubectl -n postgres rollout status deploy/postgres-operator --timeout=10s
    [ $DRY = 1 ] || wait_for "CRD postgresqls.acid.zalan.do" 120 kubectl get crd postgresqls.acid.zalan.do
  fi
  helm upgrade --install pgdb "$ZC/pgdb" -n "$NAMESPACE" --set registry="$REGISTRY" --set volume.storageClass="$STORAGE_CLASS"
  [ $DRY = 1 ] && return 0
  wait_for "pgdb status Running" 900 bash -c "[ \"\$(kubectl -n $NAMESPACE get postgresql pgdb -o jsonpath='{.status.PostgresClusterStatus}')\" = Running ]"
  wait_for "3 pgdb pods Ready" 600 bash -c "[ \"\$(kubectl -n $NAMESPACE get pods -l cluster-name=pgdb,application=spilo --no-headers | grep -c ' 2/2\\| 1/1')\" -ge 3 ]"
  wait_for "5 role secrets" 300 bash -c "[ \"\$(kubectl -n $NAMESPACE get secret --no-headers | grep -c 'pgdb.credentials.postgresql.acid.zalan.do')\" -ge 5 ]"
  kubectl -n "$NAMESPACE" exec pgdb-0 -c postgres -- patronictl list || true
}

phase_secrets(){
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
  log "F5 NGINX Ingress Controller 3.6.2"
  helm upgrade --install nginx-ingress "$C/nginx-ingress-1.3.2.tgz" -n nginx-ingress -f "$OUT/nginx-ingress.yaml" --wait --timeout 10m
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

phase_app(){
  log "TokenFactory umbrella (make install-app)"
  [ -f "$KEYFILE" ] || die "$KEYFILE missing (run phase secrets)"
  . "$KEYFILE"
  export OM_CHECK_IMAGE="$REGISTRY/busybox:1.36"        # preflight's one-shot OpenMeter probe pod
  make -C "$REPO/helm/setup" install-app NAMESPACE="$NAMESPACE" VALUES=helm/tokenfactory/values-tf-etisalat.yaml \
    HELM_ARGS="-f $OUT/umbrella.yaml --timeout 30m --set global.secrets.serviceKeyTfAccounts=$SERVICE_KEY_TF_ACCOUNTS --set global.secrets.serviceKeyTfLedger=$SERVICE_KEY_TF_LEDGER --set global.secrets.serviceKeyTfControl=$SERVICE_KEY_TF_CONTROL --set global.secrets.serviceKeyTfRelay=$SERVICE_KEY_TF_RELAY --set global.secrets.serviceKeyTfWarden=$SERVICE_KEY_TF_WARDEN"
}

phase_verify(){
  log "verify"
  local fail=0
  kubectl -n "$NAMESPACE" get postgresql pgdb
  echo "-- pods not Ready:"; kubectl get pods -A --no-headers | grep -vE 'Running|Completed' | grep -E "$NAMESPACE|openmeter|envoy|nginx-ingress|postgres" || echo "  none"
  echo "-- images NOT from $REGISTRY (expect none):"
  kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' | sort -u | grep -vE "^$REGISTRY/|^registry.k8s.io/pause|^$" | grep -vE "kube-|calico|flannel|cilium|coredns|etcd|csi|metrics-server" || echo "  none"
  echo "-- keycloak HA:"; kubectl -n "$NAMESPACE" get sts keycloak; kubectl -n "$NAMESPACE" get pdb | grep -i keycloak || true
  echo "-- ingress:"; kubectl -n "$NAMESPACE" get ingress tokenfactory
  echo "-- LB addresses (create DNS):"
  echo "   api.${DOMAIN}                      -> $(kubectl -n "$NAMESPACE" get svc -l gateway.envoyproxy.io/owning-gateway-name=envoy -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  echo "   portal./admin./www./auth.${DOMAIN} -> $(kubectl -n nginx-ingress get svc nginx-ingress-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  echo "-- admin login: kubectl -n $NAMESPACE get secret tokenfactory-secrets -o jsonpath='{.data.platform-admin-password}' | base64 -d"
}

phase_dryrun(){
  DRY=1; export DRY
  phase_check; phase_prepare; phase_render
  log "dry-run: helm template of every release"
  T(){ helm template "$@" >/dev/null && echo "  ok: $1"; }
  T postgres-operator "$ZC/postgres-operator" -n postgres --set registry="$REGISTRY"
  T pgdb "$ZC/pgdb" -n "$NAMESPACE" --set registry="$REGISTRY" --set volume.storageClass="$STORAGE_CLASS"
  T eg "$C/gateway-helm-v1.8.1.tgz" -n envoy-gateway-system -f "$REPO/helm/setup/scripts/envoygateway-config.yaml" -f "$OUT/envoy-gateway.yaml" --set config.envoyGateway.provider.kubernetes.deploy.type=GatewayNamespace
  T aieg "$C/ai-gateway-helm-v1.0.0.tgz" -n envoy-ai-gateway-system -f "$OUT/ai-gateway.yaml"
  T nginx-ingress "$C/nginx-ingress-1.3.2.tgz" -n nginx-ingress -f "$OUT/nginx-ingress.yaml"
  T openmeter "$REPO/helm/infrastructure/openmeter" -n openmeter -f "$OUT/openmeter.yaml" --set openmeter.clickhouseCredentials.existingSecretName=om-clickhouse-pw --set openmeter.config.postgres.url=x --set openmeter.svix.database.dsn=x
  T tokenfactory "$REPO/helm/tokenfactory" -n "$NAMESPACE" -f "$REPO/helm/tokenfactory/values-tf-etisalat.yaml" -f "$OUT/umbrella.yaml" \
    --set global.secrets.serviceKeyTfAccounts=x --set global.secrets.serviceKeyTfLedger=x --set global.secrets.serviceKeyTfControl=x --set global.secrets.serviceKeyTfRelay=x --set global.secrets.serviceKeyTfWarden=x \
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
  case " ${PHASES[*]} " in *" $p "*) ;; *) die "unknown phase: $p";; esac
  [ "$p" = push ] && [ "$1" = all ] && [ "${PUSH_IMAGES:-yes}" = no ] && continue
  "phase_$p"
done
log "done: ${run[*]}"
