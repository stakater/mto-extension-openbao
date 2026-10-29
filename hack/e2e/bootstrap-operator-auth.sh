#!/usr/bin/env bash
#
# Give the openbao-config-operator its own OpenBao identity on the E2E cluster:
# a kubernetes auth mount, the operator-manage policy and a login role bound to
# the operator's ServiceAccount. This is the "Bootstrap (once per OpenBao
# server)" step from the operator README, done with the bao CLI that ships in
# the OpenBao pod — no extra images, no port-forward.
#
# Two deliberate differences from the operator repo's bootstrap_operator_auth.sh:
#
#   1. No token_reviewer_jwt. bao validates login JWTs with its OWN ServiceAccount
#      token — the OpenBao chart binds system:auth-delegator to it by default
#      (server.authDelegator.enabled) — so the operator's mount depends on nothing
#      the suite creates or deletes. The suite installs and UNINSTALLS the
#      bootstrap chart per test, and that chart owns the `bao-token-reviewer`
#      Secret the operator repo's script would otherwise point bao at: a reviewer
#      credential deleted mid-run breaks the operator's login an hour later, when
#      its cached token expires, and looks like a chart bug two tests further on.
#      The per-tenant auth mounts still use the chart's reviewer Secret — that IS
#      chart behaviour, and the suite tests it through workload logins.
#   2. The policy is the vendored hack/e2e/operator-policy.hcl (provenance in its
#      header) — the real one, so a chart depending on a grant the operator does
#      not have fails here rather than on a customer's cluster.
#
# Idempotent. Every value written is half of a pair whose other half is the
# operator Deployment (ServiceAccount, audience, mount, role), so the inputs are
# read FROM the live Deployment and the script ends by logging in as that
# ServiceAccount — the only check that proves the pair matches.
set -euo pipefail

KUBECTL=${KUBECTL:-kubectl}
CONTEXT=${E2E_CONTEXT:?E2E_CONTEXT must be set}
BAO_NS=${E2E_BAO_NS:-openbao}
BAO_POD=${E2E_BAO_POD:-openbao-0}
OPERATOR_NS=${E2E_OPERATOR_NS:-openbao-config-operator-system}
ROOT_TOKEN=${BAO_ROOT_TOKEN:-root}
POLICY_NAME=${POLICY_NAME:-operator-manage}
POLICY_FILE=${POLICY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/operator-policy.hcl}
TOKEN_TTL=${TOKEN_TTL:-1h}

command -v jq >/dev/null 2>&1 || { echo "jq is required but is not on PATH" >&2; exit 1; }
[ -f "${POLICY_FILE}" ] || { echo "policy file not found: ${POLICY_FILE}" >&2; exit 1; }

kc() { "${KUBECTL}" --context "${CONTEXT}" "$@"; }
# The root token only ever travels as an env var into the pod's exec session,
# never as a CLI argument that a process listing would show.
bao() { kc -n "${BAO_NS}" exec -i "${BAO_POD}" -- env BAO_TOKEN="${ROOT_TOKEN}" bao "$@"; }

echo ">> Reading the operator's half of the pairs from its Deployment"
dep=$(kc -n "${OPERATOR_NS}" get deploy -l control-plane=controller-manager -o json | jq -c '.items[0] // empty')
[ -n "${dep}" ] || { echo "no controller-manager Deployment in ${OPERATOR_NS} — install the operator first" >&2; exit 1; }
env_of() { printf '%s' "${dep}" | jq -r --arg n "$1" '.spec.template.spec.containers[0].env[]? | select(.name==$n) | .value // empty'; }
method=$(env_of BAO_AUTH_METHOD)
[ "${method}" = "kubernetes" ] || { echo "the Deployment runs BAO_AUTH_METHOD=${method:-<unset>}, not kubernetes; this bootstrap is for the kubernetes login path" >&2; exit 1; }
sa=$(printf '%s' "${dep}" | jq -r '.spec.template.spec.serviceAccountName // empty')
aud=$(printf '%s' "${dep}" | jq -r '[.spec.template.spec.volumes[]?.projected.sources[]?.serviceAccountToken.audience | select(. != null and . != "")] | first // empty')
mount=$(env_of BAO_AUTH_MOUNT); mount=${mount:-k8s-operator}
role=$(env_of BAO_AUTH_ROLE);   role=${role:-openbao-config-operator}
[ -n "${sa}" ]  || { echo "Deployment has no serviceAccountName" >&2; exit 1; }
[ -n "${aud}" ] || { echo "Deployment projects no audience-bound ServiceAccount token; expected a projected volume with serviceAccountToken.audience" >&2; exit 1; }
echo "   serviceaccount=${OPERATOR_NS}/${sa} audience=${aud} mount=${mount} role=${role}"

echo ">> Enabling kubernetes auth at auth/${mount}"
if bao auth list -format=json | jq -e --arg m "${mount}/" 'has($m)' >/dev/null; then
  echo "   already enabled"
else
  bao auth enable -path="${mount}" -description="operator self-login (bootstrap-owned; not managed via CRs)" kubernetes
fi

echo ">> Writing auth/${mount}/config (kubernetes_host only — bao reviews tokens with its own ServiceAccount)"
bao write "auth/${mount}/config" kubernetes_host=https://kubernetes.default.svc >/dev/null

echo ">> Writing policy ${POLICY_NAME} from ${POLICY_FILE}"
bao policy write "${POLICY_NAME}" - < "${POLICY_FILE}" >/dev/null
bao policy read "${POLICY_NAME}" >/dev/null

echo ">> Writing role ${role} bound to ${OPERATOR_NS}/${sa} (ttl=${TOKEN_TTL}, audience=${aud})"
bao write "auth/${mount}/role/${role}" \
  bound_service_account_names="${sa}" \
  bound_service_account_namespaces="${OPERATOR_NS}" \
  token_policies="${POLICY_NAME}" \
  token_ttl="${TOKEN_TTL}" \
  audience="${aud}" >/dev/null

# The probe. A readable role proves nothing about whether the operator can use
# it; a login as the Deployment's own ServiceAccount, with the Deployment's own
# audience, exercises the mount, the role binding, bao's TokenReview access and
# the policy attachment in one request.
echo ">> Verifying the operator can log in"
jwt=$(kc -n "${OPERATOR_NS}" create token "${sa}" --audience="${aud}" --duration=10m)
out=$(kc -n "${BAO_NS}" exec -i "${BAO_POD}" -- bao write -format=json "auth/${mount}/login" role="${role}" jwt="${jwt}" 2>&1) || {
  echo "login FAILED — the mount, policy and role were written, but ${OPERATOR_NS}/${sa} cannot authenticate with them. bao said:" >&2
  printf '%s\n' "${out}" | sed 's/^/  /' >&2
  exit 1
}
policies=$(printf '%s' "${out}" | jq -r '.auth.token_policies | join(",")')
case ",${policies}," in
  *",${POLICY_NAME},"*) ;;
  *) echo "login succeeded but the token carries policies [${policies}], not ${POLICY_NAME}" >&2; exit 1 ;;
esac
echo "   OK — ${OPERATOR_NS}/${sa} logged in at auth/${mount}/login with policies: ${policies}"
