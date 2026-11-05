#!/usr/bin/env bash
# ONLY if the air-gap has no container registry: start one from the bundle (needs docker or podman on THIS host).
# Afterwards set REGISTRY=<this-host-ip>:5000 in config.env, DEST_TLS_VERIFY=false, and make every cluster node trust it
# (containerd: /etc/containerd/certs.d/<ip>:5000/hosts.toml  ->  server = "http://<ip>:5000" ; capabilities pull,resolve ; skip_verify).
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
CT=$(command -v docker || command -v podman) || { echo "need docker or podman"; exit 1; }
$CT load -i "$BUNDLE_DIR/registry/registry2.tar"
$CT rm -f etisalat-registry >/dev/null 2>&1 || true
$CT run -d --restart=always --name etisalat-registry -p 5000:5000 -v etisalat-registry-data:/var/lib/registry registry:2
sleep 2; curl -sf http://localhost:5000/v2/ >/dev/null && echo "registry up on :5000 (data volume: etisalat-registry-data)"
