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
Per-SA own-tenant role/policy name: <tenant>-<saNs>-<sa>-<tier>.
Usage:  {{ include "openbao.roleName" (dict "tenant" $tenant "saNs" $saNs "saName" $saName "tier" $tier) }}
*/}}
{{- define "openbao.roleName" -}}
{{- include "openbao.assertName" (printf "%s-%s-%s-%s" .tenant .saNs .saName .tier) -}}
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
Per-tenant PKI role CR name: pki-<tenant>-<roleName>.
*/}}
{{- define "openbao.pkiRoleName" -}}
{{- printf "pki-%s-%s" .tenant .roleName -}}
{{- end -}}

{{/*
The tenant's ORIGINAL PKI mount path — the one this chart has always created.
In hierarchy mode the tenant CA is a type=intermediate rendered at a FRESH
mount (pki.hierarchy.mountPath) so it never reuses a root-bearing mount;
otherwise it's the self-signed root at pki.mountPath.

This is the mount whose CRs carry the unsuffixed names (<tenant>-pki,
<tenant>-pki-root). Use openbao.pkiActiveMount for the mount that should
actually issue certificates — the two differ during a CA replacement.
Usage (root context): {{ include "openbao.pkiMount" . }}
*/}}
{{- define "openbao.pkiMount" -}}
{{- $pki := .Values.pki -}}
{{- if and $pki.hierarchy $pki.hierarchy.enabled -}}
{{- $pki.hierarchy.mountPath -}}
{{- else -}}
{{- $pki.mountPath -}}
{{- end -}}
{{- end -}}

{{/*
Every PKI mount this chart renders scaffolding for. Empty pki.mounts means just
the original mount, which is what every install had before CA replacement
existed. A mount stays in this list for as long as its CA must remain valid:
removing it deletes its OpenBaoSecretEngine, which unmounts the path and
destroys the CA and private key along with every cert that CA signed.
Usage (root context): {{ include "openbao.pkiAllMounts" . }} -> space-separated
*/}}
{{- define "openbao.pkiAllMounts" -}}
{{- $all := list -}}
{{- range $m := (default (list) .Values.pki.mounts) -}}
{{- $m = trim (toString $m) -}}
{{- if and $m (not (has $m $all)) -}}{{- $all = append $all $m -}}{{- end -}}
{{- end -}}
{{- if not $all -}}{{- $all = list (include "openbao.pkiMount" .) -}}{{- end -}}
{{- join " " $all -}}
{{- end -}}

{{/*
The mount that issues certificates: pki.activeMount when set, else the
original. Roles, SA policies, SSO grants and cert-manager Issuers all resolve
through this so they move together in one step. Fails when activeMount names a
mount this chart does not render — otherwise every PKI grant would silently
point at a path that does not exist.
Usage (root context): {{ include "openbao.pkiActiveMount" . }}
*/}}
{{- define "openbao.pkiActiveMount" -}}
{{- $active := trim (toString (default "" .Values.pki.activeMount)) -}}
{{- if not $active -}}
{{- include "openbao.pkiMount" . -}}
{{- else -}}
{{- $all := splitList " " (include "openbao.pkiAllMounts" .) -}}
{{- if not (has $active $all) -}}
{{- fail (printf "pki.activeMount=%q is not a rendered mount (have: %s) — add it to pki.mounts first, or the tenant's PKI grants would point at a path that does not exist" $active (join ", " $all)) -}}
{{- end -}}
{{- $active -}}
{{- end -}}
{{- end -}}

{{/*
CR-name suffix for a PKI mount. The original mount keeps the historical
unsuffixed names so an upgrade never renames an existing CR: renaming an
OpenBaoSecretEngine's spec.path unmounts the old path, which destroys the CA.
Extra mounts get "-<mount>".
Usage: {{ include "openbao.pkiCRSuffix" (dict "mount" $m "root" $) }}
*/}}
{{- define "openbao.pkiCRSuffix" -}}
{{- if eq .mount (include "openbao.pkiMount" .root) -}}{{- else -}}-{{ .mount }}{{- end -}}
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
