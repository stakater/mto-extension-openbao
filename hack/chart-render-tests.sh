#!/usr/bin/env bash
# Render tests for the openbao-config-mto component split.
#
# The chart renders one of four disjoint slices per pass (values.component:
# core | eso | certManager | trust; default all). These tests pin the
# invariants the split depends on:
#
#   1. golden      — component=all is object-set identical to the committed
#                    golden render (standalone/back-compat guard).
#   2. disjoint    — no object is emitted by two slices, so two
#                    TemplateInstances never fight over one object via SSA.
#   3. union       — the four slices together emit exactly the all set (no
#                    block gated into zero components), minus one recorded
#                    standalone-only object; see the check for why.
#   4. exclusivity — each optional operator's apiVersions appear only in
#                    their own slice.
#   5. empty       — certManager slice with zero PKI opt-ins renders zero
#                    objects (a benign empty TI, not a failure).
#   6. badvalue    — an unrecognized component fails the render loudly.
#   7. emission    — the parent gotemplate emits a TemplateInstance for every
#                    component whose toggle is on, with the right templateRef,
#                    and none for toggles that are off. Guards against a slice
#                    gated in the chart but never given a TI to render in.
#   8. namebudget  — sliced renders fail with the budget table when the tenant
#                    name would push the implied TI name past the 63-char
#                    label-value cap; component=all is exempt.
#   9. templateset — the bootstrap installs a child Template for exactly the
#                    enabled components, and every templateRef the parent
#                    emits resolves to one of them. Guards both directions: a
#                    Template with no TI is a standing chart-pull cost, a TI
#                    with no Template is a broken tenant.
#  10. rbacscope   — `create` on each optional integration's kinds exists only
#                    while its toggle is on. template-operator-v2 renders
#                    arbitrary charts, so every grant it holds is reachable by
#                    anything templated through it; cluster-scoped Bundles in
#                    particular cannot be narrowed any other way.
#  11. rbacteardown — the counterweight: the verbs the TI finalizer needs to
#                    reap a slice's objects are granted regardless of any
#                    toggle. Gating them alongside `create` orphans every
#                    object the slice created when the toggle goes off.
#  12. subread    — a subscribe-to-ns grant is read-only on the PRODUCING
#                    namespace's prefix, on the metadata path as well as the
#                    data path. KV v2 metadata is not a read-only view: update
#                    sets delete_version_after/max_versions and delete removes
#                    every version, so a subscriber carrying its own tier caps
#                    here can destroy secrets it should only read.
#
# The emission test renders files/parent-gotemplate.tpl through helm's tpl —
# an approximation of t-op-v2's text/template+Sprig engine that is exact for
# the constructs the gotemplate uses (range/dict/list/append/eq).
#
# Regenerating the golden after an INTENTIONAL chart change:
#   helm template openbao-config-mto charts/openbao-config-mto \
#     -n openbao-config-operator-system -f hack/render-fixtures/values-full.yaml \
#     | yq ea -P '[.] | sort_by(.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name) | .[] | sort_keys(..) | splitDoc' \
#     > hack/render-fixtures/golden-all.yaml
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/openbao-config-mto"
BOOTSTRAP="$REPO_ROOT/charts/openbao-config-mto-bootstrap"
FIXTURES="$REPO_ROOT/hack/render-fixtures"
HELM="${HELM:-$(command -v "$REPO_ROOT/bin/helm" || command -v helm)}"
YQ="${YQ:-$(command -v "$REPO_ROOT/bin/yq" || command -v yq)}"
RELEASE=openbao-config-mto
NS=openbao-config-operator-system
SLICES="core eso certManager trust"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # check <name> <ok:0|1> [detail]
  if [ "$2" -eq 0 ]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1${3:+ — $3}"
    fail=1
  fi
}

render() { # render <component> <valuesfile> -> raw manifest on stdout
  "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$2" --set "component=$1"
}

# Sort docs by identity and normalize key order so comparisons are stable
# across whitespace/ordering shifts. Comparisons always normalize BOTH sides
# with the same yq, so yq version drift cancels out.
normalize() {
  "$YQ" ea -P '[.] | sort_by(.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name) | .[] | sort_keys(..) | splitDoc'
}

identities() { # identities <normalized-file>
  "$YQ" ea '[.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name] | .[]' "$1" | sort
}

for c in all $SLICES; do
  render "$c" "$FIXTURES/values-full.yaml" | normalize > "$WORK/$c.yaml"
  identities "$WORK/$c.yaml" > "$WORK/$c.ids"
done

# 1. golden
normalize < "$FIXTURES/golden-all.yaml" > "$WORK/golden.yaml"
diff -u "$WORK/golden.yaml" "$WORK/all.yaml" > "$WORK/golden.diff" \
  && check golden 0 \
  || check golden 1 "component=all drifted from golden-all.yaml (see header for regeneration); first lines: $(head -4 "$WORK/golden.diff" | tr '\n' ' ')"

# 2. disjoint
overlap=""
for a in $SLICES; do
  for b in $SLICES; do
    [ "$a" \< "$b" ] || continue
    overlap="$overlap$(comm -12 "$WORK/$a.ids" "$WORK/$b.ids")"
  done
done
[ -z "$overlap" ] && check disjoint 0 || check disjoint 1 "emitted by two slices: $overlap"

# 3. union
# One object is deliberately standalone-only, so it is excluded from both sides
# rather than allowed to mask a real gap: the per-namespace Role backing
# bao-cert-manager's token-create permission. Under the operator that permission
# is defined once as a ClusterRole by the bootstrap chart and only bound by the
# certManager slice, because a Role rendered next to its own RoleBinding can
# never pass template-operator-v2's dry-run (see 10-cert-manager-issuer.yaml).
# component=all has no dry-run and no bootstrap chart, so it keeps the Role.
# Anything else diverging between the two paths still fails this check.
STANDALONE_ONLY='\|Role\|[^|]*\|bao-cert-manager-token-create$'
grep -vE "$STANDALONE_ONLY" "$WORK/all.ids" > "$WORK/all.union-cmp"
sort $(for c in $SLICES; do echo "$WORK/$c.ids"; done) | grep -vE "$STANDALONE_ONLY" > "$WORK/union.ids"
if [ "$(grep -cE "$STANDALONE_ONLY" "$WORK/all.ids")" -eq 0 ]; then
  check union 1 "the standalone-only Role is gone from component=all — drop the exclusion above"
else
  diff "$WORK/union.ids" "$WORK/all.union-cmp" > /dev/null \
    && check union 0 \
    || check union 1 "slices ∪ ≠ all: $(diff "$WORK/union.ids" "$WORK/all.union-cmp" | head -4 | tr '\n' ' ')"
fi

# 4. exclusivity — optional apiVersion groups appear only in their own slice
exclusivity_ok=0
exclusivity_detail=""
for pair in "external-secrets.io:eso" "cert-manager.io:certManager" "trust.cert-manager.io:trust"; do
  domain="${pair%%:*}"; owner="${pair##*:}"
  for c in $SLICES; do
    hits="$(grep -cE "^apiVersion: ${domain//./\\.}/" "$WORK/$c.yaml" || true)"
    if [ "$c" = "$owner" ]; then
      [ "$hits" -gt 0 ] || { exclusivity_ok=1; exclusivity_detail="$exclusivity_detail $domain missing from $owner;"; }
    else
      [ "$hits" -eq 0 ] || { exclusivity_ok=1; exclusivity_detail="$exclusivity_detail $domain leaked into $c;"; }
    fi
  done
done
check exclusivity "$exclusivity_ok" "$exclusivity_detail"

# 5. empty slice
emptycount="$(render certManager "$FIXTURES/values-no-optins.yaml" | normalize | grep -c '^kind:' || true)"
[ "$emptycount" -eq 0 ] && check empty 0 || check empty 1 "expected 0 objects, got $emptycount"

# 6. bad value
if render bogus "$FIXTURES/values-full.yaml" > /dev/null 2> "$WORK/bogus.err"; then
  check badvalue 1 "component=bogus rendered instead of failing"
else
  grep -q 'unknown component' "$WORK/bogus.err" \
    && check badvalue 0 \
    || check badvalue 1 "render failed but without the componentEnabled message: $(head -2 "$WORK/bogus.err" | tr '\n' ' ')"
fi

# 7. emission — parent gotemplate emits one TI per enabled component
mkdir -p "$WORK/shim/templates" "$WORK/shim/files"
cp "$BOOTSTRAP/files/parent-gotemplate.tpl" "$WORK/shim/files/"
printf 'apiVersion: v2\nname: shim\nversion: 0.0.1\n' > "$WORK/shim/Chart.yaml"
printf '{{ tpl ($.Files.Get "files/parent-gotemplate.tpl") (dict "parameters" .Values.parameters) }}\n' > "$WORK/shim/templates/render.yaml"
cat > "$WORK/shim/values.yaml" <<'EOF'
parameters:
  env: dev
  operatorNamespace: openbao-config-operator-system
  tokenReviewerSecretName: bao-token-reviewer
  kubernetesHost: https://kubernetes.default.svc
  childTemplateName: openbao-config-mto
  tenantLabelKey: stakater.com/tenant
  sharedTenantName: shared
  ssoEnabled: "false"
  ssoIssuerUrl: ""
  eso: enabled
  externalSecretRefreshInterval: "1h"
  certManagerEnabled: "false"
  crossTenantPkiEnabled: "false"
  tenants:
    - metadata:
        name: team-a
      spec:
        namespaces:
          withTenantPrefix: [dev]
    - metadata:
        name: empty-tenant
      spec: {}
EOF

emit() { # emit <eso> <certManager> <crossTenantPki> -> "name->templateRef" lines, sorted
  "$HELM" template shim "$WORK/shim" \
    --set "parameters.eso=$1" \
    --set-string "parameters.certManagerEnabled=$2" \
    --set-string "parameters.crossTenantPkiEnabled=$3" \
    | "$YQ" 'select(.kind == "TemplateInstance") | .metadata.name + "->" + .spec.templateRef.name' - | grep -v '^---$' | sort
}

emission_case() { # emission_case <name> <eso> <cm> <ct> <expected...>
  local name="$1" eso="$2" cm="$3" ct="$4"; shift 4
  local got expected
  got="$(emit "$eso" "$cm" "$ct")"
  expected="$(printf '%s\n' "$@" | sort)"
  if [ "$got" = "$expected" ]; then
    check "emission:$name" 0
  else
    check "emission:$name" 1 "expected [$(echo "$expected" | tr '\n' ' ')] got [$(echo "$got" | tr '\n' ' ')]"
  fi
}

emission_case all-on enabled true true \
  "openbao-config-mto-team-a->openbao-config-mto" \
  "openbao-config-mto-team-a.eso->openbao-config-mto-eso" \
  "openbao-config-mto-team-a.certmanager->openbao-config-mto-certmanager" \
  "openbao-config-mto-team-a.trust->openbao-config-mto-trust"
emission_case defaults enabled false false \
  "openbao-config-mto-team-a->openbao-config-mto" \
  "openbao-config-mto-team-a.eso->openbao-config-mto-eso"
# The regression this test exists for: crossTenantPki on with certManager
# off must still get a TI for the trust slice, or the Bundle renders nowhere.
emission_case trust-only disabled false true \
  "openbao-config-mto-team-a->openbao-config-mto" \
  "openbao-config-mto-team-a.trust->openbao-config-mto-trust"
emission_case all-off disabled false false \
  "openbao-config-mto-team-a->openbao-config-mto"

# 8. namebudget — sliced renders enforce the TI-name-as-label 63-char cap.
# A 40-char tenant fits core (19+40=59) but not .certmanager (19+40+12=71);
# component=all is exempt (standalone install, no TI convention in play).
LONG_TENANT="$(printf 'a%.0s' $(seq 1 40))"
if render_out="$("$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" --set-string "tenant=$LONG_TENANT" --set component=certManager 2>&1)"; then
  check namebudget-over 1 "40-char tenant with component=certManager rendered instead of failing"
else
  echo "$render_out" | grep -q "label values cap at 63" \
    && check namebudget-over 0 \
    || check namebudget-over 1 "failed without the budget message: $(echo "$render_out" | head -2 | tr '\n' ' ')"
fi
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" --set-string "tenant=$LONG_TENANT" --set component=core > /dev/null 2>&1 \
  && check namebudget-core-ok 0 \
  || check namebudget-core-ok 1 "40-char tenant should fit the core TI (59 chars)"
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" --set-string "tenant=$LONG_TENANT" > /dev/null 2>&1 \
  && check namebudget-all-exempt 0 \
  || check namebudget-all-exempt 1 "component=all must not enforce the TI budget (standalone use)"

# 9. templateset — the installed child Templates match the enabled components,
# and every templateRef the parent emits resolves to an installed Template.
tset() { # tset <eso> <certManager> <crossTenantPki> -> sorted Template names
  "$HELM" template boot "$BOOTSTRAP" -n "$NS" \
    --set-string "parent.eso=$1" \
    --set-string "parent.certManager.enabled=$2" \
    --set-string "crossTenantPki.enabled=$3" \
    | "$YQ" 'select(.kind == "Template") | .metadata.name' - | grep -v '^---$' | sort
}

templateset_case() { # templateset_case <name> <eso> <cm> <ct> <expected...>
  local name="$1" eso="$2" cm="$3" ct="$4"; shift 4
  local got expected refs missing
  got="$(tset "$eso" "$cm" "$ct")"
  expected="$(printf '%s\n' "$@" openbao-config-mto-parent | sort)"
  if [ "$got" != "$expected" ]; then
    check "templateset:$name" 1 "Templates were [$(echo "$got" | tr '\n' ' ')], want [$(echo "$expected" | tr '\n' ' ')]"
    return
  fi
  # Every templateRef the parent emits for this toggle set must be installed.
  refs="$(emit "$eso" "$cm" "$ct" | sed 's/.*->//' | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "$refs") <(printf '%s\n' "$got"))"
  [ -z "$missing" ] \
    && check "templateset:$name" 0 \
    || check "templateset:$name" 1 "parent emits TIs referencing absent Templates: $(echo "$missing" | tr '\n' ' ')"
}

rbac_rules() { # rbac_rules <eso> <certManager> <crossTenantPki> -> "group/resources -> verbs"
  "$HELM" template boot "$BOOTSTRAP" -n "$NS" \
    --set-string "parent.eso=$1" \
    --set-string "parent.certManager.enabled=$2" \
    --set-string "crossTenantPki.enabled=$3" \
    | "$YQ" 'select(.kind == "ClusterRole" and .metadata.name == "openbao-config-mto-manager")
             | .rules[] | ((.apiGroups[0] // "core") + "/" + (.resources | join(",")) + " -> " + (.verbs | join(",")))' - \
    | sort -u
}

# `create` on a kind that only an optional integration renders must exist only
# while that integration is switched on. Anything here that survives its toggle
# being off lets an engine that renders arbitrary charts mint new Issuers,
# Bundles, SecretStores, ServiceAccounts or RBAC cluster-wide.
# Keys are "<apiGroup>/<resources> -> <verbs>"; the core group renders empty,
# so its keys start with "/".
OPTIONAL_CREATE_GRANTS='external-secrets.io/secretstores,externalsecrets -> create
cert-manager.io/issuers -> create
trust.cert-manager.io/bundles -> create
rbac.authorization.k8s.io/rolebindings -> create
/serviceaccounts/token -> create
/serviceaccounts -> create'

# The mirror image, and the reason the gating above is create-only: these must
# be granted REGARDLESS of any toggle. Turning an integration off in one helm
# upgrade removes the child Template and rewrites this ClusterRole at the same
# time, but template-operator-v2 reaps the slice's objects afterwards — its TI
# finalizer lists them, patches its own finalizer off each one, and deletes
# them. Revoking these alongside the toggle wedges that finalizer on Forbidden
# forever: TI stuck Terminating, child Template unable to finalize behind it,
# and every object the slice created orphaned with a finalizer nothing will
# remove. Recovery needs a hand-applied ClusterRole.
TEARDOWN_GRANTS='external-secrets.io/secretstores,externalsecrets -> get,list,watch,update,patch,delete
cert-manager.io/issuers -> get,list,watch,update,patch,delete
trust.cert-manager.io/bundles -> get,list,watch,update,patch,delete
rbac.authorization.k8s.io/roles,rolebindings -> get,list,watch,update,patch,delete
/serviceaccounts -> update,patch,delete'

grants_case() { # grants_case <test> <name> <eso> <cm> <ct> <present|absent> <grantlist>
  local test="$1" name="$2" eso="$3" cm="$4" ct="$5" mode="$6" list="$7"
  local got wrong=""
  got="$(rbac_rules "$eso" "$cm" "$ct")"
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    if printf '%s\n' "$got" | grep -qF "$g"; then
      [ "$mode" = absent ] && wrong="$wrong [granted:$g]"
    else
      [ "$mode" = present ] && wrong="$wrong [missing:$g]"
    fi
  done <<EOF
$list
EOF
  [ -z "$wrong" ] \
    && check "$test:$name" 0 \
    || check "$test:$name" 1 "expected $mode, but:$wrong"
}

grants_case rbacscope all-off disabled false false absent  "$OPTIONAL_CREATE_GRANTS"
grants_case rbacscope all-on  enabled  true  true  present "$OPTIONAL_CREATE_GRANTS"

grants_case rbacteardown all-off disabled false false present "$TEARDOWN_GRANTS"
grants_case rbacteardown all-on  enabled  true  true  present "$TEARDOWN_GRANTS"

# 12. subread — subscriptions must be read-only on the producer's prefix.
# values-full.yaml has team-a-dev/app-a subscribing to team-a-tools. Its policy
# must not carry a write/delete verb on from-team-a-tools; its OWN from-team-a-dev
# prefix must keep them, which is what stops this passing vacuously.
subread_policy="$("$YQ" ea 'select(.kind == "OpenBaoPolicy" and .metadata.name == "team-a-team-a-dev-app-a-editor") | .spec.policy' "$WORK/core.yaml")"
sub_line="$(printf '%s\n' "$subread_policy" | grep 'kv/metadata/dev/_shared/from-team-a-tools/' || true)"
own_line="$(printf '%s\n' "$subread_policy" | grep 'kv/metadata/dev/_shared/from-team-a-dev/' | grep -c 'create' || true)"
if [ -z "$sub_line" ]; then
  check subread 1 "no subscribed-namespace metadata rule found — fixture drifted"
elif printf '%s\n' "$sub_line" | grep -qE '"(create|update|delete)"'; then
  check subread 1 "subscription grants write on the producer's metadata: $(printf '%s' "$sub_line" | tr -s ' ')"
elif [ "$own_line" -eq 0 ]; then
  check subread 1 "own-namespace metadata lost its write caps — test would pass vacuously"
else
  check subread 0
fi

templateset_case defaults  enabled  false false openbao-config-mto openbao-config-mto-eso
templateset_case all-on    enabled  true  true  openbao-config-mto openbao-config-mto-eso openbao-config-mto-certmanager openbao-config-mto-trust
templateset_case all-off   disabled false false openbao-config-mto
templateset_case trust-only disabled false true openbao-config-mto openbao-config-mto-trust

exit "$fail"
