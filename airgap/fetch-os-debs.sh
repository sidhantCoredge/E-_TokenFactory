#!/usr/bin/env bash
# Run on the CONNECTED Mac/Linux (internet + a running Docker). Downloads the few OS packages the air-gapped INSTALL VM may be missing
# (perl, python3, openssl, rsync, ...) as Ubuntu .deb files, ONE FOLDER PER PACKAGE with its dependencies, into bundle/os-debs/:
#       bundle/os-debs/python3/*.deb   bundle/os-debs/perl/*.deb   ...
# On the VM you install only the folder(s) of the tools that `command -v` reports MISSING (DEPLOY.md B2a): sudo dpkg -i ~/os-debs/<package>/*.deb
#   airgap/fetch-os-debs.sh                       Ubuntu 24.04, amd64
#   UBUNTU_VERSION=22.04 airgap/fetch-os-debs.sh  the release must be the SAME as the VM's (check there: grep VERSION_ID /etc/os-release)
#   OS_PKGS="perl python3" airgap/fetch-os-debs.sh   other package list
# Always linux/amd64 (the Etisalat VMs), also on an Apple-silicon Mac (Docker emulates it).
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
UB="${UBUNTU_VERSION:-24.04}"; PKGS="${OS_PKGS:-perl python3 openssl tar gawk openssh-client rsync}"
OUT="$BUNDLE_DIR/os-debs"
command -v docker >/dev/null || { echo "docker not found (install Docker Desktop and start it)"; exit 1; }
docker info >/dev/null 2>&1 || { echo "the Docker daemon is not running: start Docker Desktop and run this again"; exit 1; }
mkdir -p "$OUT"; rm -rf "$OUT"/*
echo "== downloading for Ubuntu $UB amd64: $PKGS"
docker run --rm --platform linux/amd64 -v "$OUT:/out" "ubuntu:$UB" bash -c '
  set -e; export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  for p in '"$PKGS"'; do
    rm -f /var/cache/apt/archives/*.deb
    apt-get install -y -qq --download-only --reinstall "$p" >/dev/null
    mkdir -p "/out/$p"; cp /var/cache/apt/archives/*.deb "/out/$p/"
    echo "  $p: $(ls /out/$p/*.deb | wc -l) files"
  done'
# helper that travels with the debs: dpkg needs the files of one package in dependency order, a glob is alphabetical, so repeat the install until it sticks
cat > "$OUT/install.sh" <<'EOS'
#!/usr/bin/env bash
# usage (on the VM):  sudo ~/os-debs/install.sh python3 perl openssl rsync      (only the packages that `command -v` reported MISSING; no argument = every package folder)
set -u; D="$(cd "$(dirname "$0")" && pwd)"; [ "$(id -u)" = 0 ] || { echo "run it with sudo"; exit 1; }
PK="${*:-$(cd "$D" && ls -d */ | tr -d /)}"; rc=0
for p in $PK; do [ -d "$D/$p" ] || { echo "no folder $D/$p"; rc=1; continue; }
  for i in 1 2 3; do dpkg -i "$D/$p"/*.deb >/dev/null 2>&1 && break; done
  dpkg --configure -a >/dev/null 2>&1
  if dpkg -s "$p" 2>/dev/null | grep -q '^Status: install ok installed'; then echo "installed $p"; else echo "FAILED $p (run: dpkg -i $D/$p/*.deb  and read the error)"; rc=1; fi
done; exit $rc
EOS
chmod +x "$OUT/install.sh"
echo "== done: $(du -sh "$OUT" | cut -f1) in $OUT"
echo "Copy the folder to the install VM (it may have no rsync yet):  scp -r $OUT <vm-user>@<VM-IP>:~/os-debs"
