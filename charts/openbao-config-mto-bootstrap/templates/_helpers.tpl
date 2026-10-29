{{/*
Drift-protection block (t-op-v2 Template spec.sync) rendered from
.Values.sync. sync.mode is validated against off|revert|strict at render
time (unquoted YAML booleans like `on` arrive here as bool true). An absent
or null mode falls back to the chart default — Helm drops null-valued keys
during coalesce, so both reach here as a missing key — while an explicitly
empty string fails. Either way a wrapper chart passing an unset variable
cannot silently ship without drift protection. Emits nothing when mode is
"off" so opted-out installs render byte-identical to charts without this
block.
Include in every Template this chart installs:

  {{- with include "openbao-config-mto-bootstrap.templateSync" . }}
  {{- . | nindent 2 }}
  {{- end }}
*/}}
{{/*
Integration toggles, validated and normalised in one place.

Every toggle in this chart is consumed as a STRING comparison
(`eq … "true"` / `eq … "enabled"`), because the value travels through a
t-op-v2 Template parameter, which is typed string. That makes a typo silent:
`yes`, `on`, `True` and `1` all fail the comparison, so the integration
renders no Template, no TemplateInstance and no grant — and says nothing.

These helpers `fail` on anything that is not a canonical value. They also
return the canonical string, but be clear about what that is and is not worth:
for every value they ACCEPT, the canonical form already equals what
`.Values.<toggle> | quote` would have produced, so routing a parameter through
a helper does not change the rendered output. The point is the guard, not the
conversion. Stamping parameters through the helpers is a belt-and-braces
choice: it means no site can consume a toggle without validating it, so a
future call site added in a file that happens to do no comparison cannot
reintroduce the silent-typo behaviour.

Downstream that gives files/parent-gotemplate.tpl — which t-op-v2 renders with
its own engine, where this chart's validation cannot reach — a guarantee that
its parameters are only ever "true"/"false" or "enabled"/"disabled". That is
why the gotemplate carries no guard of its own: one there would fail the parent
TemplateInstance and take every tenant's config down to catch a value this
boundary has already rejected.

values.schema.json enforces the same accepted set at the Helm boundary and is
what a user actually hits. Keep the two in step — the schema's `boolish`
definition and `boolValue` below must accept exactly the same values. The
schema is the better error message; these guards are what survive
`--skip-schema-validation` (helm >= 3.16) and SDK render paths that do not
apply it.

Never compare .Values.<toggle> directly — go through the named helper.
*/}}
{{- define "openbao-config-mto-bootstrap.boolValue" -}}
{{- $raw := .value -}}
{{- $s := "" -}}
{{- if kindIs "invalid" $raw -}}
{{- $s = "false" -}}
{{- else -}}
{{- $s = toString $raw -}}
{{- end -}}
{{- if not (has $s (list "true" "false")) -}}
{{- fail (printf "%s must be a boolean true or false — got %q. Quoted \"true\"/\"false\" also work; anything else (yes, on, 1, True, TRUE) is silently NOT enabled, so it is rejected here instead." .name $s) -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{- define "openbao-config-mto-bootstrap.esoMode" -}}
{{- $raw := .Values.parent.eso -}}
{{- $s := "" -}}
{{- if kindIs "invalid" $raw -}}
{{- $s = "disabled" -}}
{{- else -}}
{{- $s = toString $raw -}}
{{- end -}}
{{- if not (has $s (list "enabled" "disabled")) -}}
{{- fail (printf "parent.eso must be \"enabled\" or \"disabled\" — got %q. It is a string, not a boolean: true/false/yes/on are silently NOT enabled, so they are rejected here instead." $s) -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{- define "openbao-config-mto-bootstrap.certManagerEnabled" -}}
{{- include "openbao-config-mto-bootstrap.boolValue" (dict "name" "parent.certManager.enabled" "value" .Values.parent.certManager.enabled) -}}
{{- end -}}

{{- define "openbao-config-mto-bootstrap.crossTenantPkiEnabled" -}}
{{- include "openbao-config-mto-bootstrap.boolValue" (dict "name" "crossTenantPki.enabled" "value" .Values.crossTenantPki.enabled) -}}
{{- end -}}

{{- define "openbao-config-mto-bootstrap.platformPkiEnabled" -}}
{{- include "openbao-config-mto-bootstrap.boolValue" (dict "name" "platformPki.enabled" "value" .Values.platformPki.enabled) -}}
{{- end -}}

{{/* parent.sso is nullable, and a chained deref through it nil-pointers the
     whole bootstrap render. `parent` itself is required by values.schema.json. */}}
{{- define "openbao-config-mto-bootstrap.parentSso" -}}
{{- toYaml ((.Values.parent | default dict).sso | default dict) -}}
{{- end -}}

{{- define "openbao-config-mto-bootstrap.ssoEnabled" -}}
{{- $sso := include "openbao-config-mto-bootstrap.parentSso" . | fromYaml -}}
{{- $on := include "openbao-config-mto-bootstrap.boolValue" (dict "name" "parent.sso.enabled" "value" $sso.enabled) -}}
{{- if eq $on "true" -}}{{- include "openbao-config-mto-bootstrap.ssoClientCheck" $sso -}}{{- end -}}
{{- $on -}}
{{- end -}}

{{/*
Fails the render when SSO is on and clientId, clientSecretRef.name,
clientSecretRef.key or audience is empty or null. The oidc mounts need the
client and its secret, and every SSO role binds the token's aud claim to
audience. The schema's minLength cannot catch a null: helm drops null keys
before it validates. Expects the parent.sso map.
*/}}
{{- define "openbao-config-mto-bootstrap.ssoClientCheck" -}}
{{- $sso := . -}}
{{- $mount := "the oidc mounts log in with it" -}}
{{- $secret := "the oidc mounts read the client secret through it" -}}
{{- range $v := list (list "clientId" $sso.clientId $mount) (list "clientSecretRef.name" (dig "clientSecretRef" "name" "" $sso) $secret) (list "clientSecretRef.key" (dig "clientSecretRef" "key" "" $sso) $secret) (list "audience" $sso.audience "every SSO role binds the token's aud claim to it") -}}
{{- if not (index $v 1) -}}
{{- fail (printf "parent.sso.enabled=true requires parent.sso.%s — %s" (index $v 0) (index $v 2)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
parent.sso.sharedSpace.enabled, normalized to "true"/"false". The parent renders
the shared space's oidc mount from it, and the child Templates pass it to the
tenant chart, which renders the roles on that mount; one helper for both, so
neither side is on alone. With SSO also on, it needs the issuer and tenant chart
0.21.0 or later: an older tenant chart renders no role on the mount, so nobody
can log in, and no status says why.
*/}}
{{- define "openbao-config-mto-bootstrap.ssoSharedSpaceEnabled" -}}
{{- $sso := include "openbao-config-mto-bootstrap.parentSso" . | fromYaml -}}
{{- if and (hasKey $sso "sharedSpace") (not (kindIs "invalid" $sso.sharedSpace)) (not (kindIs "map" $sso.sharedSpace)) -}}
{{- fail (printf "parent.sso.sharedSpace must be a map with an `enabled` key — got %q. `sharedSpace: true` is not read as on." (toString $sso.sharedSpace)) -}}
{{- end -}}
{{- $on := include "openbao-config-mto-bootstrap.boolValue" (dict "name" "parent.sso.sharedSpace.enabled" "value" (dig "sharedSpace" "enabled" nil $sso)) -}}
{{- if and (eq $on "true") (eq (include "openbao-config-mto-bootstrap.ssoEnabled" .) "true") -}}
{{- if not $sso.issuerUrl -}}
{{- fail "parent.sso.sharedSpace.enabled=true requires parent.sso.issuerUrl — the shared space's oidc mount discovers the IdP through it" -}}
{{- end -}}
{{- $ver := toString ((.Values.openbaoConfigMto | default dict).version | default "") -}}
{{- /* Anchored at both ends: sprig's semverCompare fails the render with its
       own raw error on anything else (0.19.0abc), not with this message. */ -}}
{{- if not (regexMatch "^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$" $ver) -}}
{{- fail (printf "openbaoConfigMto.version %q is not a semantic version" $ver) -}}
{{- end -}}
{{- if not (semverCompare ">=0.21.0-0" $ver) -}}
{{- fail (printf "parent.sso.sharedSpace.enabled=true needs openbao-config-mto 0.21.0 or later, and openbaoConfigMto.version is %q: an older tenant chart renders no role on the shared mount, so nobody can log in and no status says why" $ver) -}}
{{- end -}}
{{- end -}}
{{- $on -}}
{{- end -}}

{{- define "openbao-config-mto-bootstrap.templateSync" -}}
{{- $sync := .Values.sync | default dict -}}
{{- $mode := "revert" -}}
{{- if hasKey $sync "mode" -}}
{{- $mode = $sync.mode | toString -}}
{{- end -}}
{{- if not (has $mode (list "off" "revert" "strict")) -}}
{{- fail (printf "sync.mode must be one of off, revert, strict — got %q (unquoted on/yes/true parse as YAML booleans; quote the value)" $mode) -}}
{{- end -}}
{{- if ne $mode "off" -}}
sync:
  mode: {{ $mode }}
{{- with $sync.ignoreFields }}
  ignoreFields:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Safety knobs normalized to "true"/"false" via boolValue. Absent/null
falls to each knob's safe direction (protection ON, grant retention
OFF), mirroring the operator's zero-value handling.
*/}}
{{- define "openbao-config-mto-bootstrap.safetyDeletionProtection" -}}
{{- $safety := .Values.safety | default dict -}}
{{- /* hasKey first: sprig get returns "" (not nil) for a missing key. */ -}}
{{- if or (not (hasKey $safety "deletionProtection")) (kindIs "invalid" (get $safety "deletionProtection")) -}}true{{- else -}}
{{- $raw := get $safety "deletionProtection" -}}
{{- include "openbao-config-mto-bootstrap.boolValue" (dict "name" "safety.deletionProtection" "value" $raw) -}}
{{- end -}}
{{- end -}}

{{- define "openbao-config-mto-bootstrap.safetyGrantDeletionProtection" -}}
{{- $safety := .Values.safety | default dict -}}
{{- /* hasKey first: sprig get returns "" (not nil) for a missing key. */ -}}
{{- if or (not (hasKey $safety "grantDeletionProtection")) (kindIs "invalid" (get $safety "grantDeletionProtection")) -}}false{{- else -}}
{{- $raw := get $safety "grantDeletionProtection" -}}
{{- include "openbao-config-mto-bootstrap.boolValue" (dict "name" "safety.grantDeletionProtection" "value" $raw) -}}
{{- end -}}
{{- end -}}

{{/*
deletionPolicy for the data-bearing CRs this chart renders itself
(the platform-PKI OpenBaoNamespace and OpenBaoSecretEngine).
*/}}
{{- define "openbao-config-mto-bootstrap.deletionPolicy" -}}
{{- ternary "Retain" "Delete" (eq (include "openbao-config-mto-bootstrap.safetyDeletionProtection" .) "true") -}}
{{- end -}}
