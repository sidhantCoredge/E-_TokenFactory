#!/usr/bin/env bash
# MinIO removed its public images (Docker Hub / quay.io answer "access denied"), so this one tar must come from a registry
# that still holds it. Run on a host that can reach it (the install VM reaches ACR `acrtokenfactory`, which has the image).
# Needs: az (logged in), python3. Writes bundle/tars/minio_minio_RELEASE.2025-09-07T16-13-09Z.tar (OCI archive, amd64).
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
ACR="${MINIO_ACR:-acrtokenfactory}"; REPOSITORY="minio/minio"; TAG="RELEASE.2025-09-07T16-13-09Z"
OUT="$BUNDLE_DIR/tars/minio_minio_$TAG.tar"; REFNAME="$REGISTRY/$REPOSITORY:$TAG"
mkdir -p "$BUNDLE_DIR/tars"
RT="$(az acr login -n "$ACR" --expose-token --query accessToken -o tsv)"
ACR="$ACR" REPOSITORY="$REPOSITORY" TAG="$TAG" OUT="$OUT" REFNAME="$REFNAME" RT="$RT" python3 - <<'PY'
import os,json,urllib.request,urllib.parse,urllib.error,tarfile,hashlib,tempfile,io
acr,repo,tag,out,ref,rt=[os.environ[k] for k in("ACR","REPOSITORY","TAG","OUT","REFNAME","RT")]
host=f"https://{acr}.azurecr.io"
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*a,**k): return None
op=urllib.request.build_opener(NoRedirect)
def tok():
    d=urllib.parse.urlencode({"grant_type":"refresh_token","service":f"{acr}.azurecr.io","scope":f"repository:{repo}:pull","refresh_token":rt}).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(host+"/oauth2/token",d)))["access_token"]
T=tok()
ACC="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
def get(path,accept=None,auth=True):
    h={"Authorization":"Bearer "+T}
    if accept: h["Accept"]=accept
    try: r=op.open(urllib.request.Request(host+path,headers=h)); return r.read(),r.headers.get("Content-Type","")
    except urllib.error.HTTPError as e:
        if e.code in(301,302,307):   # blob lives on the registry data endpoint: pre-signed URL, must NOT get our Authorization header
            r=urllib.request.urlopen(e.headers["Location"]); return r.read(),""
        raise
def manifest(ref_):
    b,ct=get(f"/v2/{repo}/manifests/{ref_}",ACC); return b,json.loads(b)
b,m=manifest(tag)
if "manifests" in m:
    pick=[x for x in m["manifests"] if x.get("platform",{}).get("os")=="linux" and x["platform"].get("architecture")=="amd64"][0]
    b,m=manifest(pick["digest"])
mdig="sha256:"+hashlib.sha256(b).hexdigest()
blobs={mdig:b}
for d in [m["config"]["digest"]]+[l["digest"] for l in m["layers"]]:
    blobs[d],_=get(f"/v2/{repo}/blobs/{d}"); print("  blob",d[:19],len(blobs[d]))
    assert "sha256:"+hashlib.sha256(blobs[d]).hexdigest()==d,"digest mismatch "+d
mt=m.get("mediaType","application/vnd.docker.distribution.manifest.v2+json")
idx={"schemaVersion":2,"manifests":[{"mediaType":mt,"digest":mdig,"size":len(b),"annotations":{"org.opencontainers.image.ref.name":ref,"io.containerd.image.name":ref}}]}
tmp=out+".part"
with tarfile.open(tmp,"w") as t:
    def add(name,data):
        ti=tarfile.TarInfo(name); ti.size=len(data); t.addfile(ti,io.BytesIO(data))
    add("oci-layout",b'{"imageLayoutVersion":"1.0.0"}'); add("index.json",json.dumps(idx).encode())
    for d,data in blobs.items(): add("blobs/sha256/"+d.split(":")[1],data)
os.replace(tmp,out); print("wrote",out,os.path.getsize(out),"bytes; ref",ref)
PY
