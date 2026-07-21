#!/usr/bin/env bash
# Offline-root ceremony for the platform intermediate CA (TEST clusters).
#
# Plays the role of the offline root: generates (or reuses) a root CA, pulls the
# operator-generated CSR from the platform-pki CR, signs it as a CA cert, and
# writes the signed cert (+ root chain) into the externalSignSecret the operator
# is waiting on. The operator then runs set-signed and the platform CA goes Active.
#
# Prereqs: the bootstrap is deployed with platformPki.mode=intermediate, and the
# operator has already created the CSR secret (platform-pki-intermediate-csr).
#
# Usage:  ./hack/sign-platform-ca.sh [kube-context]
set -euo pipefail

NS=mto-extension-openbao-system
CSR_SECRET=platform-pki-intermediate-csr      # operator writes the CSR here (key: csr)
CSR_KEY=csr
SIGNED_SECRET=platform-pki-signed             # operator reads the signed cert here (key: tls.crt)
SIGNED_KEY=tls.crt
WORKDIR=${WORKDIR:-./platform-ca-ceremony}    # where the offline root + artifacts live
CTX_ARG=""
[[ $# -ge 1 ]] && CTX_ARG="--context=$1"
OC="oc $CTX_ARG"

mkdir -p "$WORKDIR"; cd "$WORKDIR"

# 1) Offline root CA — generated once, then reused (keep root.key OFFLINE in real life).
if [[ ! -f root.crt ]]; then
  echo ">> generating offline root CA"
  openssl genrsa -out root.key 4096
  openssl req -x509 -new -nodes -key root.key -sha256 -days 7300 \
    -subj "/CN=Offline Test Root CA/O=Stakater" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out root.crt
else
  echo ">> reusing existing offline root CA (root.crt)"
fi

# 2) Pull the operator-generated CSR.
echo ">> fetching CSR from secret $CSR_SECRET"
$OC get secret "$CSR_SECRET" -n "$NS" -o jsonpath="{.data.$CSR_KEY}" | base64 -d > platform.csr
if [[ ! -s platform.csr ]]; then
  echo "ERROR: CSR not found/empty. Is platformPki.mode=intermediate deployed and reconciled yet?" >&2
  exit 1
fi

# 3) Sign the CSR as an intermediate CA cert. pathlen:1 — the platform CA must
#    be able to issue the per-tenant intermediate CAs below it (root → platform
#    → tenant → leaf), so it needs to allow at least one further CA in the chain.
#    pathlen:0 would let it issue only leaves and block tenant intermediates.
echo ">> signing CSR with offline root"
openssl x509 -req -in platform.csr \
  -CA root.crt -CAkey root.key -CAcreateserial \
  -days 3650 -sha256 \
  -extfile <(printf "basicConstraints=critical,CA:TRUE,pathlen:1\nkeyUsage=critical,keyCertSign,cRLSign\n") \
  -out platform.crt

# 4) Full chain (signed intermediate + root) for set-signed.
cat platform.crt root.crt > platform-chain.crt

# 5) Hand the signed cert back to the operator.
echo ">> writing signed cert into secret $SIGNED_SECRET[$SIGNED_KEY]"
$OC create secret generic "$SIGNED_SECRET" -n "$NS" \
  --from-file=$SIGNED_KEY=platform-chain.crt \
  --dry-run=client -o yaml | $OC apply -f -

echo ">> done. Watch the platform CA go Active:"
echo "   $OC get openbaopkisecretengineconfig platform-pki -n $NS -o jsonpath='{.status.conditions[-1].type}={.status.conditions[-1].status} {.status.conditions[-1].reason}{\"\\n\"}'"
