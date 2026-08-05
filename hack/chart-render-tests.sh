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
#  12. toggletypo — a near-miss on an integration switch (yes / on / True / 1,
#                    or "true" for the string-valued parent.eso) fails the
#                    render instead of silently disabling the integration.
#                    Either boundary satisfies this — 13 and 14 pin them
#                    individually. Canonical forms must still render.
#                    `component` is left to _helpers.tpl's own fail(), which
#                    predates this and gives a better message — see check 6.
#  13. toggleschema — values.schema.json rejects a typo with the templates
#                    stripped out, so the schema is verified independently of
#                    the template guard.
#  14. togglehelper — _helpers.tpl rejects a typo with values.schema.json
#                    removed, so the guard is verified independently of the
#                    schema. Stops the helpers being deleted on the assumption
#                    the schema covers it: the schema is skippable (helm >=
#                    3.16 --skip-schema-validation) and is not applied on every
#                    path that renders a chart through the Helm SDK.
#  15. togglenorm — each child Template parameter carries the value of the
#                    toggle it is named after (a mis-wiring guard). Every
#                    toggle in the fixture gets a distinct value, or swapping
#                    two of them would go unnoticed.
#  16. subread    — a subscribe-to-ns grant is read-only on the PRODUCING
#                    namespace's prefix, on the metadata path as well as the
#                    data path. KV v2 metadata is not a read-only view: update
#                    sets delete_version_after/max_versions and delete removes
#                    every version, so a subscriber carrying its own tier caps
#                    here can destroy secrets it should only read.
#  17. sharedpolicy — the parent gotemplate's shared-tenant data CRs carry a
#                    deletionPolicy driven by safetyDeletionProtection; only an
#                    exact "false" flips to Delete.
#  18. deletionflip — the tenant chart's two safety knobs flip exactly their
#                    own kind group (data vs grants).
#  19. tenantguard — the tenant chart's safety helpers fail loudly on garbage
#                    without the schema, and a null safety block falls to the
#                    safe defaults.
#  20. platformpki — the bootstrap chart's own platform-PKI CRs follow
#                    safety.deletionProtection in both postures.
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
  safetyDeletionProtection: "true"
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

# 17. sharedpolicy — the parent gotemplate's shared-tenant data-bearing CRs
# (OpenBaoNamespace, both OpenBaoSecretEngines, OpenBaoAuthMethod) carry a
# deletionPolicy driven by the safetyDeletionProtection parameter. Only an
# exact "false" flips to Delete; anything else — including garbage from a
# mis-plumbed parameter — fails toward Retain, because the shared namespace
# holds every tenant's shared KV/transit data. A kind missing the field
# would surface as a "null" in the unique-value set and fail the check.
shared_policy() { # <safetyParam> -> comma-joined unique deletionPolicy values
  "$HELM" template shim "$WORK/shim" --set-string "parameters.safetyDeletionProtection=$1" \
    | "$YQ" ea -N 'select(.kind == "OpenBaoNamespace" or .kind == "OpenBaoSecretEngine" or .kind == "OpenBaoAuthMethod") | .spec.deletionPolicy' - \
    | grep -v '^---$' | sort -u | tr '\n' ',' | sed 's/,$//'
}
sp_ok=0; sp_detail=""
for pair in "true:Retain" "false:Delete" "garbage:Retain"; do
  param="${pair%%:*}"; want="${pair##*:}"
  got="$(shared_policy "$param")"
  [ "$got" = "$want" ] || { sp_ok=1; sp_detail="$sp_detail [$param->$got want=$want]"; }
done
[ "$sp_ok" -eq 0 ] && check sharedpolicy 0 || check sharedpolicy 1 "$sp_detail"

# 19. tenantguard — the tenant chart's safety helpers survive a schema-less
# render (SDK paths, --skip-schema-validation): garbage fails loudly with the
# helper's own message, and a null safety block falls to the safe defaults
# (data Retain, grants Delete) instead of nil-pointering.
cp -R "$CHART" "$WORK/tenant-noschema"
rm -f "$WORK/tenant-noschema/values.schema.json"
tg_ok=0; tg_detail=""
if "$HELM" template x "$WORK/tenant-noschema" -n "$NS" -f "$FIXTURES/values-full.yaml" \
    --set-string safety.deletionProtection=yes >/dev/null 2>"$WORK/tg-err.txt"; then
  tg_ok=1; tg_detail="$tg_detail [garbage accepted without schema]"
elif ! grep -q "safety.deletionProtection must be a boolean" "$WORK/tg-err.txt"; then
  tg_ok=1; tg_detail="$tg_detail [failed without the helper message]"
fi
printf 'safety: null\n' > "$WORK/tg-null.yaml"
tg_null="$("$HELM" template x "$WORK/tenant-noschema" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  -f "$WORK/tg-null.yaml" 2>/dev/null \
  | "$YQ" ea -N 'select(.kind == "OpenBaoSecretEngine" or .kind == "OpenBaoNamespace" or .kind == "OpenBaoAuthMethod") | .spec.deletionPolicy' - \
  | grep -v '^---$' | sort -u | tr '\n' ',' | sed 's/,$//')"
[ "$tg_null" = "Retain" ] || { tg_ok=1; tg_detail="$tg_detail [null-block data policy=$tg_null want=Retain]"; }
[ "$tg_ok" -eq 0 ] && check tenantguard 0 || check tenantguard 1 "$tg_detail"

# 20. platformpki — the bootstrap chart's own data-bearing CRs (the platform
# PKI OpenBaoNamespace + OpenBaoSecretEngine) follow safety.deletionProtection.
# Guards the ternary wiring in 50-platform-pki.yaml, which no other case
# renders.
pp_ok=0; pp_detail=""
pp_def="$("$HELM" template boot "$BOOTSTRAP" 2>/dev/null | "$YQ" ea -N 'select(.kind == "OpenBaoNamespace" or .kind == "OpenBaoSecretEngine") | .spec.deletionPolicy' - | grep -v '^---$' | sort -u | tr '\n' ',' | sed 's/,$//')"
[ "$pp_def" = "Retain" ] || { pp_ok=1; pp_detail="$pp_detail [default=$pp_def want=Retain]"; }
pp_off="$("$HELM" template boot "$BOOTSTRAP" --set safety.deletionProtection=false 2>/dev/null | "$YQ" ea -N 'select(.kind == "OpenBaoNamespace" or .kind == "OpenBaoSecretEngine") | .spec.deletionPolicy' - | grep -v '^---$' | sort -u | tr '\n' ',' | sed 's/,$//')"
[ "$pp_off" = "Delete" ] || { pp_ok=1; pp_detail="$pp_detail [flipped=$pp_off want=Delete]"; }
[ "$pp_ok" -eq 0 ] && check platformpki 0 || check platformpki 1 "$pp_detail"

# 8. namebudget — sliced renders enforce the TI-name-as-label 63-char cap.
# A 40-char tenant fits core (19+40=59) but not .certmanager (19+40+12=71);
# component=all is exempt (standalone install, no TI convention in play).
LONG_TENANT="$(printf 'a%.0s' $(seq 1 40))"
if render_out="$("$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" --set-string "tenant=$LONG_TENANT" --set component=certManager 2>&1)"; then
  check namebudget-over 1 "40-char tenant with component=certManager rendered instead of failing"
else
  grep -q "label values cap at 63" <<<"$render_out" \
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
    if grep -qF "$g" <<<"$got"; then
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

# 12. toggletypo — near-misses are rejected, canonical forms are not
boot_render() { # boot_render <set-string args...>
  "$HELM" template boot "$BOOTSTRAP" "$@" 2>&1
}
typo_ok=0; typo_detail=""
for kv in \
  "parent.certManager.enabled=yes" "parent.certManager.enabled=on" \
  "parent.certManager.enabled=True" "parent.certManager.enabled=1" \
  "crossTenantPki.enabled=yes" "crossTenantPki.enabled=TRUE" \
  "parent.eso=enabledd" "parent.eso=true" "parent.eso=Enabled" \
  "safety.deletionProtection=yes" "safety.grantDeletionProtection=1" \
  "sync.mode=on"; do
  if boot_render --set-string "$kv" >/dev/null 2>&1; then
    typo_ok=1; typo_detail="$typo_detail [accepted:$kv]"
  fi
done
# and the canonical forms must still work, or the check passes vacuously
for kv in "parent.certManager.enabled=true" "parent.certManager.enabled=false" \
          "crossTenantPki.enabled=true" "parent.eso=enabled" "parent.eso=disabled" \
          "safety.deletionProtection=false" "safety.grantDeletionProtection=true" \
          "sync.mode=revert" "sync.mode=off"; do
  if ! boot_render --set-string "$kv" >/dev/null 2>&1; then
    typo_ok=1; typo_detail="$typo_detail [rejected-valid:$kv]"
  fi
done
[ "$typo_ok" -eq 0 ] && check toggletypo 0 || check toggletypo 1 "$typo_detail"

# 13. togglenorm — parameters stamped for the gotemplate are canonical
norm_ok=0; norm_detail=""
# Every toggle gets a DISTINCT value on purpose. With two switches both set to
# "true", swapping which helper feeds which parameter is undetectable — the
# first version of this check passed with the wiring crossed.
norm_out="$(boot_render --set-string parent.certManager.enabled=true \
                        --set-string crossTenantPki.enabled=false \
                        --set-string parent.eso=enabled \
                        --set-string parent.sso.enabled=false \
                        --set-string safety.deletionProtection=false \
                        --set-string safety.grantDeletionProtection=true \
                        --set-string platformPki.enabled=true)"
for pair in "certManagerEnabled:true" "crossTenantPkiEnabled:false" "eso:enabled" "ssoEnabled:false" "pkiHierarchyEnabled:true" "safetyDeletionProtection:false" "safetyGrantDeletionProtection:true"; do
  pname="${pair%%:*}"; want="${pair##*:}"
  got="$(printf '%s\n' "$norm_out" | "$YQ" ea -N "select(.kind == \"Template\") | .spec.parameters[] | select(.name == \"$pname\") | .value" - | sort -u | tr '\n' ',' | sed 's/,$//')"
  [ "$got" = "$want" ] || { norm_ok=1; norm_detail="$norm_detail [$pname=$got want=$want]"; }
done
[ "$norm_ok" -eq 0 ] && check togglenorm 0 || check togglenorm 1 "$norm_detail"

# 14. toggleschema — the schema rejects a typo on its own, with no template
# logic in play. Rendered from a copy whose templates are stripped, so nothing
# but values.schema.json can produce the error. Without this, loosening the
# schema still "passes" toggletypo because the _helpers.tpl guard catches it.
mkdir -p "$WORK/boot-noguard/templates"
cp "$BOOTSTRAP/Chart.yaml" "$BOOTSTRAP/values.yaml" "$BOOTSTRAP/values.schema.json" "$WORK/boot-noguard/"
printf '# intentionally empty\n' > "$WORK/boot-noguard/templates/noop.yaml"
schema_ok=0; schema_detail=""
for kv in "parent.certManager.enabled=yes" "crossTenantPki.enabled=True" "parent.eso=enabledd" "safety.deletionProtection=yes"; do
  if "$HELM" template boot "$WORK/boot-noguard" --set-string "$kv" >/dev/null 2>&1; then
    schema_ok=1; schema_detail="$schema_detail [schema accepted:$kv]"
  fi
done
if "$HELM" template boot "$WORK/boot-noguard" --set-string parent.certManager.enabled=true >/dev/null 2>&1; then :; else
  schema_ok=1; schema_detail="$schema_detail [schema rejected a valid value]"
fi
[ "$schema_ok" -eq 0 ] && check toggleschema 0 || check toggleschema 1 "$schema_detail"

# 14. togglehelper — the fail guard works with the schema removed
cp -R "$BOOTSTRAP" "$WORK/boot-noschema"
rm -f "$WORK/boot-noschema/values.schema.json"
helper_err="$("$HELM" template boot "$WORK/boot-noschema" --set-string parent.certManager.enabled=yes 2>&1 || true)"
if grep -q 'parent.certManager.enabled must be a boolean' <<<"$helper_err"; then
  check togglehelper 0
else
  check togglehelper 1 "schema-less render did not hit the _helpers.tpl guard: $(printf '%s' "$helper_err" | head -2 | tr '\n' ' ' | cut -c1-100)"
fi

# 18. deletionflip — the two safety knobs flip exactly their own kind
# group: data-bearing kinds (SecretEngine, Namespace, AuthMethod) follow
# safety.deletionProtection, grant kinds follow safety.grantDeletionProtection.
# The DEFAULT posture (data Retain, grants Delete) is pinned by the golden;
# this guards the flipped wiring, which the golden never exercises.
flip_out="$("$HELM" template openbao-config-mto "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  --set safety.deletionProtection=false --set safety.grantDeletionProtection=true)"
flip_ok=0; flip_detail=""
flip_data="$(printf '%s\n' "$flip_out" | "$YQ" ea -N 'select(.kind == "OpenBaoSecretEngine" or .kind == "OpenBaoNamespace" or .kind == "OpenBaoAuthMethod") | .spec.deletionPolicy' - | sort -u | grep -v '^Delete$' || true)"
# The selector lists every grant kind, including ones neither chart renders
# yet (cert/JWT roles, groups, aliases, identity-token roles) — deliberate,
# so the check picks them up the day a template starts emitting them.
flip_grant="$(printf '%s\n' "$flip_out" | "$YQ" ea -N 'select(.kind == "OpenBaoPolicy" or .kind == "OpenBaoKubernetesAuthRole" or .kind == "OpenBaoCertAuthEngineRole" or .kind == "OpenBaoJWTOIDCAuthEngineRole" or .kind == "OpenBaoPKISecretEngineRole" or .kind == "OpenBaoGroup" or .kind == "OpenBaoGroupAlias" or .kind == "OpenBaoIdentityTokenRole") | .spec.deletionPolicy' - | sort -u | grep -v '^Retain$' || true)"
[ -n "$flip_data" ] && { flip_ok=1; flip_detail="$flip_detail [data-kind got: $(printf '%s' "$flip_data" | tr '\n' ',')]"; }
[ -n "$flip_grant" ] && { flip_ok=1; flip_detail="$flip_detail [grant-kind got: $(printf '%s' "$flip_grant" | tr '\n' ',')]"; }
[ "$flip_ok" -eq 0 ] && check deletionflip 0 || check deletionflip 1 "$flip_detail"

# 12. subread — subscriptions must be read-only on the producer's prefix.
# values-full.yaml has team-a-dev/app-a subscribing to team-a-tools. Its policy
# must not carry a write/delete verb on from-team-a-tools; its OWN from-team-a-dev
# prefix must keep them, which is what stops this passing vacuously.
subread_policy="$("$YQ" ea 'select(.kind == "OpenBaoPolicy" and .metadata.name == "team-a-team-a-dev-app-a") | .spec.policy' "$WORK/core.yaml")"
sub_line="$(printf '%s\n' "$subread_policy" | grep 'kv/metadata/dev/_shared/from-team-a-tools/' || true)"
own_line="$(printf '%s\n' "$subread_policy" | grep 'kv/metadata/dev/_shared/from-team-a-dev/' | grep -c 'create' || true)"
if [ -z "$sub_line" ]; then
  check subread 1 "no subscribed-namespace metadata rule found — fixture drifted"
elif grep -qE '"(create|update|delete)"' <<<"$sub_line"; then
  check subread 1 "subscription grants write on the producer's metadata: $(printf '%s' "$sub_line" | tr -s ' ')"
elif [ "$own_line" -eq 0 ]; then
  check subread 1 "own-namespace metadata lost its write caps — test would pass vacuously"
else
  check subread 0
fi

# 17. outputs — the status-outputs contract on every Template the bootstrap
# installs. A duplicate name across the FLATTENED outputs[].fields[] does not
# degrade one field: the Template reconciler sets phase=Invalid and returns
# before rendering, so one collision stops that Template for every tenant. The
# name pattern and single-{...} jsonPath shape are CRD admission rules, rejected
# at apply time. Entry and field caps are 50 each. keyTemplate is required on our
# own CRs, which all land in one namespace where the default {ns}/{name} repeats
# a constant prefix.
#
# Every jsonPath must be a list query (wildcard, recursive descent, or filter): a
# list query matching nothing resolves to "[]", while a scalar matching nothing
# fails its whole field and holds OutputsResolved False — and every non-condition
# field in our status types is omitempty, so absent is normal. SCALAR_OK lists
# the exceptions; caSerial has no condition to read the CA serial from.
SCALAR_OK="caSerial"
outputs_ok=0; outputs_detail=""
"$HELM" template boot "$BOOTSTRAP" \
  --set-string parent.eso=enabled \
  --set-string parent.certManager.enabled=true \
  --set-string crossTenantPki.enabled=true \
  | "$YQ" ea 'select(.kind == "Template")' - > "$WORK/boot-templates.yaml"

for tname in $("$YQ" ea -N 'select(.kind == "Template") | .metadata.name' "$WORK/boot-templates.yaml"); do
  sel="select(.kind == \"Template\" and .metadata.name == \"$tname\")"
  nentries="$("$YQ" ea "$sel | (.spec.outputs // []) | length" "$WORK/boot-templates.yaml")"
  if [ "$nentries" -eq 0 ]; then continue; fi
  [ "$nentries" -le 50 ] || outputs_detail="$outputs_detail [$tname $nentries outputs > 50]"

  names="$("$YQ" ea "$sel | [.spec.outputs[].fields[].name] | .[]" "$WORK/boot-templates.yaml")"
  dupes="$(printf '%s\n' "$names" | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dupes" ] || outputs_detail="$outputs_detail [$tname duplicate field name(s): $dupes]"

  bad="$(printf '%s\n' "$names" "$("$YQ" ea "$sel | [.spec.outputs[].name] | .[]" "$WORK/boot-templates.yaml")" \
    | { grep -vE '^[a-zA-Z][a-zA-Z0-9]{0,62}$' || true; } | tr '\n' ' ')"
  [ -z "$bad" ] || outputs_detail="$outputs_detail [$tname bad name(s): $bad]"

  # Per-entry field cap, keyTemplate on our own CRs, and the jsonPath shape.
  for i in $(seq 0 $((nentries - 1))); do
    e="$sel | .spec.outputs[$i]"
    nf="$("$YQ" ea "$e | .fields | length" "$WORK/boot-templates.yaml")"
    [ "$nf" -le 50 ] || outputs_detail="$outputs_detail [$tname outputs[$i] $nf fields > 50]"
    grp="$("$YQ" ea "$e | (.fromAll.apiVersion // .from.apiVersion)" "$WORK/boot-templates.yaml")"
    kt="$("$YQ" ea "$e | .keyTemplate // \"\"" "$WORK/boot-templates.yaml")"
    if [ "${grp%%/*}" = "security.mto.stakater.com" ] && \
       [ "$("$YQ" ea "$e | has(\"fromAll\")" "$WORK/boot-templates.yaml")" = "true" ] && [ -z "$kt" ]; then
      outputs_detail="$outputs_detail [$tname outputs[$i] fromAll on our CRs without keyTemplate]"
    fi
  done
done

while IFS='|' read -r fname jpath; do
  [ -n "$fname" ] || continue
  grep -qE '^\{[^{}]*\}$' <<<"$jpath" \
    || outputs_detail="$outputs_detail [$fname jsonPath is not a single {...}: $jpath]"
  case " $SCALAR_OK " in *" $fname "*) continue ;; esac
  grep -qE '\*|\.\.|\[\?' <<<"$jpath" \
    || outputs_detail="$outputs_detail [$fname is a scalar path: $jpath]"
done <<EOF
$("$YQ" ea -N 'select(.kind == "Template") | .spec.outputs[]?.fields[]? | .name + "|" + .jsonPath' "$WORK/boot-templates.yaml")
EOF

if [ -n "$outputs_detail" ]; then outputs_ok=1; fi
check outputs "$outputs_ok" "$outputs_detail"


# 18. appgrain — the KV boundary is the app, not the namespace. A bare
# <env>/<ns>/ own-prefix grant anywhere means an app can read and overwrite
# every other app in its namespace, which is the whole point of this layout.
# Also pins that bao.stakater.com/app is honoured (app-a resolves to `payments`)
# and that an SA without it falls back to its own name.
appgrain_bare="$("$YQ" ea -N 'select(.kind == "OpenBaoPolicy") | .spec.policy' "$WORK/all.yaml" \
  | { grep -E 'path "kv/(data|metadata|delete|undelete|destroy)/dev/team-a-(dev|tools)/\*"' || true; })"
appgrain_app="$("$YQ" ea -N 'select(.kind == "OpenBaoPolicy" and .metadata.name == "team-a-team-a-dev-app-a") | .spec.policy' "$WORK/all.yaml" \
  | { grep -c 'kv/data/dev/team-a-dev/payments/\*' || true; })"
appgrain_dflt="$("$YQ" ea -N 'select(.kind == "OpenBaoPolicy" and .metadata.name == "team-a-team-a-dev-app-c") | .spec.policy' "$WORK/all.yaml" \
  | { grep -c 'kv/data/dev/team-a-dev/app-c/\*' || true; })"
if [ -n "$appgrain_bare" ]; then
  check appgrain 1 "namespace-wide own-prefix grant found: $(printf '%s' "$appgrain_bare" | tr -s ' ' | head -1)"
elif [ "$appgrain_app" -eq 0 ]; then
  check appgrain 1 "bao.stakater.com/app not honoured — expected kv/data/dev/team-a-dev/payments/*"
elif [ "$appgrain_dflt" -eq 0 ]; then
  check appgrain 1 "app did not default to the ServiceAccount name for app-c"
else
  check appgrain 0
fi

# 19. rolename — the tier must not appear in a policy/role name. With it there, a
# tier edit renames the object, and a rename is delete-then-create: deleting a
# bao policy strips live tokens immediately and the workload's cached
# VAULT_K8S_ROLE then names a role that no longer exists.
rolename_bad="$("$YQ" ea -N 'select(.kind == "OpenBaoPolicy" or .kind == "OpenBaoKubernetesAuthRole") | .metadata.name' "$WORK/all.yaml" \
  | { grep -E -- '-(viewer|editor|admin|audit-read)$' || true; } | { grep -v '^sso-' || true; } | tr '\n' ' ')"
[ -z "$rolename_bad" ] && check rolename 0 || check rolename 1 "tier in object name: $rolename_bad"

# 20. transitmatch — every transit key a policy grants must be a key the chart
# actually creates. These are derived in different templates from different
# objects, so a divergence is silent: the workload gets permission denied on a
# key that does not exist, or a key is created that nothing can use and then
# stays in bao forever because OpenBaoTransitKey is orphan-by-design.
granted="$("$YQ" ea -N 'select(.kind == "OpenBaoPolicy") | .spec.policy' "$WORK/all.yaml" \
  | { grep -oE 'transit/encrypt/[a-z0-9-]+' || true; } | sed 's|transit/encrypt/||' | sort -u)"
created="$("$YQ" ea -N 'select(.kind == "OpenBaoTransitKey") | .spec.name' "$WORK/all.yaml" | sort -u)"
missing="$(comm -23 <(printf '%s\n' "$granted") <(printf '%s\n' "$created") | tr '\n' ' ')"
unused="$(comm -13 <(printf '%s\n' "$granted") <(printf '%s\n' "$created") | tr '\n' ' ')"
if [ -n "$missing" ]; then
  check transitmatch 1 "policy grants keys that are never created: $missing"
elif [ -n "$unused" ]; then
  check transitmatch 1 "keys created that no policy grants: $unused"
else
  check transitmatch 0
fi

# 21. guards — a misconfigured ServiceAccount is reported next to itself and does
# NOT stop the rest of the tenant rendering. One TemplateInstance renders every
# namespace a tenant owns, so a fail() would freeze unrelated namespaces; the
# chart emits bao-config-<sa>-error instead. Each broken SA must get exactly one
# error ConfigMap and no policy, and the valid SA in another namespace must still
# get its full object set.
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-guards.yaml" --set component=all > "$WORK/guards.yaml" 2>"$WORK/guards.err" \
  && guards_rendered=0 || guards_rendered=1
guards_detail=""
if [ "$guards_rendered" -ne 0 ]; then
  guards_detail="render failed outright — a per-SA mistake must not fail the tenant: $(head -1 "$WORK/guards.err")"
else
  broken="g-tier-only g-no-tier g-bad-tier g-empty-caps g-injection g-wildcard g-reserved g-claimed g-claimer g-orphan-share default g-foreign-ns g-unknown-key g-bad-bool"
  for sa in $broken; do
    n="$("$YQ" ea -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-$sa-error\") | .metadata.name" "$WORK/guards.yaml" | { grep -c . || true; })"
    [ "$n" -eq 1 ] || guards_detail="$guards_detail [no error ConfigMap for $sa]"
    p="$("$YQ" ea -N "select(.kind == \"OpenBaoPolicy\" and .metadata.name == \"team-a-team-a-dev-$sa\") | .metadata.name" "$WORK/guards.yaml" | { grep -c . || true; })"
    [ "$p" -eq 0 ] || guards_detail="$guards_detail [$sa was granted a policy despite being rejected]"
    c="$("$YQ" ea -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-$sa\") | .metadata.name" "$WORK/guards.yaml" | { grep -c . || true; })"
    [ "$c" -eq 0 ] || guards_detail="$guards_detail [$sa got a real bao-config ConfigMap]"
  done
  # the injection payload must never reach a rendered policy body
  sudo_leak="$("$YQ" ea -N 'select(.kind == "OpenBaoPolicy") | .spec.policy' "$WORK/guards.yaml" | { grep -c 'sudo' || true; })"
  [ "$sudo_leak" -eq 0 ] || guards_detail="$guards_detail [injected capability reached a policy body]"
  # and the unrelated namespace is untouched
  for kind in OpenBaoPolicy OpenBaoKubernetesAuthRole; do
    g="$("$YQ" ea -N "select(.kind == \"$kind\" and .metadata.name == \"team-a-team-a-prod-good-sa\") | .metadata.name" "$WORK/guards.yaml" | { grep -c . || true; })"
    [ "$g" -eq 1 ] || guards_detail="$guards_detail [valid SA in another namespace lost its $kind]"
  done
fi
[ -z "$guards_detail" ] && check guards 0 || check guards 1 "$guards_detail"

# 22. esdedupe — two Deployments sharing a ServiceAccount and asking for the same
# secret is a normal pattern (a service and its migration job). It must render
# ONE ExternalSecret, not fail: the rendered name is per-ServiceAccount, so both
# claim it. Two different asks under one name genuinely cannot be rendered and
# must be reported on both Deployments instead.
es_detail=""
dedupe="$("$YQ" ea -N 'select(.kind == "ExternalSecret" and .metadata.name == "good-sa-db") | .metadata.name' "$WORK/guards.yaml" | { grep -c . || true; })"
[ "$dedupe" -eq 1 ] || es_detail="$es_detail [identical asks rendered $dedupe ExternalSecrets, want 1]"
clash="$("$YQ" ea -N 'select(.kind == "ExternalSecret" and .metadata.name == "good-sa-cfg") | .metadata.name' "$WORK/guards.yaml" | { grep -c . || true; })"
[ "$clash" -eq 0 ] || es_detail="$es_detail [conflicting asks still rendered an ExternalSecret]"
for d in d-clash-a d-clash-b d-no-sa d-misplaced; do
  n="$("$YQ" ea -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-deploy-$d-error\") | .metadata.name" "$WORK/guards.yaml" | { grep -c . || true; })"
  [ "$n" -eq 1 ] || es_detail="$es_detail [no error ConfigMap for Deployment $d]"
done
[ -z "$es_detail" ] && check esdedupe 0 || check esdedupe 1 "$es_detail"


# 23. removedvalue — `defaultCapability` was deleted, and Helm ignores unknown
# values silently. A values file still setting it (a stale GitOps values, or
# `helm upgrade --reuse-values` carrying it forward) would therefore lose every
# grant it believes it is making. values.schema.json is deliberately permissive
# and has no additionalProperties:false, so the helper's fail() is the only
# defense; without this check a refactor of componentEnabled could drop it and
# nothing would go red.
removedvalue_out="$("$HELM" template "$RELEASE" "$CHART" -n "$NS" \
  -f "$FIXTURES/values-full.yaml" --set defaultCapability=none 2>&1 || true)"
if grep -q "defaultCapability was removed" <<<"$removedvalue_out"; then
  check removedvalue 0
else
  check removedvalue 1 "setting defaultCapability must fail the render with a migration message"
fi

# 24. uniqueids — no two objects in one slice may share (apiVersion, kind,
# namespace, name). The disjoint and union checks compare ACROSS slices and
# cannot see a duplicate inside one: it appears on both sides of the diff and
# cancels out. A within-slice duplicate silently applies last-wins, which for a
# transit key would mean two apps sharing crypto material.
uniqueids_detail=""
for c in all $SLICES; do
  render "$c" "$FIXTURES/values-full.yaml" > "$WORK/uid-$c.yaml" 2>/dev/null || continue
  dupes="$("$YQ" ea -N '[.apiVersion, .kind, (.metadata.namespace // "-"), .metadata.name] | join("|")' "$WORK/uid-$c.yaml" \
    | { grep -v '^null' || true; } | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dupes" ] || uniqueids_detail="$uniqueids_detail [$c: $dupes]"
done
# the guards fixture too — it renders the error-ConfigMap paths
render all "$FIXTURES/values-guards.yaml" > "$WORK/uid-guards.yaml" 2>/dev/null
dupes="$("$YQ" ea -N '[.apiVersion, .kind, (.metadata.namespace // "-"), .metadata.name] | join("|")' "$WORK/uid-guards.yaml" \
  | { grep -v '^null' || true; } | sort | uniq -d | tr '\n' ' ')"
[ -z "$dupes" ] || uniqueids_detail="$uniqueids_detail [guards: $dupes]"
[ -z "$uniqueids_detail" ] && check uniqueids 0 || check uniqueids 1 "duplicate object identity within a slice:$uniqueids_detail"

# 25. grantmatch — an ExternalSecret must never be rendered for a path the
# workload's policy does not grant. Both cases here produced a permanent silent
# 403 before: reading a sibling namespace's _shared/ without kv-subscribe-ns, and
# importing from a tenant absent from the roster. Positive controls sit alongside
# so the check cannot pass by rejecting everything.
grantmatch_detail=""
for d in d-sub-nogrant d-imp-bad; do
  n="$("$YQ" ea -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-deploy-$d-error\") | .metadata.name" "$WORK/uid-guards.yaml" | { grep -c . || true; })"
  [ "$n" -eq 1 ] || grantmatch_detail="$grantmatch_detail [no error ConfigMap for $d]"
done
for es in sub-ok-y good-sa-z; do
  n="$("$YQ" ea -N "select(.kind == \"ExternalSecret\" and .metadata.name == \"$es\") | .metadata.name" "$WORK/uid-guards.yaml" | { grep -c . || true; })"
  [ "$n" -eq 1 ] || grantmatch_detail="$grantmatch_detail [positive control $es did not render]"
done
# an app annotation with no engine registers nothing and must say so
n="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-config-g-app-only-error") | .metadata.name' "$WORK/uid-guards.yaml" | { grep -c . || true; })"
[ "$n" -eq 1 ] || grantmatch_detail="$grantmatch_detail [app-without-engine not reported]"
[ -z "$grantmatch_detail" ] && check grantmatch 0 || check grantmatch 1 "$grantmatch_detail"

# 26. esooff — with ESO disabled install-wide, a Deployment still asking for a
# secret must be told. The whole ExternalSecret file is gated on eso=enabled, so
# this report has to come from the core slice or it cannot exist at all.
esooff_out="$("$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-guards.yaml" \
  --set component=core --set eso=disabled 2>&1 || true)"
if grep -q "External Secrets Operator is disabled for this whole install" <<<"$esooff_out"; then
  check esooff 0
else
  check esooff 1 "eso=disabled must still report Deployments that request secrets"
fi

templateset_case defaults  enabled  false false openbao-config-mto openbao-config-mto-eso
templateset_case all-on    enabled  true  true  openbao-config-mto openbao-config-mto-eso openbao-config-mto-certmanager openbao-config-mto-trust
templateset_case all-off   disabled false false openbao-config-mto
templateset_case trust-only disabled false true openbao-config-mto openbao-config-mto-trust

exit "$fail"
