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
#  11b. rbacsplit  — OpenBao* CRs + child TIs: mutation verbs in a
#                    namespaced Role, ClusterRole holds exactly `list`
#                    (t-op-v2 orphan discovery). Complete atom sets pinned
#                    by equality, incl. a case where operatorNamespace
#                    differs from the release namespace.
#  11c. rbacpremise — pins the premise itself: those kinds render only
#                    into operatorNamespace and every Template targets it.
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
#  31. nullfields — no rendered field is YAML null when the tenant has no
#                    workload namespaces. Field-agnostic: a `key:` above an
#                    empty range is null, admission rejects it, and one such
#                    object fails the whole tenant's TemplateInstance.
#                    nullinputs (30) checks only that the render exits 0.
#  32. ssoredirect — sso.allowedRedirectUris emptied fails at render with the
#                    value named, rather than rendering a null bao rejects.
#  33. ssopkimount — every PKI path in every rendered policy names the
#                    EFFECTIVE tenant mount. §7 read pki.mountPath directly
#                    while the engine, CA and roles were at
#                    pki.hierarchy.mountPath, so every human SSO tier was
#                    granted paths on a mount that does not exist.
#  34. pkirolenames — two pki.roles entries rendering the same name fail the
#                    render (one would otherwise silently overwrite the other),
#                    and the schema rejects misspelled role keys — dropped
#                    silently, they leave bao's own, permissive, default.
#  35. pkicadomains — the tenant CA's permittedDnsDomains is never empty in
#                    hierarchy mode. An omitted field is not a null field, so
#                    nullfields (31) passes on an unconstrained CA, and the
#                    operator treats a present CA as final: empty is permanent.
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
# Skips are printed, never silent — a vanishing check reads as a passing one.
note_skip() { echo "SKIP  $1${2:+ — $2}"; }
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
# Render on its own line: inside a command substitution the exit status is lost,
# and a failed render then yields emptycount=0 — this check's pass condition.
if render certManager "$FIXTURES/values-no-optins.yaml" > "$WORK/empty.yaml" 2>"$WORK/empty.err"; then
  emptycount="$(normalize < "$WORK/empty.yaml" | grep -c '^kind:' || true)"
  [ "$emptycount" -eq 0 ] && check empty 0 || check empty 1 "expected 0 objects, got $emptycount"
else
  check empty 1 "render itself failed: $(head -2 "$WORK/empty.err" | tr '\n' ' ')"
fi

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

# RBAC rules are compared as fully-exploded atoms — one line per (apiGroup,
# resource, verb) — because authorization is the union of atoms, not rule
# factoring: a multi-group/multi-resource rule yields the same atoms as
# standalone rules, so no factoring hides a grant from exact-line asserts.
RBAC_ATOMS_Q='.rules[] as $r | $r.apiGroups[] as $g | $r.resources[] as $res | $r.verbs[] as $v
  | ($g + "/" + $res + " -> " + $v)'

rbac_rules() { # rbac_rules <eso> <certManager> <crossTenantPki> -> "group/resource -> verb" atoms
  "$HELM" template boot "$BOOTSTRAP" -n "$NS" \
    --set-string "parent.eso=$1" \
    --set-string "parent.certManager.enabled=$2" \
    --set-string "crossTenantPki.enabled=$3" \
    | "$YQ" "select(.kind == \"ClusterRole\" and .metadata.name == \"openbao-config-mto-manager\") | $RBAC_ATOMS_Q" - \
    | sort -u
}

# `create` on a kind that only an optional integration renders must exist only
# while that integration is switched on. Anything here that survives its toggle
# being off lets an engine that renders arbitrary charts mint new Issuers,
# Bundles, SecretStores, ServiceAccounts or RBAC cluster-wide.
# Keys are atoms; the core group renders empty, so its keys start with "/".
OPTIONAL_CREATE_GRANTS='external-secrets.io/secretstores -> create
external-secrets.io/externalsecrets -> create
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
TEARDOWN_GRANTS="$(
  for gr in external-secrets.io/secretstores external-secrets.io/externalsecrets \
            cert-manager.io/issuers trust.cert-manager.io/bundles \
            rbac.authorization.k8s.io/roles rbac.authorization.k8s.io/rolebindings; do
    for v in delete get list patch update watch; do echo "$gr -> $v"; done
  done
  for v in delete patch update; do echo "/serviceaccounts -> $v"; done
)"

grants_case() { # grants_case <test> <name> <eso> <cm> <ct> <present|absent> <atomlist>
  local test="$1" name="$2" eso="$3" cm="$4" ct="$5" mode="$6" list="$7"
  local got wrong="" n=0
  got="$(rbac_rules "$eso" "$cm" "$ct")"
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    n=$((n + 1))
    if grep -qxF "$g" <<<"$got"; then
      [ "$mode" = absent ] && wrong="$wrong [granted:$g]"
    else
      [ "$mode" = present ] && wrong="$wrong [missing:$g]"
    fi
  done <<EOF
$list
EOF
  # An emptied atom list iterates zero times and would pass vacuously.
  [ "$n" -ge 2 ] || wrong="$wrong [atom list has $n entries — mangled?]"
  [ -z "$wrong" ] \
    && check "$test:$name" 0 \
    || check "$test:$name" 1 "expected $mode, but:$wrong"
}

grants_case rbacscope all-off disabled false false absent  "$OPTIONAL_CREATE_GRANTS"
grants_case rbacscope all-on  enabled  true  true  present "$OPTIONAL_CREATE_GRANTS"

grants_case rbacteardown all-off disabled false false present "$TEARDOWN_GRANTS"
grants_case rbacteardown all-on  enabled  true  true  present "$TEARDOWN_GRANTS"

# 11b. rbacsplit — the OpenBao* CRs and child TemplateInstances render only
# into operatorNamespace: the ClusterRole holds exactly `list` on those two
# apiGroups (t-op-v2's orphan discovery lists rendered GVKs cluster-wide;
# without it TI teardown wedges) and a namespaced Role holds every other
# verb. Complete atom sets are pinned by equality: extra rules, wildcards,
# and multi-group rules all produce extra atoms and fail, on the Role too
# (operatorNamespace holds the token-reviewer Secret).
MOVED_GROUPS_RE='^(security\.mto\.stakater\.com|templates\.v2\.stakater\.com)/'
OPNS_KINDS='openbaonamespaces openbaosecretengines openbaopolicies openbaoauthmethods openbaokubernetesauthengineconfigs openbaokubernetesauthroles openbaojwtoidcauthengineconfigs openbaojwtoidcauthengineroles openbaotransitkeys openbaopkisecretengineconfigs openbaopkisecretengineroles'
EXPECTED_CR_MOVED="$(
  { for k in $OPNS_KINDS; do echo "security.mto.stakater.com/$k -> list"; done
    echo "templates.v2.stakater.com/templateinstances -> list"; } | sort
)"
EXPECTED_ROLE_RULES="$(
  { for k in $OPNS_KINDS; do
      for v in create delete get list patch update watch; do echo "security.mto.stakater.com/$k -> $v"; done
    done
    for v in create delete get list patch update watch; do echo "templates.v2.stakater.com/templateinstances -> $v"; done; } | sort
)"

# Guard against a vacuous pass: every assertion below compares against these
# atom sets (11 CR kinds + templateinstances = 12 list atoms; the same 12
# kinds x 7 verbs = 84 Role atoms), so an accidental emptying of either
# constant must itself fail.
[ "$(printf '%s\n' "$EXPECTED_CR_MOVED" | grep -c .)" -eq 12 ] \
  && [ "$(printf '%s\n' "$EXPECTED_ROLE_RULES" | grep -c .)" -eq 84 ] \
  && check "rbacsplit:selfcheck" 0 \
  || check "rbacsplit:selfcheck" 1 "expected atom sets must be 12 and 84 lines"

split_case() { # split_case <name> <operatorNamespace> <release-ns> [helm value args...]
  local name="$1" opns="$2" rns="$3"; shift 3
  local render got wrong=""
  render="$("$HELM" template boot "$BOOTSTRAP" -n "$rns" "$@")"

  got="$(printf '%s\n' "$render" \
    | "$YQ" "select(.kind == \"ClusterRole\" and .metadata.name == \"openbao-config-mto-manager\") | $RBAC_ATOMS_Q" - \
    | sort -u | grep -E "$MOVED_GROUPS_RE" || true)"
  [ "$got" = "$EXPECTED_CR_MOVED" ] \
    || wrong="$wrong [clusterrole atoms on moved groups: got ($(printf '%s' "$got" | tr '\n' ';'))]"

  # The Role is selected by name AND namespace: a Role rendered into any other
  # namespace is unreachable from the RoleBinding (roleRef resolves in the
  # binding's own namespace) and grants nothing.
  got="$(printf '%s\n' "$render" \
    | opns="$opns" "$YQ" "select(.kind == \"Role\" and .metadata.name == \"openbao-config-mto-manager\" and .metadata.namespace == env(opns)) | $RBAC_ATOMS_Q" - \
    | sort -u)"
  [ "$got" = "$EXPECTED_ROLE_RULES" ] \
    || wrong="$wrong [role in $opns: got ($(printf '%s' "$got" | tr '\n' ';'))]"

  got="$(printf '%s\n' "$render" \
    | opns="$opns" "$YQ" 'select(.kind == "RoleBinding" and .metadata.name == "openbao-config-mto-manager" and .metadata.namespace == env(opns))
             | .roleRef.kind + "/" + .roleRef.name + " <- " + .subjects[0].kind + ":" + .subjects[0].namespace + "/" + .subjects[0].name' -)"
  [ "$got" = "Role/openbao-config-mto-manager <- ServiceAccount:stakater-template-operator/template-operator-template-operator-v2" ] \
    || wrong="$wrong [rolebinding in $opns: got ($got)]"

  [ -z "$wrong" ] \
    && check "rbacsplit:$name" 0 \
    || check "rbacsplit:$name" 1 "$wrong"
}

split_case all-off "$NS" "$NS" --set-string parent.eso=disabled --set-string parent.certManager.enabled=false --set-string crossTenantPki.enabled=false
split_case all-on  "$NS" "$NS" --set-string parent.eso=enabled  --set-string parent.certManager.enabled=true  --set-string crossTenantPki.enabled=true
# operatorNamespace must place the pair, not the release namespace. The two
# default to the same string, so only a render where they differ can tell a
# correct reference from {{ .Release.Namespace }} standing in for the value.
split_case ns-override zz-operator-ns zz-release-ns --set-string operatorNamespace=zz-operator-ns

# The Role/RoleBinding pair renders byte-identically with every optional
# integration off and with all of them on: the pair carries teardown verbs, so
# no toggle may remove or reshape it. This asserts invariance and non-emptiness
# only — namespace, subject, and rule content are asserted by split_case.
role_pair_docs() { # role_pair_docs <eso> <certManager> <crossTenantPki>
  "$HELM" template boot "$BOOTSTRAP" -n "$NS" \
    --set-string "parent.eso=$1" \
    --set-string "parent.certManager.enabled=$2" \
    --set-string "crossTenantPki.enabled=$3" \
    | "$YQ" ea 'select((.kind == "Role" or .kind == "RoleBinding") and .metadata.name == "openbao-config-mto-manager")' -
}
if [ "$(role_pair_docs disabled false false)" = "$(role_pair_docs enabled true true)" ] \
   && [ -n "$(role_pair_docs disabled false false)" ]; then
  check "rbacsplit:toggle-invariant" 0
else
  check "rbacsplit:toggle-invariant" 1 "Role/RoleBinding differ across toggle sets (or render empty)"
fi

# 11c. rbacpremise — the premise the split stands on: the OpenBao* CRs render
# only into operatorNamespace, and every installed Template pins its render
# target there. A chart change rendering one CR into a tenant namespace makes
# the Role insufficient without touching any RBAC object, so this reads the
# render targets themselves — with operatorNamespace overridden away from the
# release namespace so the release namespace cannot stand in.
premise_crs="$("$HELM" template "$RELEASE" "$CHART" -n zz-release-ns -f "$FIXTURES/values-full.yaml" --set-string operatorNamespace=zz-operator-ns \
  | "$YQ" ea '[select(.apiVersion == "security.mto.stakater.com/v1alpha1") | .metadata.namespace] | unique | join(",")' -)"
premise_cr_count="$("$HELM" template "$RELEASE" "$CHART" -n zz-release-ns -f "$FIXTURES/values-full.yaml" --set-string operatorNamespace=zz-operator-ns \
  | "$YQ" ea '[select(.apiVersion == "security.mto.stakater.com/v1alpha1")] | length' -)"
[ "$premise_crs" = "zz-operator-ns" ] && [ "$premise_cr_count" -ge 5 ] \
  && check "rbacpremise:tenant-chart" 0 \
  || check "rbacpremise:tenant-chart" 1 "OpenBao CR namespaces [$premise_crs] (count $premise_cr_count), want only zz-operator-ns"

premise_tpl="$("$HELM" template boot "$BOOTSTRAP" -n zz-release-ns --set-string operatorNamespace=zz-operator-ns \
  | "$YQ" ea '[select(.kind == "Template") | .spec.targetNamespaces.explicit.allow.literal[]] | unique | join(",")' -)"
premise_tpl_count="$("$HELM" template boot "$BOOTSTRAP" -n zz-release-ns --set-string operatorNamespace=zz-operator-ns \
  | "$YQ" ea '[select(.kind == "Template")] | length' -)"
[ "$premise_tpl" = "zz-operator-ns" ] && [ "$premise_tpl_count" -ge 2 ] \
  && check "rbacpremise:template-targets" 0 \
  || check "rbacpremise:template-targets" 1 "Template targetNamespaces [$premise_tpl] (count $premise_tpl_count), want only zz-operator-ns"

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

# 15. pkimode — platformPki.mode is matched exactly against "intermediate", so
# any other value used to fall through to an ONLINE self-signed platform root
# with no error. Two guards reject it, each checked without the other so
# deleting either fails here instead of restoring the fall-through.
pkimode_ok=0; pkimode_detail=""
# a. the schema enum alone, templates stripped.
mkdir -p "$WORK/boot-pkimode-schema/templates"
cp "$BOOTSTRAP/Chart.yaml" "$BOOTSTRAP/values.yaml" "$BOOTSTRAP/values.schema.json" "$WORK/boot-pkimode-schema/"
printf '# intentionally empty\n' > "$WORK/boot-pkimode-schema/templates/noop.yaml"
for bad in Intermediate bogus ""; do
  if "$HELM" template boot "$WORK/boot-pkimode-schema" --set-string platformPki.mode="$bad" >/dev/null 2>&1; then
    pkimode_ok=1; pkimode_detail="$pkimode_detail [schema accepted mode=\"$bad\"]"
  fi
done
# b. the template fail() alone, schema removed.
cp -R "$BOOTSTRAP" "$WORK/boot-pkimode-noschema"
rm -f "$WORK/boot-pkimode-noschema/values.schema.json"
for bad in Intermediate bogus; do
  out="$("$HELM" template boot "$WORK/boot-pkimode-noschema" --set-string platformPki.mode="$bad" 2>&1 || true)"
  grep -q 'platformPki.mode must be' <<<"$out" \
    || { pkimode_ok=1; pkimode_detail="$pkimode_detail [no fail() guard for mode=\"$bad\"]"; }
  # The regression this exists for: a fall-through renders an online root.
  grep -qE '^\s+type: root' <<<"$out" \
    && { pkimode_ok=1; pkimode_detail="$pkimode_detail [mode=\"$bad\" rendered type: root]"; }
done
# c. both valid modes still render their own type.
for good in root intermediate; do
  out="$("$HELM" template boot "$BOOTSTRAP" --set-string platformPki.mode="$good" \
    --set-string platformPki.externalSignSecret=sec 2>&1 || true)"
  grep -qE "^\s+type: $good" <<<"$out" \
    || { pkimode_ok=1; pkimode_detail="$pkimode_detail [mode=$good did not render type: $good]"; }
done
[ "$pkimode_ok" -eq 0 ] && check pkimode 0 || check pkimode 1 "$pkimode_detail"

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
  # Zero entries is a failure, not a skip: status.outputs is the only working
  # hook for per-kind TI health, so a Template that stops emitting them loses
  # that signal silently.
  if [ "$nentries" -eq 0 ]; then
    outputs_detail="$outputs_detail [$tname has no spec.outputs — per-kind TI health is unreportable]"
    continue
  fi
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
# chart emits bao-config-<sa>.error instead. Each broken SA must get exactly one
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
    n="$("$YQ" ea -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-$sa.error\") | .metadata.name" "$WORK/guards.yaml" | { grep -c . || true; })"
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
  n="$("$YQ" ea -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-$d.deploy-error\") | .metadata.name" "$WORK/guards.yaml" | { grep -c . || true; })"
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
  dupes="$("$YQ" e -N '[.apiVersion, .kind, (.metadata.namespace // "-"), .metadata.name] | join("|")' "$WORK/uid-$c.yaml" \
    | { grep -v '^null' || true; } | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dupes" ] || uniqueids_detail="$uniqueids_detail [$c: $dupes]"
done
# the guards fixture too — it renders the error-ConfigMap paths
render all "$FIXTURES/values-guards.yaml" > "$WORK/uid-guards.yaml" 2>/dev/null
dupes="$("$YQ" e -N '[.apiVersion, .kind, (.metadata.namespace // "-"), .metadata.name] | join("|")' "$WORK/uid-guards.yaml" \
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
  n="$("$YQ" ea -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-$d.deploy-error\") | .metadata.name" "$WORK/uid-guards.yaml" | { grep -c . || true; })"
  [ "$n" -eq 1 ] || grantmatch_detail="$grantmatch_detail [no error ConfigMap for $d]"
done
for es in sub-ok-y good-sa-z; do
  n="$("$YQ" ea -N "select(.kind == \"ExternalSecret\" and .metadata.name == \"$es\") | .metadata.name" "$WORK/uid-guards.yaml" | { grep -c . || true; })"
  [ "$n" -eq 1 ] || grantmatch_detail="$grantmatch_detail [positive control $es did not render]"
done
# an app annotation with no engine registers nothing and must say so
n="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-config-g-app-only.error") | .metadata.name' "$WORK/uid-guards.yaml" | { grep -c . || true; })"
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

# 27. cohesion — the annotation-vocabulary contract. (a) A pre-rename Deployment
# key is told its NEW name, not just "unknown" — the rename is only cheap while
# every stale user gets pointed at the fix. (b) A dotted ServiceAccount name is
# rejected: every chart-reserved object-name suffix is dot-separated (.error,
# .deploy-error, .share-<peer>-bao), so dot-free workload names are what makes
# rendered names collision-free by construction. (c) bao-apps — the per-namespace
# app->path directory — renders from CORE only, keyed by resolved app name, and
# carries the secrets: leaves a seeder needs.
cohesion_detail=""
oldkey_msg="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-config-d-oldkey.deploy-error") | .data.ERROR' "$WORK/uid-guards.yaml")"
grep -q "was renamed to bao.stakater.com/kv-secret.db" <<<"$oldkey_msg" || cohesion_detail="$cohesion_detail [old spelling not told its new name]"
dotted="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-config-g.dotted.error") | .data.ERROR' "$WORK/uid-guards.yaml")"
grep -q "Rename the ServiceAccount" <<<"$dotted" || cohesion_detail="$cohesion_detail [dotted ServiceAccount name not rejected by G16]"
apps_core="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-apps" and .metadata.namespace == "team-a-dev") | .data.payments' "$WORK/uid-all.yaml")"
grep -q "kvPath: kv/data/dev/team-a-dev/payments/" <<<"$apps_core" || cohesion_detail="$cohesion_detail [bao-apps payments entry missing its kvPath]"
grep -q 'requestedSecrets: "app-config, db-creds"' <<<"$apps_core" || cohesion_detail="$cohesion_detail [bao-apps payments entry missing its requestedSecrets leaves]"
apps_eso="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-apps") | .metadata.name' "$WORK/uid-eso.yaml" | { grep -c . || true; })"
[ "$apps_eso" -eq 0 ] || cohesion_detail="$cohesion_detail [bao-apps leaked into the eso slice]"
# an errored SA still appears in the index, as a pointer to its error ConfigMap
apps_err="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-apps" and .metadata.namespace == "team-a-dev") | .data["g-tier-only.error"]' "$WORK/uid-guards.yaml")"
grep -q "bao-config-g-tier-only.error" <<<"$apps_err" || cohesion_detail="$cohesion_detail [errored SA has no pointer entry in bao-apps]"
# two Deployments sharing one SA and asking for the same leaf -> the leaf listed
# ONCE; the clash pair's leaves (one, two) still appear — both are genuinely
# requested and path-valid, the clash is about the Secret NAME and is reported
# on the Deployments themselves
apps_dedupe="$("$YQ" ea -N 'select(.kind == "ConfigMap" and .metadata.name == "bao-apps" and .metadata.namespace == "team-a-prod") | .data.good-sa' "$WORK/uid-guards.yaml")"
grep -q '^requestedSecrets: "one, postgres, two"$' <<<"$apps_dedupe" || cohesion_detail="$cohesion_detail [requestedSecrets leaves wrong — want deduped sorted 'one, postgres, two']"
[ -z "$cohesion_detail" ] && check cohesion 0 || check cohesion 1 "$cohesion_detail"

# 28. anndrift — charts/README.md and the templates must document the SAME
# annotation key set, both directions. The names have drifted twice already.
# ServiceAccount keys come from openbao.saAnnotationKeys; Deployment families
# are extracted from 05's hasPrefix checks, not hardcoded here — a template
# rename with a stale README is the drift this exists to catch. Every command
# substitution tolerates zero matches: under set -e a bare grep would kill the
# script and silently skip later checks.
README="$REPO_ROOT/charts/README.md"
anndrift_detail=""
sa_keys="$(awk '/define "openbao.saAnnotationKeys"/,/toYaml \$keys/' "$CHART/templates/_helpers.tpl" | { grep -oE '"[a-z0-9-]+"' || true; } | tr -d '"' | sort -u)"
[ -n "$sa_keys" ] || anndrift_detail=" [could not extract openbao.saAnnotationKeys from _helpers.tpl]"
dep_families="$({ grep -oE 'hasPrefix "(kv-[a-z0-9-]+)\.' "$CHART/templates/05-deployment-externalsecrets.yaml" || true; } | sed -E 's/hasPrefix "//; s/\.$//' | sort -u)"
[ -n "$dep_families" ] || anndrift_detail="$anndrift_detail [could not extract Deployment key families from 05]"
for k in $sa_keys; do
  # anchored: bare `kv` must not be satisfied by `kv-export-tenant`
  grep -qE "bao\.stakater\.com/$k([^a-z0-9.-]|\$)" "$README" || anndrift_detail="$anndrift_detail [template reads $k, README does not document it]"
done
for fam in $dep_families; do
  grep -q "bao\.stakater\.com/$fam\." "$README" || anndrift_detail="$anndrift_detail [template reads $fam.<name>, README does not document it]"
done
docd="$({ grep -oE 'bao\.stakater\.com/[a-z0-9.-]*[a-z0-9]' "$README" || true; } | sed 's|bao\.stakater\.com/||' | sort -u)"
for k in $docd; do
  base="${k%%.*}"
  if grep -qx "$base" <<<"$dep_families"; then
    continue  # a dotted family, with or without an example suffix
  fi
  grep -qx "$k" <<<"$sa_keys" || anndrift_detail="$anndrift_detail [README documents $k, no template reads it]"
done
[ -z "$anndrift_detail" ] && check anndrift 0 || check anndrift 1 "$anndrift_detail"

# 29. vardrift — same contract for the VAULT_* names the ConfigMaps publish, so
# nobody codes against a name that no longer renders. Rendered names come from
# the golden; dynamic per-peer families collapse to their prefix on both sides.
# VAULT_TOKEN is doc-only: the CLI examples use it, no ConfigMap renders it.
normalize_vars() {
  sed -E 's/^(VAULT_TRANSIT_IN_|VAULT_TRANSIT_OUT_|VAULT_FROM_|VAULT_IN_|VAULT_OUT_).*/\1/' | sort -u
}
vardrift_detail=""
rendered="$({ grep -oE '^\s+VAULT_[A-Z0-9_]+' "$FIXTURES/golden-all.yaml" || true; } | tr -d ' :' | normalize_vars)"
documented="$({ grep -oE 'VAULT_[A-Z0-9_]+' "$README" || true; } | normalize_vars | { grep -v '^VAULT_TOKEN$' || true; })"
[ -n "$rendered" ] || vardrift_detail=" [no VAULT_ names found in the golden — extraction broken]"
for v in $rendered; do
  grep -qx "$v" <<<"$documented" || vardrift_detail="$vardrift_detail [rendered $v not documented in README]"
done
for v in $documented; do
  grep -qx "$v" <<<"$rendered" || vardrift_detail="$vardrift_detail [README documents $v, nothing renders it]"
done
[ -z "$vardrift_detail" ] && check vardrift 0 || check vardrift 1 "$vardrift_detail"

# 31. hostileinputs — annotation VALUES are the only free-form user strings the
# chart interpolates. Each must become an error ConfigMap, never reach a
# rendered spec, and never forge fields — including inside the error ConfigMap
# reporting it (a raw newline once produced a top-level `spec:` there).
hostile_detail=""
for d in d-evil-key d-evil-leaf d-evil-name; do
  n="$("$YQ" e -N "select(.kind == \"ConfigMap\" and .metadata.name == \"bao-config-$d.deploy-error\") | .metadata.name" "$WORK/uid-guards.yaml" | { grep -c . || true; })"
  [ "$n" -eq 1 ] || hostile_detail="$hostile_detail [no error ConfigMap for $d]"
done
es_evil="$("$YQ" e -N 'select(.kind == "ExternalSecret") | .spec.dataFrom[0].extract.key // .spec.data[0].remoteRef.key' "$WORK/uid-guards.yaml" | { grep -c '\.\.' || true; })"
[ "$es_evil" -eq 0 ] || hostile_detail="$hostile_detail [a traversal path reached an ExternalSecret spec]"
forged="$("$YQ" e -N 'select(.kind == "ConfigMap") | keys | sort | join(",")' "$WORK/uid-guards.yaml" | { grep -v '^apiVersion,data,kind,metadata$' || true; } | tr '\n' ' ')"
[ -z "$forged" ] || hostile_detail="$hostile_detail [a ConfigMap grew unexpected top-level fields: $forged]"
[ -z "$hostile_detail" ] && check hostileinputs 0 || check hostileinputs 1 "$hostile_detail"

# 32. apiserver — decode every object through sigs.k8s.io/yaml (the apiserver's
# own path: YAML 1.1 via go-yaml v2) and run apimachinery's validators over
# names, labels and ConfigMap keys. yq cannot stand in: go-yaml v3 keeps `no` a
# string while the apiserver decodes it as a boolean, so an unquoted app name
# `no` fails a real apply yet passes every yq assertion.
if command -v go >/dev/null 2>&1; then
  apiserver_detail=""
  for fx in values-full values-guards; do
    # render-validate reports 0 problems on an empty file, so a failed render
    # would pass vacuously — same shape as the `empty` bug above.
    if ! render all "$FIXTURES/$fx.yaml" > "$WORK/api-$fx.yaml" 2>"$WORK/api-$fx.err"; then
      apiserver_detail="$apiserver_detail [$fx: render failed: $(head -2 "$WORK/api-$fx.err" | tr '\n' ' ')]"
      continue
    fi
    if ! out="$(cd "$REPO_ROOT" && GOFLAGS=-mod=mod go run ./hack/render-validate "$WORK/api-$fx.yaml" 2>&1)"; then
      # Line 1 carries infrastructure failures (READ-ERROR, missing go.mod), so
      # dropping it reports "[values-full: ]" with no cause.
      apiserver_detail="$apiserver_detail [$fx: $(printf '%s' "$out" | sed -n '1,3p' | tr '\n' ' ')]"
    fi
  done
  [ -z "$apiserver_detail" ] && check apiserver 0 || check apiserver 1 "$apiserver_detail"
else
  note_skip apiserver "go toolchain not found"
fi

# 30. nullinputs — the parent passes serviceAccounts/deployments straight from
# LIST resolutions that can be null; every consumer must ternary-guard. A crash
# here fails the whole tenant.
if "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  --set serviceAccounts=null --set deployments=null > "$WORK/null.yaml" 2>"$WORK/null.err"; then
  check nullinputs 0
else
  check nullinputs 1 "null serviceAccounts/deployments crashed the render: $(head -1 "$WORK/null.err")"
fi

# 31. nullfields — a successful render is not the assertion. With no workload
# namespaces every per-namespace list is empty, and a `key:` emitted above an
# empty range is YAML null, which admission rejects as "must be of type array".
# One invalid object fails the whole render's apply, so this takes out the
# tenant's entire TemplateInstance, not just the feature that produced the
# null — and a failed child TI emits no metric and no Event. nullinputs above
# passed throughout that bug: it only ever checked the exit status.
#
# Field-agnostic on purpose. Naming the two known sites would not catch the
# third, and this shape recurs wherever a list is built by ranging namespaces.
#
# The whole line is built INSIDE the generator, so a document with no nulls
# produces no result at all. The obvious form — identity + (generator) — is
# yq-version-dependent: `"str" + (empty)` yields nothing up to 4.44.x and yields
# "str" from 4.45 on, so on a newer yq every object was reported as an offender.
# That went unnoticed because a developer machine on the pinned YQ_VERSION
# (4.44.3) passed while CI, which resolves `yq` from PATH and so uses whatever
# the runner image ships (4.53.3), failed on every object. Hence the self-check
# below: it pins the detector's own behaviour, on any yq, before it is trusted.
nullfield_paths() { # nullfield_paths <manifest> -> "Kind/name spec.field" per null leaf
  "$YQ" e -N 'select(. != null) | . as $d | (.. | select(tag == "!!null") | ($d.kind + "/" + $d.metadata.name + " " + (path | join("."))))' "$1"
}
nf_detail=""
# Self-check first: a detector that cannot report is indistinguishable from a
# clean render, and a detector that reports everything is noise. Both directions
# are asserted against fixtures whose answer is known.
printf 'kind: Probe\nmetadata:\n  name: clean\nspec:\n  domains:\n    - a\n' > "$WORK/nf-clean.yaml"
printf 'kind: Probe\nmetadata:\n  name: dirty\nspec:\n  domains:\n' > "$WORK/nf-dirty.yaml"
nf_probe_clean="$(nullfield_paths "$WORK/nf-clean.yaml")" \
  || nf_detail="$nf_detail [self-check: yq failed on the clean probe]"
[ -z "$nf_probe_clean" ] \
  || nf_detail="$nf_detail [self-check: reported \"$nf_probe_clean\" on a manifest with no null field — every finding below would be a false positive; check the yq build ($("$YQ" --version 2>&1 | tr -d '\n'))]"
nf_probe_dirty="$(nullfield_paths "$WORK/nf-dirty.yaml")" \
  || nf_detail="$nf_detail [self-check: yq failed on the dirty probe]"
[ "$nf_probe_dirty" = "Probe/dirty spec.domains" ] \
  || nf_detail="$nf_detail [self-check: a known null field reported as \"$nf_probe_dirty\", want \"Probe/dirty spec.domains\" — the detector cannot see nulls, so a clean result below means nothing]"
for nf in "null-inputs:$WORK/null.yaml" "no-workloads:$WORK/noworkloads.yaml"; do
  nf_label="${nf%%:*}"; nf_file="${nf#*:}"
  if [ "$nf_label" = no-workloads ]; then
    # Rendered here rather than reused: values-no-workloads.yaml is the fixture
    # that also turns on pki.hierarchy, the only path that emits
    # permittedDnsDomains — the second empty-list site.
    "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-no-workloads.yaml" \
      --set component=all > "$nf_file" 2>"$WORK/noworkloads.err" \
      || { nf_detail="$nf_detail [$nf_label: render failed: $(head -1 "$WORK/noworkloads.err")]"; continue; }
  fi
  # Own line, then check the status: $(...) would discard a yq failure and the
  # empty result would read as "no null fields".
  nf_out="$(nullfield_paths "$nf_file")" \
    || { nf_detail="$nf_detail [$nf_label: yq failed: $(printf '%s' "$nf_out" | head -1)]"; continue; }
  [ -n "$nf_out" ] \
    && nf_detail="$nf_detail [$nf_label: $(printf '%s' "$nf_out" | sort -u | tr '\n' ' ')]"
done
[ -z "$nf_detail" ] && check nullfields 0 \
  || check nullfields 1 "rendered null field(s) — admission rejects these and fails the whole TI:$nf_detail"

# 32. ssoredirect — every §7 role is roleType=oidc, for which bao requires a
# non-empty allowed_redirect_uris. Emptied in values it rendered as YAML null
# and failed admission for the whole tenant. Failing at render names the value
# instead; unlike the PKI namespace window no cluster state resolves it, so a
# guard is right here and a `with` would be wrong.
#
# Both empty forms come from a VALUES FILE, not --set: `--set x=[]` gives helm
# the STRING "[]", so the guard never runs, the render dies in the range, and Go
# embeds the variable path in that error — which the grep below then matched,
# passing while asserting nothing.
ssor_ok=0; ssor_detail=""
printf 'sso:\n  allowedRedirectUris: []\n'   > "$WORK/ssor-empty.yaml"
printf 'sso:\n  allowedRedirectUris: null\n' > "$WORK/ssor-null.yaml"
for ssor_form in empty null; do
  # Render on its own line so the exit status survives: inside $(...) a failed
  # render is indistinguishable from a clean one, and "it printed the value
  # name" alone would also pass on a manifest that merely contains the key.
  if "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
    -f "$WORK/ssor-$ssor_form.yaml" --set component=core > "$WORK/ssor.out" 2>&1; then
    ssor_ok=1; ssor_detail="$ssor_detail [allowedRedirectUris=$ssor_form rendered instead of failing]"
    continue
  fi
  # The guard's own sentence, not the value name: the value name alone also
  # appears in the Go template error this check used to pass on.
  grep -q 'requires at least one entry in sso.allowedRedirectUris' "$WORK/ssor.out" \
    || { ssor_ok=1; ssor_detail="$ssor_detail [allowedRedirectUris=$ssor_form failed somewhere other than the guard: $(head -1 "$WORK/ssor.out" | cut -c1-90)]"; }
done
# The counterweight: a populated list must still render the roles. Without this
# the guard could reject everything and still "pass" above.
ssor_out="$("$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  --set component=core 2>&1 || true)"
# The VALUE, not the key: §7 emits `allowedRedirectUris:` unconditionally above
# its range, so grepping the key matches even when the range emits nothing —
# which is the YAML-null-that-fails-admission this check family exists to catch.
grep -qE '^\s+- "http://localhost:8250/oidc/callback"' <<<"$ssor_out" \
  || { ssor_ok=1; ssor_detail="$ssor_detail [a populated sso.allowedRedirectUris rendered no URI entries]"; }
[ "$ssor_ok" -eq 0 ] && check ssoredirect 0 || check ssoredirect 1 "$ssor_detail"

# 33. ssopkimount — every PKI path in every rendered policy names the EFFECTIVE
# tenant mount (openbao.pkiMount), not pki.mountPath. §7 read the raw value
# while §3/§4/§10 went through the helper, so with the default
# pki.hierarchy.enabled=true the human SSO tiers were granted paths under `pki`
# while the engine, the CA and the roles all lived at `pki-int`: every SSO tier
# silently had no PKI access at all. It
# rendered, it validated, and the golden carried it.
#
# Checked by prefix across the whole render, not by asserting §7's text, so the
# same drift in any other template fails here too.
spm_ok=0; spm_detail=""
# Any policy line that is unmistakably a PKI path, whatever mount it claims.
# No `sign/`: transit has a sign endpoint too, so that tail cannot tell the two
# mounts apart. The stale-mount assertion below covers the sign grants instead.
PKI_PATH_TAILS='ca/pem|ca_chain|cert/ca|certs|cert/[+]|issue/|roles|root|root/|intermediate/|issuers|issuer/'
pki_path_prefixes() { # <manifest> -> one mount prefix per PKI path line
  # The mount is everything between `path "` and the first PKI-specific tail,
  # so this reads the prefix off the render itself rather than being told it.
  # `#` as the s delimiter, not `|`: the tails are an alternation, and a `|`
  # delimiter ends the pattern at the first branch ("parentheses not balanced").
  grep -oE "path \"[^\"]+/($PKI_PATH_TAILS)" "$1" \
    | sed -E "s#^path \"##; s#/($PKI_PATH_TAILS)\$##" \
    | sort -u
}
for posture in "true:pki-int:pki" "false:pki:pki-int"; do
  spm_hier="${posture%%:*}"; spm_rest="${posture#*:}"
  spm_want="${spm_rest%%:*}"; spm_stale="${spm_rest#*:}"
  "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
    --set component=core --set "pki.hierarchy.enabled=$spm_hier" > "$WORK/spm.out" 2>&1 \
    || { spm_ok=1; spm_detail="$spm_detail [hierarchy=$spm_hier render failed: $(head -1 "$WORK/spm.out" | cut -c1-90)]"; continue; }
  # a. the inactive mount is granted nowhere. This is the actual regression: the
  # grants named a mount that holds nothing.
  if grep -q "path \"$spm_stale/" "$WORK/spm.out"; then
    spm_ok=1
    spm_detail="$spm_detail [hierarchy=$spm_hier grants paths on the inactive mount $spm_stale: $(grep -oE "path \"$spm_stale/[^\"]*" "$WORK/spm.out" | sort -u | head -3 | tr '\n' ' ')]"
  fi
  # b. and every PKI path that can be attributed to a mount uses the live one.
  spm_got="$(pki_path_prefixes "$WORK/spm.out")" \
    || { spm_ok=1; spm_detail="$spm_detail [hierarchy=$spm_hier: prefix scan failed]"; continue; }
  # Non-empty first: "no PKI paths at all" must not read as "no wrong prefixes".
  [ -n "$spm_got" ] \
    || { spm_ok=1; spm_detail="$spm_detail [hierarchy=$spm_hier rendered no PKI policy paths]"; continue; }
  [ "$spm_got" = "$spm_want" ] \
    || { spm_ok=1; spm_detail="$spm_detail [hierarchy=$spm_hier: PKI paths under $(printf '%s' "$spm_got" | tr '\n' ',' | sed 's/,$//'), want only $spm_want]"; }
done
# The mount the SSO tiers actually got, pinned by name: the prefix check above
# would still pass if §7 dropped its PKI block entirely.
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  --set component=core > "$WORK/spm-sso.out" 2>&1 \
  && grep -q 'path "pki-int/ca/pem"           { capabilities = \["read"\] }' "$WORK/spm-sso.out" \
  || { spm_ok=1; spm_detail="$spm_detail [no SSO-tier PKI grant at the effective mount]"; }
[ "$spm_ok" -eq 0 ] && check ssopkimount 0 || check ssopkimount 1 "$spm_detail"

# 34. pkirolenames — two pki.roles entries that render the same name fail the
# render. The name is the bao role, the CR name and the cert-manager Issuer
# name, so a collision emitted two same-named objects with different specs from
# one render: helm accepts it, server-side apply keeps the last, and the other
# entry's TTL and flags disappear with no error, no failed TI and no Event.
#
# Guarded in two independent places, each checked with the other removed:
# the template fail() (schema stripped) and the schema's own key constraints.
prn_ok=0; prn_detail=""
cat > "$WORK/roles-dup.yaml" <<'YAML'
pki:
  roles:
    - nameTemplate: "{tenant}-svc"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
      ttl: "1h"
    - nameTemplate: "{tenant}-svc"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
      ttl: "999h"
YAML
cp -R "$CHART" "$WORK/chart-noschema-roles"
rm -f "$WORK/chart-noschema-roles/values.schema.json"
# a. the template guard, with the schema gone. Rendered per component because
# each slice is its own TemplateInstance: certManager iterates pki.roles
# without §3, so a guard living only in §3 would let the collision through
# there. core covers §3/§4, certManager covers §10.
for prn_comp in core certManager; do
  if "$HELM" template "$RELEASE" "$WORK/chart-noschema-roles" -n "$NS" \
    -f "$FIXTURES/values-full.yaml" -f "$WORK/roles-dup.yaml" \
    --set component=$prn_comp > "$WORK/prn.out" 2>&1; then
    prn_ok=1; prn_detail="$prn_detail [component=$prn_comp rendered a duplicate role name instead of failing]"
    continue
  fi
  grep -q 'both render the role name' "$WORK/prn.out" \
    || { prn_ok=1; prn_detail="$prn_detail [component=$prn_comp failed without naming the collision: $(head -1 "$WORK/prn.out" | cut -c1-90)]"; }
done
# b. a missing nameTemplate names the entry instead of dying in a helper.
cat > "$WORK/roles-noname.yaml" <<'YAML'
pki:
  roles:
    - allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
YAML
if "$HELM" template "$RELEASE" "$WORK/chart-noschema-roles" -n "$NS" \
  -f "$FIXTURES/values-full.yaml" -f "$WORK/roles-noname.yaml" \
  --set component=core > "$WORK/prn-nn.out" 2>&1; then
  prn_ok=1; prn_detail="$prn_detail [a role with no nameTemplate rendered]"
else
  grep -q 'has no nameTemplate' "$WORK/prn-nn.out" \
    || { prn_ok=1; prn_detail="$prn_detail [missing nameTemplate failed without naming the field: $(head -1 "$WORK/prn-nn.out" | cut -c1-90)]"; }
fi
# c. the schema alone, on the typos the template cannot see: an unknown key is
# omitted from the CR, so bao keeps its own default — permissive for
# allow_ip_sans and require_cn — and the render stays clean.
cat > "$WORK/roles-typo.yaml" <<'YAML'
pki:
  roles:
    - nameTemplate: "{tenant}-svc"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
      allowedDomainTemplate: ["typo"]
      maxTTL: "720h"
      allowIpSANs: true
YAML
if "$HELM" template "$RELEASE" "$CHART" -n "$NS" \
  -f "$FIXTURES/values-full.yaml" -f "$WORK/roles-typo.yaml" \
  --set component=core > "$WORK/prn-typo.out" 2>&1; then
  prn_ok=1; prn_detail="$prn_detail [schema accepted misspelled role keys]"
else
  for prn_key in allowedDomainTemplate maxTTL allowIpSANs; do
    grep -q "$prn_key" "$WORK/prn-typo.out" \
      || { prn_ok=1; prn_detail="$prn_detail [schema rejection did not name $prn_key]"; }
  done
fi
# d. a name the apiserver would reject fails at render. One rejected object
# fails the whole apply — the tenant's entire TI, no metric and no Event.
# Uniqueness alone never looked at the characters.
cat > "$WORK/roles-badname.yaml" <<'YAML'
pki:
  roles:
    - nameTemplate: "{tenant}_SVC"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
YAML
if "$HELM" template "$RELEASE" "$WORK/chart-noschema-roles" -n "$NS" \
  -f "$FIXTURES/values-full.yaml" -f "$WORK/roles-badname.yaml" \
  --set component=core > "$WORK/prn-bn.out" 2>&1; then
  prn_ok=1; prn_detail="$prn_detail [an RFC 1123-invalid role name rendered]"
else
  grep -q "CRD rejects for spec.name" "$WORK/prn-bn.out" \
    || { prn_ok=1; prn_detail="$prn_detail [invalid role name failed for another reason: $(head -1 "$WORK/prn-bn.out" | cut -c1-90)]"; }
fi
# e. same for the 253-char limit.
{ printf 'pki:\n  roles:\n    - nameTemplate: "{tenant}-'; \
  head -c 250 < /dev/zero | tr '\0' 'a'; \
  printf '"\n      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]\n'; \
} > "$WORK/roles-longname.yaml"
if "$HELM" template "$RELEASE" "$WORK/chart-noschema-roles" -n "$NS" \
  -f "$FIXTURES/values-full.yaml" -f "$WORK/roles-longname.yaml" \
  --set component=core > "$WORK/prn-ln.out" 2>&1; then
  prn_ok=1; prn_detail="$prn_detail [a 253+ char role name rendered]"
else
  grep -q 'over the 253-char' "$WORK/prn-ln.out" \
    || { prn_ok=1; prn_detail="$prn_detail [over-long role name failed for another reason: $(head -1 "$WORK/prn-ln.out" | cut -c1-90)]"; }
fi
# g. the pki.roles value constraints MIRROR the operator's CRD. A values schema
# looser than the CRD is worse than none: the value renders clean and the
# apiserver rejects the object. Both cases shipped once — a bare-integer ttl
# (valid to bao's parser, rejected by the CRD) and keyBits over the CRD maximum.
cat > "$WORK/roles-crdmismatch.yaml" <<'YAML'
pki:
  roles:
    - nameTemplate: "{tenant}-svc"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
      ttl: "3600"
YAML
cat > "$WORK/roles-keybits.yaml" <<'YAML'
pki:
  roles:
    - nameTemplate: "{tenant}-svc"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
      keyBits: 16384
YAML
for prn_case in crdmismatch:ttl keybits:keyBits; do
  prn_file="$WORK/roles-${prn_case%%:*}.yaml"; prn_key="${prn_case##*:}"
  # Against the REAL chart: this one is the schema's job, not a template fail().
  if "$HELM" template "$RELEASE" "$CHART" -n "$NS" \
    -f "$FIXTURES/values-full.yaml" -f "$prn_file" \
    --set component=core > "$WORK/prn-crd.out" 2>&1; then
    prn_ok=1; prn_detail="$prn_detail [$prn_key outside the operator CRD's constraint rendered — it would be rejected at apply]"
  else
    grep -q "$prn_key" "$WORK/prn-crd.out" \
      || { prn_ok=1; prn_detail="$prn_detail [$prn_key rejection did not name the field: $(head -1 "$WORK/prn-crd.out" | cut -c1-90)]"; }
  fi
done
# f. counterweight: two DISTINCT names still render two roles. Without this the
# guard could reject every multi-role catalog and still pass above.
cat > "$WORK/roles-ok.yaml" <<'YAML'
pki:
  roles:
    - nameTemplate: "{tenant}-svc"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
    - nameTemplate: "{tenant}-client"
      allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
YAML
prn_n="$("$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  -f "$WORK/roles-ok.yaml" --set component=core 2>/dev/null \
  | grep -c '^kind: OpenBaoPKISecretEngineRole' || true)"
[ "$prn_n" = 2 ] \
  || { prn_ok=1; prn_detail="$prn_detail [two distinct role names rendered $prn_n roles, want 2]"; }
# h. blast radius: the guards must fail the slices that RENDER PKI and only
# those. §04 renders core and eso, so an unqualified call there hard-failed the
# tenant's ESO SecretStores over a PKI-only typo.
for prn_slice in core certManager; do
  "$HELM" template "$RELEASE" "$WORK/chart-noschema-roles" -n "$NS" \
    -f "$FIXTURES/values-full.yaml" -f "$WORK/roles-dup.yaml" \
    --set component=$prn_slice > /dev/null 2>&1 \
    && { prn_ok=1; prn_detail="$prn_detail [component=$prn_slice renders PKI but did not catch a duplicate role name]"; }
done
"$HELM" template "$RELEASE" "$WORK/chart-noschema-roles" -n "$NS" \
  -f "$FIXTURES/values-full.yaml" -f "$WORK/roles-dup.yaml" \
  --set component=eso > "$WORK/prn-eso.out" 2>&1 \
  || { prn_ok=1; prn_detail="$prn_detail [a PKI-only role-catalog error failed the eso slice, taking out KV secret delivery: $(head -1 "$WORK/prn-eso.out" | cut -c1-90)]"; }
# and the eso slice still rendered its own objects rather than going quietly empty
grep -q '^kind:' "$WORK/prn-eso.out" \
  || { prn_ok=1; prn_detail="$prn_detail [the eso slice rendered nothing at all under a PKI typo]"; }
[ "$prn_ok" -eq 0 ] && check pkirolenames 0 || check pkirolenames 1 "$prn_detail"

# 35. pkicadomains — the tenant CA is never created without name constraints,
# in EITHER mode, and never created before the constraints can be right.
#
# Not covered by nullfields (31): an OMITTED field is not a null field, so the
# render was clean and admission was happy while the CA went out unconstrained.
# The operator treats a present CA as final ("A present CA is final for both
# root and intermediate"), so that is permanent for that tenant — the next
# render cannot repair it, and an unconstrained tenant CA is accepted for any
# other tenant's name by every peer that trusts it. The role's allowedDomains is
# the opposite case and is deliberately left omittable: bao fails an empty role
# closed and the next render fills it in.
pcd_ok=0; pcd_detail=""
pcd_dom() { # <manifest> -> permittedDnsDomains entries of the tenant CA
  "$YQ" e -N 'select(.kind == "OpenBaoPKISecretEngineConfig" and .metadata.name == "team-a-pki-root")
              | .spec.permittedDnsDomains // [] | .[]' "$1"
}
pcd_kinds() { # <manifest> -> sorted kind list
  "$YQ" e -N 'select(.kind) | .kind' "$1" | sort -u
}
# a. the zero-labelled-namespace window: NO CA at all. The only constraint
# derivable there is the templates' literal suffix — cluster-wide by default —
# and a final CA would keep it forever.
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-no-workloads.yaml" \
  --set component=core > "$WORK/pcd-empty.out" 2>&1 \
  || { pcd_ok=1; pcd_detail="$pcd_detail [no-workloads render failed: $(head -1 "$WORK/pcd-empty.out" | cut -c1-90)]"; }
grep -q '^kind: OpenBaoPKISecretEngineConfig' "$WORK/pcd-empty.out" \
  && { pcd_ok=1; pcd_detail="$pcd_detail [no-workloads emitted a CA: constraints \"$(pcd_dom "$WORK/pcd-empty.out" | tr '\n' ',')\" would be frozen cluster-wide]"; }
# and the counterweight, or "emitted nothing at all" would be the pass path: the
# mount and the role still render, so the CA is what waits, not the whole slice.
for pcd_want in OpenBaoSecretEngine OpenBaoPKISecretEngineRole; do
  pcd_kinds "$WORK/pcd-empty.out" | grep -qx "$pcd_want" \
    || { pcd_ok=1; pcd_detail="$pcd_detail [no-workloads dropped $pcd_want too — the CA alone should wait]"; }
done
# b. with namespaces, the per-namespace union, and the CA appears.
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  --set component=core > "$WORK/pcd-full.out" 2>&1 \
  || { pcd_ok=1; pcd_detail="$pcd_detail [values-full render failed]"; }
pcd_full="$(pcd_dom "$WORK/pcd-full.out")" \
  || { pcd_ok=1; pcd_detail="$pcd_detail [yq failed on the values-full render]"; }
[ -n "$pcd_full" ] \
  || { pcd_ok=1; pcd_detail="$pcd_detail [populated tenant rendered no CA constraints]"; }
grep -qx 'svc.cluster.local' <<<"$pcd_full" \
  && { pcd_ok=1; pcd_detail="$pcd_detail [populated tenant fell back to a bare suffix instead of its namespaces]"; }
# c. root mode is constrained too: under pki.crossTenant a peer trusts a
# self-signed root directly, so nothing above it bounds an unconstrained one.
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  --set component=core --set pki.hierarchy.enabled=false > "$WORK/pcd-root.out" 2>&1 \
  || { pcd_ok=1; pcd_detail="$pcd_detail [root-mode render failed: $(head -1 "$WORK/pcd-root.out" | cut -c1-90)]"; }
pcd_root="$(pcd_dom "$WORK/pcd-root.out")"
[ -n "$pcd_root" ] \
  || { pcd_ok=1; pcd_detail="$pcd_detail [root mode rendered a CA with no permittedDnsDomains]"; }
"$YQ" e -N 'select(.kind == "OpenBaoPKISecretEngineConfig") | .spec.type' "$WORK/pcd-root.out" \
  | grep -qx root || { pcd_ok=1; pcd_detail="$pcd_detail [root-mode fixture did not render a type=root CA]"; }
# d. a catalog that yields no domain for any namespace cannot constrain the CA,
# so it fails at render rather than emitting an unconstrained one.
cat > "$WORK/roles-nodomains.yaml" <<'YAML'
pki:
  roles:
    - nameTemplate: "{tenant}-svc"
      allowedDomainsTemplate: []
YAML
# Reuses pkirolenames' schema-stripped tree rather than making a second identical
# copy — two copies drift the moment one changes how the schema is bypassed.
if "$HELM" template "$RELEASE" "$WORK/chart-noschema-roles" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  -f "$WORK/roles-nodomains.yaml" --set component=core > "$WORK/pcd-nd.out" 2>&1; then
  pcd_ok=1; pcd_detail="$pcd_detail [a catalog with no allowedDomainsTemplate rendered an unconstrained CA]"
else
  grep -q 'no DNS name constraints' "$WORK/pcd-nd.out" \
    || { pcd_ok=1; pcd_detail="$pcd_detail [empty domain catalog failed without explaining why: $(head -1 "$WORK/pcd-nd.out" | cut -c1-90)]"; }
fi
# e. an omitted pki.hierarchy renders root mode, as openbao.pkiMount reads it.
# A chained deref on the absent block nil-pointers the whole core TI instead.
printf 'pki:\n  hierarchy: null\n' > "$WORK/pcd-nilhier.yaml"
if "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  -f "$WORK/pcd-nilhier.yaml" --set component=core > "$WORK/pcd-nh.out" 2>&1; then
  "$YQ" e -N 'select(.kind == "OpenBaoPKISecretEngineConfig") | .spec.type' "$WORK/pcd-nh.out" \
    | grep -qx root \
    || { pcd_ok=1; pcd_detail="$pcd_detail [a null pki.hierarchy did not render root mode]"; }
else
  pcd_ok=1; pcd_detail="$pcd_detail [a null pki.hierarchy failed the render: $(head -1 "$WORK/pcd-nh.out" | cut -c1-90)]"
fi
# f. §11's Bundle waits for the same window: its first source is <tenant>-ca,
# which only the CA publishes, and its target selects this tenant's namespaces.
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-no-workloads.yaml" \
  --set component=trust --set pki.crossTenant.enabled=true > "$WORK/pcd-tr0.out" 2>&1 \
  || { pcd_ok=1; pcd_detail="$pcd_detail [no-workloads trust render failed]"; }
grep -q '^kind: Bundle' "$WORK/pcd-tr0.out" \
  && { pcd_ok=1; pcd_detail="$pcd_detail [no-workloads emitted a Bundle sourcing a CA that does not exist yet]"; }
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  --set component=trust --set pki.crossTenant.enabled=true > "$WORK/pcd-tr1.out" 2>&1 \
  || { pcd_ok=1; pcd_detail="$pcd_detail [values-full trust render failed]"; }
grep -q '^kind: Bundle' "$WORK/pcd-tr1.out" \
  || { pcd_ok=1; pcd_detail="$pcd_detail [a populated tenant rendered no Bundle — the window gate is too wide]"; }
[ "$pcd_ok" -eq 0 ] && check pkicadomains 0 || check pkicadomains 1 "$pcd_detail"

# 36. parentplumb — the bootstrap passes the install-wide tenant knobs down its
# child valuesTemplate. Both default to [], so without this the `with` branches
# render in ZERO passes and a wrong nindent or nesting level ships green,
# surfacing only as a failed child TI per tenant (no metric, no Event).
# Parsed as YAML, not grepped, so "contains the key" cannot pass.
pp_ok=0; pp_detail=""
cat > "$WORK/parent-plumb.yaml" <<'YAML'
parent:
  pki:
    roles:
      - nameTemplate: "{tenant}-client"
        allowedDomainsTemplate: ["{namespace}.svc.cluster.local"]
        ttl: "24h"
        serverFlag: false
  sso:
    allowedRedirectUris:
      - "https://console.example.com/oidc/callback"
YAML
"$HELM" template "$RELEASE" "$BOOTSTRAP" -n "$NS" -f "$WORK/parent-plumb.yaml" \
  > "$WORK/pp.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [bootstrap render failed: $(head -1 "$WORK/pp.out" | cut -c1-90)]"; }
# The core child Template's valuesTemplate, parsed as the YAML the tenant chart
# will receive. The gotemplate placeholders are scalars, so this parses.
"$YQ" e -N 'select(.kind == "Template" and .metadata.name == "openbao-config-mto")
            | .spec.helm.valuesTemplate' "$WORK/pp.out" > "$WORK/pp-values.yaml" 2>/dev/null \
  || { pp_ok=1; pp_detail="$pp_detail [could not extract the core valuesTemplate]"; }
pp_get() { "$YQ" e -N "$1" "$WORK/pp-values.yaml" 2>/dev/null; }
[ "$(pp_get '.pki.roles | length')" = 1 ] \
  || { pp_ok=1; pp_detail="$pp_detail [parent.pki.roles did not reach the child values as a 1-entry list: got '$(pp_get '.pki.roles | length')']"; }
[ "$(pp_get '.pki.roles[0].nameTemplate')" = '{tenant}-client' ] \
  || { pp_ok=1; pp_detail="$pp_detail [role nameTemplate wrong: '$(pp_get '.pki.roles[0].nameTemplate')']"; }
[ "$(pp_get '.pki.roles[0].serverFlag')" = false ] \
  || { pp_ok=1; pp_detail="$pp_detail [a false pass-through field was lost: serverFlag='$(pp_get '.pki.roles[0].serverFlag')']"; }
[ "$(pp_get '.sso.allowedRedirectUris[0]')" = 'https://console.example.com/oidc/callback' ] \
  || { pp_ok=1; pp_detail="$pp_detail [sso.allowedRedirectUris did not reach the child values]"; }
# The plumbed values must survive the tenant chart too, not just parse here.
"$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" \
  -f <("$YQ" e -N '{"pki": {"roles": .pki.roles}, "sso": {"allowedRedirectUris": .sso.allowedRedirectUris}}' "$WORK/pp-values.yaml") \
  --set component=core > "$WORK/pp-tenant.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [tenant chart rejected the plumbed values: $(head -1 "$WORK/pp-tenant.out" | cut -c1-90)]"; }
grep -q 'name: pki-team-a-client' "$WORK/pp-tenant.out" \
  || { pp_ok=1; pp_detail="$pp_detail [plumbed role did not render in the tenant chart]"; }
# Counterweight: left at its default the block is OMITTED, not emitted empty —
# an empty pki.roles would trip the tenant chart's own guard for every tenant.
"$HELM" template "$RELEASE" "$BOOTSTRAP" -n "$NS" > "$WORK/pp-def.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [default bootstrap render failed]"; }
"$YQ" e -N 'select(.kind == "Template" and .metadata.name == "openbao-config-mto")
            | .spec.helm.valuesTemplate' "$WORK/pp-def.out" > "$WORK/pp-defvals.yaml" 2>/dev/null
"$YQ" e -N 'has("pki") and (.pki | has("roles"))' "$WORK/pp-defvals.yaml" 2>/dev/null | grep -qx false \
  || { pp_ok=1; pp_detail="$pp_detail [an unset parent.pki.roles still emitted a roles key, which would override the tenant chart default]"; }
# And a nulled optional block must not nil-pointer the whole bootstrap render.
printf 'parent:\n  pki: null\n  sso: null\n' > "$WORK/pp-null.yaml"
"$HELM" template "$RELEASE" "$BOOTSTRAP" -n "$NS" -f "$WORK/pp-null.yaml" > "$WORK/pp-null.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [a nulled parent.pki/parent.sso failed the bootstrap render: $(head -1 "$WORK/pp-null.out" | cut -c1-90)]"; }
[ "$pp_ok" -eq 0 ] && check parentplumb 0 || check parentplumb 1 "$pp_detail"

templateset_case defaults  enabled  false false openbao-config-mto openbao-config-mto-eso
templateset_case all-on    enabled  true  true  openbao-config-mto openbao-config-mto-eso openbao-config-mto-certmanager openbao-config-mto-trust
templateset_case all-off   disabled false false openbao-config-mto
templateset_case trust-only disabled false true openbao-config-mto openbao-config-mto-trust

exit "$fail"
