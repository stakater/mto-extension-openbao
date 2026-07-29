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
#                    block gated into zero components).
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
#
# The emission test renders files/parent-gotemplate.tpl through helm's tpl —
# an approximation of t-op-v2's text/template+Sprig engine that is exact for
# the constructs the gotemplate uses (range/dict/list/append/eq).
#
# Regenerating the golden after an INTENTIONAL chart change:
#   helm template openbao-config-mto charts/openbao-config-mto \
#     -n mto-extension-openbao-system -f hack/render-fixtures/values-full.yaml \
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
NS=mto-extension-openbao-system
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
sort $(for c in $SLICES; do echo "$WORK/$c.ids"; done) > "$WORK/union.ids"
diff "$WORK/union.ids" "$WORK/all.ids" > /dev/null \
  && check union 0 \
  || check union 1 "slices ∪ ≠ all: $(diff "$WORK/union.ids" "$WORK/all.ids" | head -4 | tr '\n' ' ')"

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
  operatorNamespace: mto-extension-openbao-system
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

exit "$fail"
