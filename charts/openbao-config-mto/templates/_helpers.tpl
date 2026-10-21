{{/*
Returns "true" when the given component should render in this pass, "" when
it should not. Every template block belongs to exactly one component (core,
eso, certManager, trust); component=all renders them all. trust (the
trust-manager Bundle wiring) is separate from certManager because the two
depend on different operators' CRDs and toggle independently. Fails the
render on an unrecognized .Values.component so a typo surfaces loudly
instead of silently emitting nothing.
Usage:  {{ if include "openbao.componentEnabled" (dict "component" "eso" "ctx" $) }}
*/}}
{{- define "openbao.componentEnabled" -}}
{{- $valid := list "all" "core" "eso" "certManager" "trust" -}}
{{- if not (has .ctx.Values.component $valid) -}}
{{- fail (printf "unknown component %q — must be one of: %s" .ctx.Values.component (join ", " $valid)) -}}
{{- end -}}
{{- /* Helm ignores unknown values silently, so a values file still setting the
       removed `defaultCapability` would lose every grant it believes it makes.
       Checked here because every template calls this first; the file named in the
       error is incidental. */ -}}
{{- if hasKey .ctx.Values "defaultCapability" -}}
{{- fail "defaultCapability was removed: OpenBao access is now opt-in per engine. Annotate each ServiceAccount with bao.stakater.com/kv, /transit or /pki set to \"true\" plus bao.stakater.com/tier, and delete defaultCapability from your values" -}}
{{- end -}}
{{- /* A tenant with the shared space's name would BE the shared space: the same
       bao namespace, and CRs named <name>-kv, <name>-kubernetes, <name>-oidc —
       the parent's own shared objects. Failing here fails that one tenant's
       TemplateInstance; every other tenant and the shared space are unaffected. */ -}}
{{- $sharedName := toString (dig "name" "" (.ctx.Values.sharedTenant | default dict)) -}}
{{- if and $sharedName (eq (toString .ctx.Values.tenant) $sharedName) -}}
{{- fail (printf "tenant %q has the name of the shared space (parent.sharedTenantName in the bootstrap chart, sharedTenant.name here): its OpenBao namespace and its CRs would be the shared space's own. Rename the tenant, or, before any tenant shares data, give the shared space another name. See \"Upgrading\" in the charts README." $sharedName) -}}
{{- end -}}
{{- /* The same for the platform CA's namespace, which exists when the hierarchy
       is on: the bootstrap chart's OpenBaoNamespace CR has that name, and the
       tenant's CRs would target the namespace that holds the platform CA. */ -}}
{{- if eq (include "openbao.on" (dict "ctx" .ctx "path" "pki.hierarchy.enabled")) "true" -}}
{{- $platformName := trimSuffix "/" (toString (dig "hierarchy" "platformNamespace" "" (.ctx.Values.pki | default dict))) -}}
{{- if and $platformName (eq (toString .ctx.Values.tenant) $platformName) -}}
{{- fail (printf "tenant %q has the name of the platform CA's namespace (platformPki.openbaoNamespace in the bootstrap chart, pki.hierarchy.platformNamespace here): its OpenBao namespace and its OpenBaoNamespace CR would be the platform CA's. Rename the tenant, or, before the platform CA is issued, put the platform CA in another namespace. See \"Upgrading\" in the charts README." $platformName) -}}
{{- end -}}
{{- end -}}
{{- /* A sliced render only happens under the bootstrap's per-tenant
       TemplateInstance convention (openbao-config-mto-<tenant>[.suffix]),
       and template-operator-v2 stamps that TI name as a label value on every
       rendered resource — Kubernetes caps label values at 63 chars. Fail the
       render with a clear message instead of letting every object bounce off
       server-side dry-run with an opaque invalid-label error. component=all
       (standalone helm install, no TI) is exempt. */ -}}
{{- if ne .ctx.Values.component "all" -}}
{{- $suffix := index (dict "core" "" "eso" ".eso" "certManager" ".certmanager" "trust" ".trust") .ctx.Values.component -}}
{{- $tiName := printf "openbao-config-mto-%s%s" (.ctx.Values.tenant | default "") $suffix -}}
{{- if gt (len $tiName) 63 -}}
{{- fail (printf "tenant name %q (%d chars) makes TemplateInstance name %q %d chars; it is stamped as a label value on every rendered resource and label values cap at 63 — shorten the tenant name (budget: ≤44 core, ≤40 .eso, ≤38 .trust, ≤32 .certmanager). Checked in every template, so the file named above is incidental." .ctx.Values.tenant (len .ctx.Values.tenant) $tiName (len $tiName)) -}}
{{- end -}}
{{- end -}}
{{- if or (eq .ctx.Values.component "all") (eq .ctx.Values.component .component) -}}true{{- end -}}
{{- end -}}

{{/*
Returns the JSON-list capabilities string for a tier.
Usage:  {{ include "openbao.tierCaps" (dict "tier" "editor" "tierCaps" .Values.tierCaps) }}
*/}}
{{- define "openbao.tierCaps" -}}
{{- index .tierCaps .tier -}}
{{- end -}}

{{/*
Fails the render if a generated resource name exceeds the 253-char Kubernetes
metadata.name limit, naming the offender. Without this, a long combination of
tenant/namespace/service-account/peer names surfaces only as an opaque apply-time
rejection that blocks the whole tenant. Returns the name unchanged on success.
*/}}
{{- define "openbao.assertName" -}}
{{- if gt (len .) 253 -}}
{{- fail (printf "generated resource name %q is %d chars, over the 253-char Kubernetes name limit — shorten the tenant, namespace, service-account, or peer name" . (len .)) -}}
{{- end -}}
{{- . -}}
{{- end -}}

{{/*
Per-SA own-tenant role/policy name: <tenant>-<saNs>-<sa>.

The tier is deliberately not part of it: (tenant, namespace, serviceAccount) is
already unique, so a tier suffix only makes a mutable attribute part of the
object's identity. A tier edit would then be a rename, and a rename deletes the
old policy — which strips live tokens at once and leaves the workload's cached
VAULT_K8S_ROLE naming a role that no longer exists.

Usage:  {{ include "openbao.roleName" (dict "tenant" $tenant "saNs" $saNs "saName" $saName) }}
*/}}
{{- define "openbao.roleName" -}}
{{- include "openbao.assertName" (printf "%s-%s-%s" .tenant .saNs .saName) -}}
{{- end -}}

{{/*
Cross-tenant share-out role/policy name: share-<tenant>-<saNs>-<sa>-out-<peer>.
*/}}
{{- define "openbao.shareOutName" -}}
{{- include "openbao.assertName" (printf "share-%s-%s-%s-out-%s" .tenant .saNs .saName .peer) -}}
{{- end -}}

{{/*
Cross-tenant share-in role/policy name: share-<tenant>-<saNs>-<sa>-in-<peer>.
*/}}
{{- define "openbao.shareInName" -}}
{{- include "openbao.assertName" (printf "share-%s-%s-%s-in-%s" .tenant .saNs .saName .peer) -}}
{{- end -}}

{{/*
Returns "true" when a cross-tenant share to .peer should be rendered: .peer is
non-empty AND either .knownCsv (the comma-separated roster of real tenant names
the parent passes via .Values.knownTenants) is empty — no roster supplied, so
filtering is disabled and the chart behaves as it did standalone — or .peer is
one of those names. Skipping an unknown peer avoids creating a dangling
Policy/Role for a tenant that does not exist; the share self-heals when that
tenant later appears and the roster updates.
Usage:  {{ if include "openbao.peerEmittable" (dict "peer" $peer "knownCsv" $.Values.knownTenants) }}
*/}}
{{- define "openbao.peerEmittable" -}}
{{- $peer := .peer -}}
{{- $csv := .knownCsv | default "" -}}
{{- if not $peer -}}
{{- else if not (trim $csv) -}}
true
{{- else -}}
{{- $known := list -}}
{{- range $t := splitList "," $csv -}}{{- $known = append $known (trim $t) -}}{{- end -}}
{{- if has $peer $known -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The cross-tenant KV peers this tenant's workloads hold grants for, as
{exports: [...], imports: [...]}, sorted and de-duplicated. It uses the same
ServiceAccounts, conditions and roster filter as 04-sa-share-out.yaml and
04-sa-share-in.yaml, so the SSO grants in the shared space name exactly the
peers a workload of the tenant can reach.
Usage:  {{ $peers := include "openbao.ssoSharePeers" $ | fromYaml }}
*/}}
{{- define "openbao.ssoSharePeers" -}}
{{- $tenantNamespaces := include "openbao.tenantNamespaces" . | fromYaml -}}
{{- $appClaims := include "openbao.appClaims" . | fromYaml -}}
{{- $found := dict "exports" (list) "imports" (list) -}}
{{- range $sa := (ternary .Values.serviceAccounts (list) (kindIs "slice" .Values.serviceAccounts)) -}}
{{- $f := include "openbao.saFacts" (dict "sa" $sa "ctx" $ "tenantNamespaces" $tenantNamespaces "appClaims" $appClaims) | fromYaml -}}
{{- if and $f.kvOn (not $f.errors) $f.name $f.ns -}}
{{- range $dir := list (list "exports" "kv-export-tenant") (list "imports" "kv-import-tenant") -}}
{{- $raw := dig "metadata" "annotations" (printf "bao.stakater.com/%s" (index $dir 1)) "" $sa -}}
{{- range $peer := splitList "," $raw -}}
{{- $peer = trim $peer -}}
{{- if include "openbao.peerEmittable" (dict "peer" $peer "knownCsv" $.Values.knownTenants) -}}
{{- $_ := set $found (index $dir 0) (append (get $found (index $dir 0)) $peer) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml (dict "exports" ($found.exports | uniq | sortAlpha) "imports" ($found.imports | uniq | sortAlpha)) -}}
{{- end -}}

{{/*
The _sharedSpace entry of bao-apps: one web UI link per partner tenant, to what
it sent this tenant and to what this tenant sends it. People cannot browse to
these folders, because a list of <env>/ or of a partner's folder shows other
tenants' shares, and an OpenBao list cannot be filtered. Empty unless SSO and
the shared-space login are on and the tenant has a share. The UI address is the
first sso.allowedRedirectUris entry that is the UI callback, without the
callback path; with none, the links start at /ui/.
Usage:  {{ include "openbao.sharedSpaceLinks" $ }}
*/}}
{{- define "openbao.sharedSpaceLinks" -}}
{{- if and (include "openbao.ssoEnabled" .) (include "openbao.ssoSharedSpaceEnabled" .) -}}
{{- $peers := include "openbao.ssoSharePeers" . | fromYaml -}}
{{- if or $peers.exports $peers.imports -}}
{{- $tenant := .Values.tenant -}}
{{- $shared := .Values.sharedTenant.name -}}
{{- $callback := "/ui/vault/auth/oidc/oidc/callback" -}}
{{- $base := "" -}}
{{- range $u := (.Values.sso.allowedRedirectUris | default list) -}}
{{- if and (not $base) (hasSuffix $callback (toString $u)) -}}{{- $base = trimSuffix $callback (toString $u) -}}{{- end -}}
{{- end -}}
{{- $roles := list -}}
{{- range $t := .Values.sso.tiers -}}{{- $roles = append $roles (include "openbao.ssoRoleName" (dict "tenant" $tenant "tier" $t)) -}}{{- end -}}
{{- $list := printf "%s/ui/vault/secrets/kv/list/%s" $base .Values.env -}}
namespace: {{ $shared }}
login: {{ printf "%s/ui/vault/auth?namespace=%s&with=oidc" $base $shared | quote }}
roles: {{ join ", " $roles | quote }}
{{- with $peers.imports }}
received:
{{- range $p := . }}
  {{ $p }}: {{ printf "%s/from-%s/to-%s/?namespace=%s" $list $p $tenant $shared | quote }}
{{- end }}
{{- end }}
{{- with $peers.exports }}
sent:
{{- range $p := . }}
  {{ $p }}: {{ printf "%s/from-%s/to-%s/?namespace=%s" $list $tenant $p $shared | quote }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Splits a comma-separated annotation value into a trimmed, non-empty list of
strings. Returns an empty list when input is empty.
Usage:  {{ range include "openbao.splitCsv" "team-a, team-b" | fromYamlArray }}
*/}}
{{- define "openbao.splitCsv" -}}
{{- $out := list -}}
{{- range $p := splitList "," . -}}
  {{- $p = trim $p -}}
  {{- if $p -}}{{- $out = append $out $p -}}{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Renders the IdP-side group name for a (tenant, tier) pair.
Resolution: tenantRoleMapping[<tier>].pattern → tenantGroupTemplate → fail.
Substitutes {tenant} and {tier} placeholders.

Usage:
  {{ include "openbao.ssoGroup" (dict "tenant" "team-a" "tier" "admin"
                                       "mapping" $.Values.sso.tenantRoleMapping
                                       "defaultTemplate" $.Values.sso.tenantGroupTemplate) }}
*/}}
{{- define "openbao.ssoGroup" -}}
{{- $tierEntry := index .mapping .tier -}}
{{- $pattern := "" -}}
{{- if and $tierEntry $tierEntry.pattern -}}
{{- $pattern = $tierEntry.pattern -}}
{{- else if .defaultTemplate -}}
{{- $pattern = .defaultTemplate -}}
{{- else -}}
{{- fail (printf "sso: tier %q has no pattern and no sso.tenantGroupTemplate default is set" .tier) -}}
{{- end -}}
{{- $s := $pattern -}}
{{- $s = replace "{tenant}" .tenant $s -}}
{{- $s = replace "{tier}" .tier $s -}}
{{- $s -}}
{{- end -}}

{{/*
Per-tenant-tier SSO role/policy name: sso-<tenant>-<tier>.
Usage:  {{ include "openbao.ssoRoleName" (dict "tenant" $tenant "tier" $tier) }}
*/}}
{{- define "openbao.ssoRoleName" -}}
{{- printf "sso-%s-%s" .tenant .tier -}}
{{- end -}}

{{/*
Fails the render unless the tier is one of the four the templates know. The
templates match tier names exactly, so an unknown tier falls through to the
plain tierCaps grant. It also makes role names ambiguous: tier "read" of tenant
"x-audit" and tier "audit-read" of tenant "x" both give sso-x-audit-read. Every
tenant's SSO CRs share operatorNamespace, and in the shared space every
tenant's bao roles and policies sit side by side, so the collision crosses
tenants. values.schema.json carries the same enum.
Usage:  {{- include "openbao.assertSsoTier" $tier }}
*/}}
{{- define "openbao.assertSsoTier" -}}
{{- $known := list "admin" "editor" "viewer" "audit-read" -}}
{{- if not (has . $known) -}}
{{- fail (printf "sso.tiers includes %q, which is not one of %s — role names are sso-<tenant>-<tier>, so a custom tier can collide with another tenant's role" (toString .) (join ", " $known)) -}}
{{- end -}}
{{- end -}}

{{/*
Reads a boolean value strictly: a YAML boolean or the string "true"/"false".
Returns "true" or "false", or "" when the key is absent or null, so each caller
picks its own default. Anything else fails the render with .name and .why, so
the guard also works with --skip-schema-validation. `{{ if .Values.x }}` is not
enough: the schema accepts the string "false", and a non-empty string is
truthy. Callers: openbao.on and the two deletion-policy helpers.
Usage:  {{ include "openbao.strictBool" (dict "from" .Values.safety "key" "deletionProtection" "name" "safety.deletionProtection" "why" "turn deletion protection off") }}
*/}}
{{- define "openbao.strictBool" -}}
{{- $m := .from | default dict -}}
{{- /* hasKey first: sprig get returns "" (not nil) for a missing key. */ -}}
{{- if and (hasKey $m .key) (not (kindIs "invalid" (get $m .key))) -}}
{{- $s := toString (get $m .key) -}}
{{- if not (has $s (list "true" "false")) -}}
{{- fail (printf "%s must be a boolean true or false — got %q. Quoted \"true\"/\"false\" also work; anything else (yes, on, 1, True) is rejected so a typo cannot silently %s." .name $s .why) -}}
{{- end -}}
{{- $s -}}
{{- end -}}
{{- end -}}

{{/*
Returns "true" when the switch at .path (dot-separated, under .Values) is on, ""
when not. Absent or null, at the switch or at a block above it, is off. A block
that is not a map fails, as does a value that strictBool rejects. .why ends the
error message; it defaults to "turn <path> on or off". Every boolean switch of
the chart is read through here, except safety.*, whose defaults the
deletion-policy helpers set.
Usage:  {{ if include "openbao.on" (dict "ctx" $ "path" "pki.hierarchy.enabled") }}
*/}}
{{- define "openbao.on" -}}
{{- $parts := splitList "." .path -}}
{{- $m := .ctx.Values -}}
{{- $walked := list -}}
{{- range $p := initial $parts -}}
{{- $walked = append $walked $p -}}
{{- if and (hasKey $m $p) (not (kindIs "invalid" (get $m $p))) -}}
{{- if not (kindIs "map" (get $m $p)) -}}
{{- fail (printf "%s must be a map — got %q. The switch is %s, and a value here is not read as on or off." (join "." $walked) (toString (get $m $p)) $.path) -}}
{{- end -}}
{{- $m = get $m $p -}}
{{- else -}}
{{- $m = dict -}}
{{- end -}}
{{- end -}}
{{- $why := .why | default (printf "turn %s on or off" .path) -}}
{{- if eq (include "openbao.strictBool" (dict "from" $m "key" (last $parts) "name" .path "why" $why)) "true" -}}true{{- end -}}
{{- end -}}

{{/*
Returns "true" when sso.enabled is on, "" when not; absent or null is off.
*/}}
{{- define "openbao.ssoEnabled" -}}
{{- include "openbao.on" (dict "ctx" . "path" "sso.enabled" "why" "turn SSO on") -}}
{{- end -}}

{{/*
Returns "true" when people may log in to the shared space (sso.sharedSpace.
enabled), "" when not; absent or null is off. Does not include sso.enabled —
callers check both.
*/}}
{{- define "openbao.ssoSharedSpaceEnabled" -}}
{{- include "openbao.on" (dict "ctx" . "path" "sso.sharedSpace.enabled" "why" "change who can read another tenant's shares") -}}
{{- end -}}

{{/*
The spec of an SSO OIDC role, shared by §7 (the tenant namespace) and §7b (the
shared space), so the two logins cannot drift. It fails closed: a role binds
its .group, and only "unbound" true renders a role with no group (§7's
fallback). An empty .group without "unbound" fails the render.
Usage:  spec:
          {{- include "openbao.ssoRoleSpec" (dict "ctx" $ "name" $n "namespace" "team-a/" "group" $g "policy" $n) | nindent 2 }}
*/}}
{{- define "openbao.ssoRoleSpec" -}}
deletionPolicy: {{ include "openbao.grantDeletionPolicy" .ctx }}
name: {{ .name }}
path: oidc
openbaoNamespace: {{ .namespace }}
roleType: oidc
userClaim: email
groupsClaim: groups
oidcScopes:
  - email
  - profile
  - groups
boundAudiences:
  - {{ .ctx.Values.sso.audience | quote }}
{{- if .unbound }}
{{- else if .group }}
boundClaims:
  groups:
    - {{ .group | quote }}
{{- else }}
{{- fail (printf "openbao.ssoRoleSpec: role %s has an empty IdP group and is not marked unbound — rendered, any IdP user could log in with it" .name) }}
{{- end }}
tokenPolicies:
  - {{ .policy }}
allowedRedirectUris:
  {{- range $uri := .ctx.Values.sso.allowedRedirectUris }}
  - {{ $uri | quote }}
  {{- end }}
{{- if .ctx.Values.ssoToken.ttl }}
tokenTtl: {{ .ctx.Values.ssoToken.ttl }}
{{- end }}
{{- if .ctx.Values.ssoToken.maxTTL }}
tokenMaxTtl: {{ .ctx.Values.ssoToken.maxTTL }}
{{- end }}
{{- end -}}

{{/*
Substitutes {tenant} in a string. Used for transit/pki templated values.
Usage:  {{ include "openbao.subTenant" (dict "tenant" $tenant "s" "{tenant}.svc.cluster.local") }}
*/}}
{{- define "openbao.subTenant" -}}
{{- replace "{tenant}" .tenant .s -}}
{{- end -}}

{{/*
Bao-side intra-tenant transit key NAMES (the .spec.name on the
OpenBaoTransitKey CR; also the literal in bao path transit/encrypt/<name>).
  - per-namespace key:  <nsFull>-<env>
  - tenant shared key:  <tenant>-shared-<env>
*/}}
{{- define "openbao.transitNsKeyName" -}}
{{- printf "%s-%s" .ns .env -}}
{{- end -}}
{{- define "openbao.transitSharedKeyName" -}}
{{- printf "%s-shared-%s" .tenant .env -}}
{{- end -}}

{{/*
OpenBaoTransitKey CR names (metadata.name — must be unique within the
operator namespace across all tenants, hence the tenant prefix).
  - per-namespace key:  transit-<tenant>-<nsFull>-<env>
  - tenant shared key:  transit-<tenant>-shared-<env>
*/}}
{{- define "openbao.transitNsKeyCRName" -}}
{{- printf "transit-%s-%s-%s" .tenant .ns .env -}}
{{- end -}}
{{- define "openbao.transitSharedKeyCRName" -}}
{{- printf "transit-%s-shared-%s" .tenant .env -}}
{{- end -}}

{{/*
Per-app transit key NAME: <ns>-<app>-<env>-<hash>.

Key names are flat strings and every part may contain hyphens, so joining is
ambiguous: (ns team-a-dev, app app-a) and (ns team-a, app dev-app-a) both glue to
"team-a-dev-app-a-dev". The suffix is computed from the parts BEFORE joining.
Usage: {{ include "openbao.transitAppKeyName" (dict "ns" $saNs "app" $app "env" $env) }}
*/}}
{{- define "openbao.transitAppKeyName" -}}
{{- $h := printf "%s/%s/%s" .ns .app .env | sha256sum | trunc 6 -}}
{{- printf "%s-%s-%s-%s" .ns .app .env $h -}}
{{- end -}}

{{/*
Per-app transit key CR name: transit-<tenant>-<ns>-<app>-<env>-<hash>.
*/}}
{{- define "openbao.transitAppKeyCRName" -}}
{{- include "openbao.assertName" (printf "transit-%s-%s" .tenant (include "openbao.transitAppKeyName" (dict "ns" .ns "app" .app "env" .env))) -}}
{{- end -}}

{{/*
Effective tenant PKI mount path. In hierarchy mode the tenant CA is a
type=intermediate rendered at a FRESH mount (pki.hierarchy.mountPath) so it
never reuses a root-bearing mount; otherwise it's the self-signed root at
pki.mountPath. Every template that references the tenant PKI mount (config,
role, SA policies, cert-manager Issuer) must resolve it through this helper so
they stay in lockstep.
Usage (root context): {{ include "openbao.pkiMount" . }}
*/}}
{{- define "openbao.pkiMount" -}}
{{- $pki := .Values.pki -}}
{{- if include "openbao.on" (dict "ctx" . "path" "pki.hierarchy.enabled") -}}
{{- $pki.hierarchy.mountPath -}}
{{- else -}}
{{- $pki.mountPath -}}
{{- end -}}
{{- end -}}

{{/*
Renders the bao-side PKI role NAME (the .spec.name on the
OpenBaoPKISecretEngineRole CR, also the literal used in bao path
`pki/issue/<name>`). Substitutes {tenant}.
Usage: {{ include "openbao.pkiDefaultRoleName" (dict "tpl" .Values.pki.defaultRole.nameTemplate "tenant" $tenant) }}
*/}}
{{- define "openbao.pkiDefaultRoleName" -}}
{{- replace "{tenant}" .tenant .tpl -}}
{{- end -}}

{{/*
Fails unless every pki.roles[] entry renders a DISTINCT role name.

The name is the bao role name, the `metadata.name` of the
OpenBaoPKISecretEngineRole (as pki-<name>) and the cert-manager Issuer name, so
two entries that render the same name emit two same-named objects with different
specs from one render. Helm does not reject that, and server-side apply takes
the last one: the other entry's ttl, flags and domains vanish with no error on
any object, no failed TemplateInstance and no Event — the render looks clean and
one of the two roles the values asked for does not exist.

Called from every template that iterates pki.roles (03, 04, 10) rather than from
03 alone, because each component renders in its own TemplateInstance and the
certManager slice iterates the roles without 03.

Usage (root context): {{ include "openbao.pkiAssertRoleNamesUnique" . }}
*/}}
{{- define "openbao.pkiAssertRoleNamesUnique" -}}
{{- $tenant := .Values.tenant -}}
{{- /* Named here rather than left to the CA-constraint guard downstream, which
       would report the same state as "no role renders a domain for any
       namespace". The schema rejects both [] and null, so this only fires with
       the schema skipped. */ -}}
{{- if not .Values.pki.roles -}}
{{- fail "pki.enabled=true but pki.roles is empty — the engine and the tenant CA would be created with no role able to issue from them" -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $i, $r := .Values.pki.roles -}}
{{- if not (kindIs "string" $r.nameTemplate) -}}
{{- fail (printf "pki.roles[%d] has no nameTemplate — every entry needs one, and it becomes the bao role name, the OpenBaoPKISecretEngineRole name and the cert-manager Issuer name" $i) -}}
{{- end -}}
{{- $name := include "openbao.pkiDefaultRoleName" (dict "tpl" $r.nameTemplate "tenant" $tenant) -}}
{{- if not $name -}}
{{- fail (printf "pki.roles[%d].nameTemplate renders empty for tenant %q" $i $tenant) -}}
{{- end -}}
{{- /* The strictest consumer sets the rule: the CRD constrains spec.name to an
       RFC 1123 LABEL (no dots), while metadata.name and the Issuer name would
       take a subdomain. Not openbao.assertName — that helper echoes its input
       and this one runs for its failures only, so its limit is repeated below. */ -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{- fail (printf "pki.roles[%d].nameTemplate renders %q for tenant %q, which the operator's CRD rejects for spec.name — it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ (lowercase alphanumerics and '-' only; no dots, no underscores, no uppercase). It becomes the OpenBaoPKISecretEngineRole \"pki-%s\" and the cert-manager Issuer %q" $i $name $tenant $name $name) -}}
{{- end -}}
{{- if gt (len (printf "pki-%s" $name)) 253 -}}
{{- fail (printf "pki.roles[%d].nameTemplate renders %q for tenant %q, making the OpenBaoPKISecretEngineRole name \"pki-%s\" %d chars — over the 253-char Kubernetes name limit. Shorten the nameTemplate or the tenant name" $i $name $tenant $name (len (printf "pki-%s" $name))) -}}
{{- end -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "pki.roles[%d].nameTemplate and pki.roles[%s].nameTemplate both render the role name %q for tenant %q — each entry becomes an object of that name, so one would silently overwrite the other. Make every nameTemplate render a distinct name" $i (index $seen $name) $name $tenant) -}}
{{- end -}}
{{- $_ := set $seen $name (toString $i) -}}
{{- end -}}
{{- end -}}

{{/*
Renders the bao kubernetes-auth role NAME the cert-manager Issuer uses,
from pki.certManager.authRoleNameTemplate. Substitutes {tenant} and {ns}.
*/}}
{{- define "openbao.certManagerAuthRoleName" -}}
{{- $s := .tpl -}}
{{- $s = replace "{tenant}" .tenant $s -}}
{{- $s = replace "{ns}" .ns $s -}}
{{- $s -}}
{{- end -}}

{{/*
Renders one entry of pki.defaultRole.allowedDomainsTemplate against a
(tenant, namespace) pair. Substitutes {tenant} and {namespace}.
*/}}
{{- define "openbao.pkiAllowedDomain" -}}
{{- $s := .tpl -}}
{{- $s = replace "{tenant}" .tenant $s -}}
{{- $s = replace "{namespace}" .namespace $s -}}
{{- $s -}}
{{- end -}}

{{/*
Cross-tenant transit share-out policy/role name:
  share-transit-<tenant>-<saNs>-<sa>-out-<peer>.
*/}}
{{- define "openbao.transitShareOutName" -}}
{{- include "openbao.assertName" (printf "share-transit-%s-%s-%s-out-%s" .tenant .saNs .saName .peer) -}}
{{- end -}}

{{/*
Cross-tenant transit share-in policy/role name:
  share-transit-<tenant>-<saNs>-<sa>-in-<peer>.
*/}}
{{- define "openbao.transitShareInName" -}}
{{- include "openbao.assertName" (printf "share-transit-%s-%s-%s-in-%s" .tenant .saNs .saName .peer) -}}
{{- end -}}

{{/*
Per-pair transit key CR name in shared/ bao ns:
  transit-share-<writer>-to-<reader>.
*/}}
{{- define "openbao.transitShareKeyCRName" -}}
{{- printf "transit-share-%s-to-%s" .writer .reader -}}
{{- end -}}

{{/*
Bao-side transit key NAME (the .spec.name on the OpenBaoTransitKey CR;
also the literal segment used in bao path `transit/encrypt/<keyName>`):
  from-<writer>-to-<reader>-<env>.
*/}}
{{- define "openbao.transitShareKeyName" -}}
{{- printf "from-%s-to-%s-%s" .writer .reader .env -}}
{{- end -}}

{{/*
Common labels stamped on every chart-emitted resource. Includes
stakater.com/tenant for cost-attribution / per-tenant cardinality, plus
the chart/app-managed-by metadata. The `tenant` label is the v9 contract
with the upstream MTO labelling — also what the parent's namespaceSelector
keys off, so reusing it on emitted CRs keeps everything consistent.

Usage (inside a chart template — has .Values, .Chart, .Release available):
  metadata:
    labels:
      {{- include "openbao.labels" . | nindent 6 }}
*/}}
{{- define "openbao.labels" -}}
{{- $t := required ".Values.tenant must be set by the parent" .Values.tenant -}}
{{- if gt (len $t) 63 -}}
{{- fail (printf "tenant name %q is %d chars; it is stamped as the %q label value on every resource and a Kubernetes label value must be <=63 chars" $t (len $t) .Values.tenantLabelKey) -}}
{{- end -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: helm-via-template-operator-v2
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ .Values.tenantLabelKey }}: {{ required ".Values.tenant must be set by the parent" .Values.tenant }}
{{- end -}}

{{/*
The complete set of `bao.stakater.com/` keys this chart reads on a ServiceAccount,
so an unrecognised one can be reported rather than ignored: the templates look up
the keys they expect, so without a closed-world list a typo grants nothing and
says nothing.

A new annotation must be added here too, or it is rejected as unknown — loud, and
the safe direction to fail.
*/}}
{{- define "openbao.saAnnotationKeys" -}}
{{- $keys := list
      "kv" "transit" "pki"
      "tier" "app"
      "kv-subscribe-ns" "kv-export-tenant" "kv-import-tenant"
      "transit-export-tenant" "transit-import-tenant"
      "pki-allow-tenant" "pki-trust-tenant" -}}
{{- toYaml $keys -}}
{{- end -}}

{{/*
Resolves and validates every `bao.stakater.com/` annotation on one
ServiceAccount, returning a YAML dict the caller parses with `fromYaml`. One
helper, so validation and the values used to render cannot drift apart.

Returns: name, ns, app, tier, kvOn, transitOn, pkiOn, caps, transitCaps, and
`errors`. A non-empty `errors` means the caller renders the error ConfigMap and
nothing else for this ServiceAccount.

Reporting per ServiceAccount rather than failing: one TemplateInstance renders
every namespace a tenant owns, so `fail` produces zero objects for the tenant and
freezes unrelated namespaces. `fail` is kept for problems that cannot be
attributed to one ServiceAccount.

Usage:
  {{- $f := include "openbao.saFacts" (dict "sa" $sa "ctx" $ "tenantNamespaces" $tns "appClaims" $claims) | fromYaml }}
*/}}
{{- define "openbao.saFacts" -}}
{{- /* Both maps are required. Defaulting them would leave the app-collision and
       foreign-namespace checks inert for a caller that forgot to thread them —
       validation that appears to run and does not. An empty dict is legitimate;
       an absent key is a wiring bug. */ -}}
{{- if not (hasKey . "appClaims") -}}
{{- fail "openbao.saFacts requires an appClaims argument (see openbao.appClaims); omitting it would silently disable the app-collision check" -}}
{{- end -}}
{{- if not (hasKey . "tenantNamespaces") -}}
{{- fail "openbao.saFacts requires a tenantNamespaces argument (see openbao.tenantNamespaces); omitting it would silently disable the foreign-namespace check" -}}
{{- end -}}
{{- $sa := .sa -}}
{{- $v := .ctx.Values -}}
{{- $transitEngine := eq (include "openbao.on" (dict "ctx" .ctx "path" "transit.enabled")) "true" -}}
{{- $pkiEngine := eq (include "openbao.on" (dict "ctx" .ctx "path" "pki.enabled")) "true" -}}
{{- $p := "bao.stakater.com/" -}}
{{- $known := include "openbao.saAnnotationKeys" . | fromYamlArray -}}
{{- $name := dig "metadata" "name" "" $sa -}}
{{- $ns := dig "metadata" "namespace" "" $sa -}}
{{- $ann := dig "metadata" "annotations" (dict) $sa -}}
{{- $errs := list -}}

{{- /* G13 — unknown key, checked first: a misspelled key means nothing read below
       reflects what the user meant. Only our own prefix is considered. */ -}}
{{- $hasBao := false -}}
{{- range $k, $_ := $ann -}}
{{- if hasPrefix $p $k -}}
{{- $hasBao = true -}}
{{- if not (has (trimPrefix $p $k) $known) -}}
{{- $errs = append $errs (printf "unknown annotation %q — this chart reads none of that name, so it has no effect. Valid keys: %s" $k (join ", " (sortAlpha $known))) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* G16 — rendered ConfigMap and SecretStore names embed this name and
       reserve dot-separated suffixes (.error, .deploy-error,
       .share-<peer>-bao). Kubernetes allows dots in ServiceAccount names;
       keeping OpenBao-enabled ones dot-free is what keeps those suffixes
       unreachable. Says nothing about role/policy name ambiguity. */ -}}
{{- if and $hasBao (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) -}}
{{- $errs = append $errs (printf "ServiceAccount name %q cannot be used with OpenBao: rendered ConfigMap and SecretStore names embed it and reserve dot-separated suffixes (.error, .share-<peer>-bao), so it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ (lowercase letters, digits and hyphens — no dots). Rename the ServiceAccount" $name) -}}
{{- end -}}

{{- /* G14 — a misspelled boolean would leave its engine off while the
       mutual-requirement checks stay quiet, another engine being legitimately on. */ -}}
{{- $raw := dict -}}
{{- range $e := list "kv" "transit" "pki" -}}
{{- $val := lower (trim (toString (dig "metadata" "annotations" (printf "%s%s" $p $e) "" $sa))) -}}
{{- $_ := set $raw $e $val -}}
{{- if and $val (not (has $val (list "true" "false"))) -}}
{{- $errs = append $errs (printf "%s%s must be \"true\" or \"false\", got %q" $p $e $val) -}}
{{- end -}}
{{- end -}}
{{- $kvOn := eq (get $raw "kv") "true" -}}
{{- $transitReq := eq (get $raw "transit") "true" -}}
{{- $pkiReq := eq (get $raw "pki") "true" -}}
{{- $anyEngine := or $kvOn $transitReq $pkiReq -}}

{{- $tier := trim (toString (dig "metadata" "annotations" (printf "%stier" $p) "" $sa)) -}}
{{- $app := trim (toString (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa)) -}}
{{- if not $app -}}{{- $app = $name -}}{{- end -}}

{{- /* G8 — every pod that omits serviceAccountName runs as `default`, so granting
       it hands one identity and one prefix to all of them, while the rendered
       policy still looks correctly scoped. */ -}}
{{- if and (eq $name "default") $anyEngine -}}
{{- $errs = append $errs (printf "the `default` ServiceAccount cannot be granted OpenBao access: every pod that omits serviceAccountName runs as `default`, so they would all share one identity and the prefix kv/data/%s/%s/default/. Give each workload its own ServiceAccount and annotate that instead" $v.env $ns) -}}
{{- end -}}

{{- /* G1/G2 — an engine without a tier grants nothing, and a tier without an
       engine grants nothing. Both are silent misconfigurations otherwise. */ -}}
{{- if and $tier (not $anyEngine) -}}
{{- $errs = append $errs (printf "%stier is set to %q but no engine is enabled, so nothing is granted. Add %skv, %stransit or %spki set to \"true\"" $p $tier $p $p $p) -}}
{{- end -}}
{{- if and $anyEngine (not $tier) -}}
{{- $errs = append $errs (printf "an engine is enabled but %stier is not set, so no capabilities can be granted. Set a tier: %s" $p (join ", " (keys $v.tierCaps | sortAlpha))) -}}
{{- end -}}
{{- /* G1b — `app` only names the prefix an engine grant would use, so on its own
       it registers nothing the user believes it has. */ -}}
{{- if and (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa) (not $anyEngine) -}}
{{- $errs = append $errs (printf "%sapp is set but no engine is enabled, so no app identity is registered — it only names the prefix a %skv or %stransit grant would use. Add an engine, or remove the annotation" $p $p $p) -}}
{{- end -}}

{{- /* G3 — an unknown tier makes the capability lookup nil, which would skip
       the ServiceAccount with no signal. */ -}}
{{- if and $tier (not (hasKey $v.tierCaps $tier)) -}}
{{- $errs = append $errs (printf "%stier %q is not a known tier. Valid tiers: %s" $p $tier (join ", " (keys $v.tierCaps | sortAlpha))) -}}
{{- end -}}
{{- $caps := "" -}}
{{- $transitCaps := "" -}}
{{- if hasKey $v.tierCaps $tier -}}
{{- $caps = index $v.tierCaps $tier -}}
{{- $transitCaps = index $v.transit.tierCaps $tier -}}
{{- end -}}

{{- /* An engine switched off chart-wide can never be granted, so opting in is
       a request that silently returns nothing. */ -}}
{{- if and $transitReq (not $transitEngine) -}}
{{- $errs = append $errs (printf "%stransit is enabled on this ServiceAccount but the transit engine is disabled for the whole install (transit.enabled=false)" $p) -}}
{{- end -}}
{{- if and $pkiReq (not $pkiEngine) -}}
{{- $errs = append $errs (printf "%spki is enabled on this ServiceAccount but the PKI engine is disabled for the whole install (pki.enabled=false)" $p) -}}
{{- end -}}
{{- if and $pkiReq $pkiEngine (not $v.pki.roles) -}}
{{- $errs = append $errs (printf "%spki is enabled but pki.roles is empty — define at least one role under pki.roles" $p) -}}
{{- end -}}

{{- /* G4 — a tier that grants an enabled engine nothing. transit needs writes, so
       its viewer and audit-read capability sets are empty. */ -}}
{{- if and $transitReq $tier (hasKey $v.tierCaps $tier) (or (not $transitCaps) (eq $transitCaps "[]")) -}}
{{- $errs = append $errs (printf "%stransit is enabled but tier %q grants no transit capabilities (transit needs write access; use editor or admin)" $p $tier) -}}
{{- end -}}
{{- if and $kvOn $tier (hasKey $v.tierCaps $tier) (or (not $caps) (eq $caps "[]")) -}}
{{- $errs = append $errs (printf "%skv is enabled but tier %q grants no KV capabilities" $p $tier) -}}
{{- end -}}

{{- /* G5 — the app name becomes a path segment inside an HCL policy body and a
       segment of a transit key name. Unvalidated it is not a name but a policy
       the tenant writes: a value containing a quote and a brace closes our
       `path "..."` block and opens another one, and `+` is bao's
       single-segment wildcard, which would match every app in the namespace.
       Underscore-prefixed names are reserved for chart-owned prefixes such as
       `_shared`. */ -}}
{{- if $anyEngine -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $app) -}}
{{- $errs = append $errs (printf "%sapp %q is not a valid app name — it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ (lowercase letters, digits and hyphens; no leading or trailing hyphen). It is used as a path segment in the OpenBao policy and as part of the transit key name" $p $app) -}}
{{- else if gt (len $app) 63 -}}
{{- $errs = append $errs (printf "%sapp %q is %d characters; keep it to 63 or fewer" $p $app (len $app)) -}}
{{- end -}}
{{- end -}}

{{- /* G6 — two ServiceAccounts resolving to one app share a prefix and a key.
       Compared on RESOLVED names, so an SA that declared no `app` still defends
       its own name against another claiming it. */ -}}
{{- $claim := index .appClaims (printf "%s/%s" $ns $app) -}}
{{- if and $anyEngine $claim (gt (len $claim) 1) -}}
{{- $errs = append $errs (printf "app %q in namespace %s is claimed by more than one ServiceAccount (%s). Each app owns its own secret prefix and transit key, so the name must be unique within the namespace — change %sapp on all but one" $app $ns (join ", " $claim) $p) -}}
{{- end -}}

{{- /* G7 — a sharing annotation whose engine is off grants nothing. */ -}}
{{- range $k := list "kv-subscribe-ns" "kv-export-tenant" "kv-import-tenant" -}}
{{- if and (dig "metadata" "annotations" (printf "%s%s" $p $k) "" $sa) (not $kvOn) -}}
{{- $errs = append $errs (printf "%s%s is set but %skv is not \"true\", so it grants nothing" $p $k $p) -}}
{{- end -}}
{{- end -}}
{{- range $k := list "transit-export-tenant" "transit-import-tenant" -}}
{{- if and (dig "metadata" "annotations" (printf "%s%s" $p $k) "" $sa) (not $transitReq) -}}
{{- $errs = append $errs (printf "%s%s is set but %stransit is not \"true\", so it grants nothing" $p $k $p) -}}
{{- end -}}
{{- end -}}
{{- range $k := list "pki-allow-tenant" "pki-trust-tenant" -}}
{{- if and (dig "metadata" "annotations" (printf "%s%s" $p $k) "" $sa) (not $pkiReq) -}}
{{- $errs = append $errs (printf "%s%s is set but %spki is not \"true\", so it grants nothing" $p $k $p) -}}
{{- end -}}
{{- end -}}

{{- /* G9 — a namespace outside the tenant grants read on a prefix nothing writes
       to: a dead grant. */ -}}
{{- range $subNs := splitList "," (dig "metadata" "annotations" (printf "%skv-subscribe-ns" $p) "" $sa) -}}
{{- $subNs = trim $subNs -}}
{{- if and $subNs (not (hasKey $.tenantNamespaces $subNs)) -}}
{{- $errs = append $errs (printf "%skv-subscribe-ns references namespace %q, which is not a namespace of tenant %q (tenant owns: %s)" $p $subNs $v.tenant (join ", " (keys $.tenantNamespaces | sortAlpha))) -}}
{{- end -}}
{{- end -}}

{{- $out := dict
      "name" $name "ns" $ns "app" $app "tier" $tier
      "kvOn" $kvOn
      "transitOn" (and $transitReq $transitEngine)
      "pkiOn" (and $pkiReq $pkiEngine)
      "caps" $caps "transitCaps" $transitCaps
      "errors" $errs -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Builds the (namespace, resolved app) claim map used by G6: "<ns>/<app>" -> sorted
ServiceAccount names resolving to it. Only ServiceAccounts that enable an engine
claim an app, so plumbing accounts such as `builder` never collide. Sorted so the
message is stable whatever order the parent lists ServiceAccounts in.
Usage (root context): {{ include "openbao.appClaims" . }} -> YAML dict
*/}}
{{- define "openbao.appClaims" -}}
{{- $p := "bao.stakater.com/" -}}
{{- $claims := dict -}}
{{- range $sa := (ternary .Values.serviceAccounts (list) (kindIs "slice" .Values.serviceAccounts)) -}}
{{- $name := dig "metadata" "name" "" $sa -}}
{{- $ns := dig "metadata" "namespace" "" $sa -}}
{{- $on := false -}}
{{- range $e := list "kv" "transit" "pki" -}}
{{- if eq (lower (trim (toString (dig "metadata" "annotations" (printf "%s%s" $p $e) "" $sa)))) "true" -}}{{- $on = true -}}{{- end -}}
{{- end -}}
{{- if and $on $name $ns -}}
{{- $app := trim (toString (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa)) -}}
{{- if not $app -}}{{- $app = $name -}}{{- end -}}
{{- $k := printf "%s/%s" $ns $app -}}
{{- $_ := set $claims $k (append (index $claims $k | default (list)) $name | sortAlpha) -}}
{{- end -}}
{{- end -}}
{{- toYaml $claims -}}
{{- end -}}

{{/*
Reports a misconfiguration next to the object that carries it. No
`bao-config-<sa>` is rendered for a ServiceAccount with errors, so the pod fails
to start on the missing `configMapRef` and this object, beside it in the same
namespace, says why. Fixing the annotation replaces it with the real ConfigMap.
Usage: {{ include "openbao.errorConfigMap" (dict "name" $n "ns" $ns "labels" $labels "subject" $s "errors" $errs) }}
*/}}
{{- define "openbao.errorConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    {{- .labels | nindent 4 }}
data:
  ERROR: |
    OpenBao access has NOT been configured for {{ .subject }}.
    {{- range $i, $e := .errors }}
    {{ add1 $i }}. {{ $e }}
    {{- end }}
{{- end -}}

{{/*
Set of every k8s namespace this tenant owns, from the ServiceAccount and
Deployment lists the child TI resolves through its namespaceSelector. Used to
reject intra-tenant references pointing outside the tenant.
Usage (root context): {{ include "openbao.tenantNamespaces" . | fromYaml }}
*/}}
{{- define "openbao.tenantNamespaces" -}}
{{- $ns := dict -}}
{{- range $sa := (ternary .Values.serviceAccounts (list) (kindIs "slice" .Values.serviceAccounts)) -}}
{{- $n := dig "metadata" "namespace" "" $sa -}}
{{- if $n }}{{- $_ := set $ns $n true -}}{{- end -}}
{{- end -}}
{{- range $d := (ternary .Values.deployments (list) (kindIs "slice" .Values.deployments)) -}}
{{- $n := dig "metadata" "namespace" "" $d -}}
{{- if $n }}{{- $_ := set $ns $n true -}}{{- end -}}
{{- end -}}
{{- toYaml $ns -}}
{{- end -}}

{{/*
deletionPolicy for data-bearing kinds, from safety.deletionProtection:
true (default) -> Retain, false -> Delete. Read through openbao.strictBool:
a boolean or "true"/"false"; absent/null falls to Retain (the safe
direction); anything else fails the render — the guard survives
--skip-schema-validation, and a typo
must never silently change the posture. Call with $ inside ranges.
*/}}
{{- define "openbao.deletionPolicy" -}}
{{- $s := include "openbao.strictBool" (dict "from" .Values.safety "key" "deletionProtection" "name" "safety.deletionProtection" "why" "change the deletion posture") -}}
{{- ternary "Delete" "Retain" (eq $s "false") -}}
{{- end -}}

{{/*
deletionPolicy for grant kinds, from safety.grantDeletionProtection:
false (default) -> Delete, true -> Retain. Same guard as above with the
opposite safe direction: absent/null falls to Delete so revocation
never silently stops. Call with $ inside ranges.
*/}}
{{- define "openbao.grantDeletionPolicy" -}}
{{- $s := include "openbao.strictBool" (dict "from" .Values.safety "key" "grantDeletionProtection" "name" "safety.grantDeletionProtection" "why" "change the revocation posture") -}}
{{- ternary "Retain" "Delete" (eq $s "true") -}}
{{- end -}}
