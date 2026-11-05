#!/usr/bin/env bash
# Loads every image TAR into the containerd of EVERY node (no registry involved).  Run where bundle/tars lives (the install VM).
#   NODE_LOAD_MODE=pod  : a privileged pod per node downloads the tars from a tiny HTTP server on this host and runs `ctr images import`
#   NODE_LOAD_MODE=ssh  : scp + ssh to each entry of NODES ("user@ip ...")
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
T="$BUNDLE_DIR/tars"; [ -s "$T/INDEX" ] || { echo "no $T/INDEX - bundle missing"; exit 1; }
REFS=$(cut -d'|' -f2 "$T/INDEX" | tr '\n' ' ')
FILES=$(cut -d'|' -f1 "$T/INDEX" | tr '\n' ' ')
# digest-pinned images: containerd needs the name@sha256 form too (pods reference @sha256)
PAIRS=$(awk -F'|' '{print $1"="$2}' "$T/INDEX" | tr '\n' ' ')
PINS=$(awk -F'|' '$3!=""{print $2"="$3}' "$T/INDEX" | tr '\n' ' ')
IMPORT_SCRIPT='
set -e
cd /tmp
for pr in $PAIRS; do f=${pr%%=*}; r=${pr#*=}
  if ctr -n k8s.io images ls -q | grep -qxF "$r"; then echo "present  $f"; continue; fi
  [ -n "$FETCH" ] && curl -sf "$FETCH/$f" -o "/tmp/$f"
  ctr -n k8s.io images import --all-platforms "/tmp/$f" >/dev/null && echo "imported $f"; rm -f "/tmp/$f"
done
for p in $PINS; do ref=${p%%=*}; dig=${p##*=}; base=${ref%:pinned-*}
  ctr -n k8s.io images tag --force "$ref" "$base@sha256:$dig" >/dev/null 2>&1 || true; done
miss=0; for r in $REFS; do ctr -n k8s.io images ls -q | grep -qxF "$r" || { echo "MISSING $r"; miss=1; }; done
[ $miss = 0 ] && echo "ALL $(echo $REFS | wc -w) IMAGES PRESENT" || exit 1'
case "${1:-$NODE_LOAD_MODE}" in
  pod)
    HOST_IP="${LOADER_HOST_IP:-$(hostname -I | awk '{print $1}')}"; PORT="$LOADER_HTTP_PORT"
    ( cd "$T" && exec python3 -m http.server "$PORT" ) >/tmp/etisalat-tars-http.log 2>&1 & HP=$!; trap 'kill $HP 2>/dev/null || true' EXIT; sleep 2
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
      echo "== node $node =="; pod="img-loader-$(echo "$node" | tr -c 'a-z0-9\n' '-' | cut -c1-40)"
      kubectl -n default delete pod "$pod" --ignore-not-found >/dev/null
      cat <<YAML | kubectl -n default apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $pod }
spec:
  restartPolicy: Never
  nodeName: $node
  hostPID: true
  tolerations: [ { operator: Exists } ]
  containers:
  - name: loader
    image: $LOADER_DEBUG_IMAGE
    securityContext: { privileged: true }
    env:
    - { name: FILES, value: "$FILES" }
    - { name: PAIRS, value: "$PAIRS" }
    - { name: REFS, value: "$REFS" }
    - { name: PINS, value: "$PINS" }
    - { name: FETCH, value: "http://$HOST_IP:$PORT" }
    - name: SCRIPT
      value: |
$(echo "$IMPORT_SCRIPT" | sed 's/^/        /')
    command: ["chroot","/host","/bin/bash","-c","eval \"\$SCRIPT\""]
    volumeMounts: [ { name: host, mountPath: /host } ]
  volumes: [ { name: host, hostPath: { path: / } } ]
YAML
      for i in $(seq 1 360); do ph=$(kubectl -n default get pod "$pod" -o jsonpath='{.status.phase}'); [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 5; done
      kubectl -n default logs "$pod" | tail -5; [ "$ph" = Succeeded ] || { echo "LOAD FAILED on $node"; exit 1; }
      kubectl -n default delete pod "$pod" >/dev/null
    done;;
  ssh)
    [ -n "$NODES" ] || { echo "set NODES in config.env"; exit 1; }
    for n in $NODES; do echo "== $n =="
      ssh "$n" 'mkdir -p /tmp/etisalat-tars' && scp -q $(for f in $FILES; do echo "$T/$f"; done) "$n:/tmp/etisalat-tars/"
      ssh "$n" "sudo env FILES='$FILES' PAIRS='$PAIRS' REFS='$REFS' PINS='$PINS' FETCH='' bash -c 'cd /tmp/etisalat-tars; $(echo "$IMPORT_SCRIPT" | sed "s#/tmp/\\\$f#/tmp/etisalat-tars/\\\$f#g")'"
    done;;
  *) echo "usage: load-images.sh [pod|ssh]"; exit 1;;
esac
echo "images loaded on all nodes"
