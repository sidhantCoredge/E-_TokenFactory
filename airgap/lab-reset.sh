#!/usr/bin/env bash
# LAB ONLY. Removes the WHOLE TokenFactory / Etisalat stack from the Azure lab cluster `aks-etisalat-test` (1 or more nodes), so the next deployment starts from zero.
#   airgap/lab-reset.sh --dry-run     print every command, change nothing
#   airgap/lab-reset.sh               asks you to type RESET-LAB, then resets the cluster and the jumphost's Etisalat files
#   airgap/lab-reset.sh -y            same without the question
#   airgap/lab-reset.sh --images      ALSO removes the cached image tars' images from the node (the next `images` phase re-imports all ~56 tars)
#   airgap/lab-reset.sh --no-files    keep the Etisalat files in the home directory (service keys, Vault init file, logs, lab certificate)
# SAFETY: it only talks to the kubeconfig ~/etisalat.kubeconfig (never to the default kubeconfig), refuses to run unless that cluster is the lab
# (1-5 nodes, all named aks-sys1-*, context aks-etisalat-test*), and removes only the objects of this stack. It touches kube-system only to uninstall the Helm release csi-secrets-store (installed by deploy-all.sh); never the AKS add-ons,
# other clusters, or any Xailon / production file on the jumphost.
set -uo pipefail
DRY=0; YES=0; IMAGES=0; FILES=1
for a in "$@"; do case "$a" in --dry-run) DRY=1;; -y) YES=1;; --images) IMAGES=1;; --no-files) FILES=0;; *) echo "unknown option $a"; sed -n 2,9p "$0"; exit 2;; esac; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$ROOT/bundle/tools" ] && [ "$(uname -s)" = Linux ] && export PATH="$ROOT/bundle/tools:$PATH"
KCFG="${KCFG:-$HOME/etisalat.kubeconfig}"
[ -f "$KCFG" ] || { echo "kubeconfig $KCFG not found (az aks get-credentials -g rg-tokenfactory -n aks-etisalat-test --admin --file ~/etisalat.kubeconfig)"; exit 1; }
K(){ kubectl --kubeconfig "$KCFG" "$@"; }
H(){ helm --kubeconfig "$KCFG" "$@"; }
say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
run(){ if [ $DRY = 1 ]; then echo "  [dry-run] $*"; else "$@" 2>&1 | sed 's/^/  /' || true; fi; }

NS="tokenfactory-etisalat tokenfactory openmeter nginx-ingress postgres envoy-ai-gateway-system envoy-gateway-system vault hpe-storage"
# API groups of the CRDs this stack installs (never: cilium, azure, snapshot.storage.k8s.io, ...)
CRD_RE='(envoyproxy\.io|gateway\.networking\.k8s\.io|gateway\.networking\.x-k8s\.io|k8s\.nginx\.org|externaldns\.nginx\.org|appprotect\.f5\.com|appprotectdos\.f5\.com|clickhouse\.altinity\.com|clickhouse-keeper\.altinity\.com|acid\.zalan\.do|secrets-store\.csi\.x-k8s\.io|storage\.hpe\.com|hpe\.com)$'
CR_RE='envoy|gateway|nginx-ingress|postgres-operator|openmeter|altinity|clickhouse|vault|secrets-store|tf-|tokenfactory|keycloak|hpe-|zalando'

say "Guard: is this the lab cluster?"
NODES=$(K get nodes -o name 2>/dev/null) || { echo "cannot reach the cluster with $KCFG"; exit 1; }
CTX=$(K config current-context 2>/dev/null || true)
echo "  context: $CTX"; echo "  nodes:   $(echo $NODES | tr '\n' ' ')"
[ -n "$NODES" ] && [ -z "$(echo "$NODES" | grep -v '^node/aks-sys1-')" ] && [ "$(echo "$NODES" | wc -l | tr -d ' ')" -le 5 ] && echo "$CTX" | grep -q 'aks-etisalat-test' \
  || { echo "ABORT: this is not the lab cluster (need 1-5 nodes, ALL named aks-sys1-*, and context aks-etisalat-test*). Nothing was changed."; exit 1; }
echo "  OK: aks-etisalat-test"
if [ $DRY = 0 ] && [ $YES = 0 ]; then
  echo; echo "This DELETES the whole TokenFactory/Etisalat lab stack (namespaces: $NS, their volumes, the CRDs and cluster roles of the stack)."
  read -r -p "Type RESET-LAB to continue: " ans; [ "$ans" = RESET-LAB ] || { echo "cancelled"; exit 1; }
fi

say "1/8 Helm releases of the stack"
H list -A --no-headers 2>/dev/null | awk -v ns=" $NS " 'index(ns," "$2" ")>0 {print $1" "$2}' | while read -r rel n; do
  echo "  uninstall $rel ($n)"; run helm --kubeconfig "$KCFG" -n "$n" uninstall "$rel" --timeout 5m; done
# the Secrets Store CSI driver is installed by deploy-all.sh into kube-system (not one of the stack namespaces): remove exactly that release, nothing else in kube-system
if H list -n kube-system --no-headers 2>/dev/null | awk '{print $1}' | grep -qx csi-secrets-store; then
  echo "  uninstall csi-secrets-store (kube-system)"; run helm --kubeconfig "$KCFG" -n kube-system uninstall csi-secrets-store --timeout 5m; fi

say "2/8 Custom resources that block namespace deletion (finalizers)"
for kind in postgresqls.acid.zalan.do clickhouseinstallations.clickhouse.altinity.com clickhousekeeperinstallations.clickhouse-keeper.altinity.com; do
  for r in $(K get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    echo "  $kind $r"; run kubectl --kubeconfig "$KCFG" -n "${r%%/*}" delete "$kind" "${r##*/}" --wait=false --ignore-not-found
    run kubectl --kubeconfig "$KCFG" -n "${r%%/*}" patch "$kind" "${r##*/}" --type=merge -p '{"metadata":{"finalizers":null}}'; done; done

# GatewayClass / Gateway objects have a finalizer that only the (already uninstalled) Envoy Gateway controller removes: clear it or the CRD deletion hangs
for r in $(K get gatewayclass -o name 2>/dev/null) $(K get gateways.gateway.networking.k8s.io -A -o name 2>/dev/null); do
  echo "  finalizers: $r"; run kubectl --kubeconfig "$KCFG" patch "$r" --type=merge -p '{"metadata":{"finalizers":null}}'; done

say "3/8 Namespaces of the stack (this also deletes their volumes)"
run kubectl --kubeconfig "$KCFG" delete ns $NS --ignore-not-found --wait=true --timeout=15m
for n in $NS; do K get ns "$n" >/dev/null 2>&1 && { echo "  $n still Terminating: removing its finalizers"; run kubectl --kubeconfig "$KCFG" patch ns "$n" --type=merge -p '{"spec":{"finalizers":null}}'; }; done

say "4/8 Leftovers in the default namespace"
for p in $(K -n default get pods -o name 2>/dev/null | grep -E 'nginx|img-loader|use-tag|use-digest|x10000-test' || true); do run kubectl --kubeconfig "$KCFG" -n default delete "$p" --ignore-not-found --wait=false; done

say "5/8 CRDs installed by the stack"
CRDS=$(K get crd -o name 2>/dev/null | sed 's|customresourcedefinition.apiextensions.k8s.io/||' | grep -E "$CRD_RE" || true)
echo "  $(echo "$CRDS" | grep -c .) CRDs"; [ -z "$CRDS" ] || run kubectl --kubeconfig "$KCFG" delete crd $CRDS --ignore-not-found --wait=true --timeout=5m

say "6/8 Cluster-scoped objects of the stack"
for kind in clusterrole clusterrolebinding mutatingwebhookconfiguration validatingwebhookconfiguration; do
  objs=$(K get "$kind" -o name 2>/dev/null | grep -i -E "$CR_RE" | grep -v -E 'system:|aks|azure|cilium|kube-' || true)
  [ -z "$objs" ] || { echo "  $kind: $(echo $objs | wc -w | tr -d ' ')"; run kubectl --kubeconfig "$KCFG" delete $objs --ignore-not-found; }; done
for o in ingressclass/nginx gatewayclass/tf-envoy csidriver/csi.hpe.com csidriver/secrets-store.csi.k8s.io storageclass/hpe-standard-file; do
  K get "$o" >/dev/null 2>&1 && { echo "  $o"; run kubectl --kubeconfig "$KCFG" delete "$o" --ignore-not-found; }; done

say "7/8 Volumes that are left (Released / Failed / Available)"
LEFT=$(K get pv --no-headers 2>/dev/null | awk '$5!="Bound"{print $1}' || true)
[ -z "$LEFT" ] && echo "  none" || { echo "  $(echo $LEFT | wc -w | tr -d ' ') leftover PVs"; run kubectl --kubeconfig "$KCFG" delete pv $LEFT --ignore-not-found --wait=false; }
BOUND=$(K get pv --no-headers 2>/dev/null | awk '$5=="Bound"{print $1" "$6}' || true); [ -z "$BOUND" ] || echo "  still Bound (not ours? check): $BOUND"

if [ $IMAGES = 1 ]; then
  say "7b Images cached on the node (prefix registry.etisalat.local/)"
  IMG="${LOADER_DEBUG_IMAGE:-mcr.microsoft.com/azurelinux/busybox:1.36}"
  for NODE in $(K get nodes -o jsonpath='{.items[*].metadata.name}'); do
  PODN="img-prune-${NODE##*-}"
  if [ $DRY = 1 ]; then echo "  [dry-run] privileged pod on $NODE ($IMG): ctr -n k8s.io images rm every registry.etisalat.local/* image"; else
    K -n default delete pod "$PODN" --ignore-not-found >/dev/null 2>&1
    cat <<YAML | K -n default apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $PODN }
spec:
  restartPolicy: Never
  nodeName: $NODE
  hostPID: true
  tolerations: [ { operator: Exists } ]
  containers:
  - name: p
    image: $IMG
    securityContext: { privileged: true }
    command: ["chroot","/host","/bin/bash","-c","ctr -n k8s.io images ls -q | grep '^registry.etisalat.local/' | xargs -r ctr -n k8s.io images rm >/dev/null; echo remaining: \$(ctr -n k8s.io images ls -q | grep -c '^registry.etisalat.local/')"]
    volumeMounts: [ { name: host, mountPath: /host } ]
  volumes: [ { name: host, hostPath: { path: / } } ]
YAML
    for i in $(seq 1 120); do ph=$(K -n default get pod "$PODN" -o jsonpath='{.status.phase}' 2>/dev/null); [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 5; done
    echo "  $NODE:"; K -n default logs "$PODN" 2>&1 | tail -2 | sed 's/^/    /'; K -n default delete pod "$PODN" >/dev/null 2>&1; fi
  done
fi

if [ $FILES = 1 ]; then
  say "8/8 Etisalat files in $HOME (only these; nothing else is touched)"
  for f in "$HOME/.etisalat-service-keys.env" "$HOME/.etisalat-vault-init.json" "$HOME/etisalat-deploy.log" "$HOME/etisalat-app2.log" "$HOME/wild.crt" "$HOME/wild.key"; do
    [ -e "$f" ] && { echo "  $f"; run rm -f "$f"; }; done
  echo "  (the package folder $ROOT is kept: the next rsync replaces it)"
fi

say "Result"
if [ $DRY = 1 ]; then echo "  dry-run: nothing was changed."; exit 0; fi
echo "  namespaces left:  $(K get ns --no-headers | awk '{print $1}' | grep -v -E '^(default|kube-node-lease|kube-public|kube-system)$' | tr '\n' ' ')"
echo "  helm releases:    $(H list -A --no-headers 2>/dev/null | awk '{print $1"/"$2}' | grep -v 'aks-managed' | tr '\n' ' ')"
echo "  stack CRDs:       $(K get crd -o name | sed 's|.*/||' | grep -c -E "$CRD_RE")"
echo "  persistent vols:  $(K get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
left=$(K get ns --no-headers | awk '{print $1}' | grep -v -E '^(default|kube-node-lease|kube-public|kube-system)$' | wc -l | tr -d ' ')
[ "$left" = 0 ] && [ "$(K get crd -o name | sed 's|.*/||' | grep -c -E "$CRD_RE")" = 0 ] && echo "  LAB CLEAN" || echo "  NOT clean: run the script again (Terminating namespaces can need a minute)"
