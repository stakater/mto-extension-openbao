{{/*
Returns the JSON-list capabilities string for a tier.
Usage:  {{ include "openbao.tierCaps" (dict "tier" "editor" "tierCaps" .Values.tierCaps) }}
*/}}
{{- define "openbao.tierCaps" -}}
{{- index .tierCaps .tier -}}
{{- end -}}

{{/*
Per-SA own-tenant role/policy name: <tenant>-<saNs>-<sa>-<tier>.
Usage:  {{ include "openbao.roleName" (dict "tenant" $tenant "saNs" $saNs "saName" $saName "tier" $tier) }}
*/}}
{{- define "openbao.roleName" -}}
{{- printf "%s-%s-%s-%s" .tenant .saNs .saName .tier -}}
{{- end -}}

{{/*
Cross-tenant share-out role/policy name: share-<tenant>-<saNs>-<sa>-out-<peer>.
*/}}
{{- define "openbao.shareOutName" -}}
{{- printf "share-%s-%s-%s-out-%s" .tenant .saNs .saName .peer -}}
{{- end -}}

{{/*
Cross-tenant share-in role/policy name: share-<tenant>-<saNs>-<sa>-in-<peer>.
*/}}
{{- define "openbao.shareInName" -}}
{{- printf "share-%s-%s-%s-in-%s" .tenant .saNs .saName .peer -}}
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
Substitutes {tenant} in a string. Used for transit/pki templated values.
Usage:  {{ include "openbao.subTenant" (dict "tenant" $tenant "s" "{tenant}.svc.cluster.local") }}
*/}}
{{- define "openbao.subTenant" -}}
{{- replace "{tenant}" .tenant .s -}}
{{- end -}}

{{/*
Per-tenant transit key CR name: transit-<tenant>-<keyName>.
*/}}
{{- define "openbao.transitKeyName" -}}
{{- printf "transit-%s-%s" .tenant .keyName -}}
{{- end -}}

{{/*
Per-tenant PKI role CR name: pki-<tenant>-<roleName>.
*/}}
{{- define "openbao.pkiRoleName" -}}
{{- printf "pki-%s-%s" .tenant .roleName -}}
{{- end -}}

{{/*
Cross-tenant transit share-out policy/role name:
  share-transit-<tenant>-<saNs>-<sa>-out-<peer>.
*/}}
{{- define "openbao.transitShareOutName" -}}
{{- printf "share-transit-%s-%s-%s-out-%s" .tenant .saNs .saName .peer -}}
{{- end -}}

{{/*
Cross-tenant transit share-in policy/role name:
  share-transit-<tenant>-<saNs>-<sa>-in-<peer>.
*/}}
{{- define "openbao.transitShareInName" -}}
{{- printf "share-transit-%s-%s-%s-in-%s" .tenant .saNs .saName .peer -}}
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
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: helm-via-template-operator-v2
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ .Values.tenantLabelKey }}: {{ required ".Values.tenant must be set by the parent" .Values.tenant }}
{{- end -}}

{{/*
Validates that every entry in a workload SA's CSV annotation refers to a
key/role name declared in chart values. Fails the helm render with a
clear message when a typo is found; bypasses when the gating
strictAnnotationValidation flag is false.

Usage:
  {{ include "openbao.validateCsvAgainstCatalog" (dict
       "csv" $transitRaw "catalog" $.Values.transit.keys
       "annotation" "bao.stakater.com/transit-keys"
       "saName" $saName "saNs" $saNs "strict" $.Values.transit.strictAnnotationValidation) }}
*/}}
{{- define "openbao.validateCsvAgainstCatalog" -}}
{{- if and .strict .csv -}}
{{- $known := list -}}
{{- range $entry := .catalog -}}{{- $known = append $known $entry.name -}}{{- end -}}
{{- range $name := splitList "," .csv -}}
{{- $name = trim $name -}}
{{- if and $name (not (has $name $known)) -}}
{{- fail (printf "SA %s/%s annotation %s references %q which is not in the chart catalog %v. Either add it to values, fix the typo, or set strictAnnotationValidation=false." $.saNs $.saName $.annotation $name $known) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
