{{- $env := .parameters.env }}
{{- $opNs := .parameters.operatorNamespace }}
{{- $tokenReviewerSecret := .parameters.tokenReviewerSecretName }}
{{- $kubeHost := .parameters.kubernetesHost }}
{{- $childTemplate := .parameters.childTemplateName }}
{{- $tenantLabel := .parameters.tenantLabelKey }}
{{- $shared := .parameters.sharedTenantName }}
{{- $ssoEnabled := .parameters.ssoEnabled }}
{{- $ssoIssuerUrl := .parameters.ssoIssuerUrl }}
{{- $eso := .parameters.eso }}
{{- $esoRefresh := .parameters.externalSecretRefreshInterval }}
{{- $certManager := .parameters.certManagerEnabled }}
{{- $crossTenantPki := .parameters.crossTenantPkiEnabled }}
{{- /* deletionPolicy for the shared tenant's data CRs. Only an exact
       "false" disables protection — anything unexpected fails toward
       Retain; the shared namespace holds every tenant's shared data. */ -}}
{{- $dataPolicy := ternary "Delete" "Retain" (eq .parameters.safetyDeletionProtection "false") }}
{{- /* Namespaces per tenant, counted from the <tenantLabel> label.
       This is the ONLY fact MTO and this chart both agree on. MTO puts that
       label on a namespace by either supported route: one listed in the Tenant
       spec (withTenantPrefix/withoutTenantPrefix), and one adopted by adding
       the label to a namespace that already exists. Reading spec.namespaces
       instead sees only the first route, so a tenant that adopts namespaces by
       label renders nothing at all — and the child TI, which resolves through a
       namespaceSelector on this same label, would have worked fine. It is also
       wrong the other way: a spec that lists namespaces MTO has not created yet
       passes, and the child then fails NamespaceSelectorMatchedZero, which is
       the very failure the gate exists to prevent. */ -}}
{{- $nsCount := dict }}
{{- range $ns := (default list .parameters.tenantNamespaces) }}
{{- $owner := dig "metadata" "labels" $tenantLabel "" $ns }}
{{- if $owner }}
{{- $_ := set $nsCount $owner (add1 (int (get $nsCount $owner))) }}
{{- end }}
{{- end }}
{{- /* Comma-separated roster of tenant names a share can usefully target.
       Gated on the same count as the render loop below: a tenant this parent
       emits nothing for cannot consume a share, so listing it would leave the
       peer holding a Policy and Role for an endpoint that does not exist. It
       self-heals — the peer re-renders when that tenant gets its first
       labelled namespace. */ -}}
{{- $tenantNames := list }}
{{- range $t := .parameters.tenants }}
{{- if gt (int (get $nsCount $t.metadata.name)) 0 }}
{{- $tenantNames = append $tenantNames $t.metadata.name }}
{{- end }}
{{- end }}
{{- $knownTenants := join "," $tenantNames }}
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoNamespace
metadata: { name: {{ $shared }}, namespace: {{ $opNs }} }
spec: { name: {{ $shared }}, deletionPolicy: {{ $dataPolicy }} }
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoSecretEngine
metadata: { name: {{ $shared }}-kv, namespace: {{ $opNs }} }
spec: { path: kv, openbaoNamespace: {{ $shared }}/, kvV2: {}, deletionPolicy: {{ $dataPolicy }} }
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoSecretEngine
metadata: { name: {{ $shared }}-transit, namespace: {{ $opNs }} }
spec:
  path: transit
  openbaoNamespace: {{ $shared }}/
  transit: {}
  deletionPolicy: {{ $dataPolicy }}
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoAuthMethod
metadata: { name: {{ $shared }}-kubernetes, namespace: {{ $opNs }} }
spec: { path: kubernetes, type: kubernetes, openbaoNamespace: {{ $shared }}/, deletionPolicy: {{ $dataPolicy }} }
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoKubernetesAuthEngineConfig
metadata: { name: {{ $shared }}-kubernetes-config, namespace: {{ $opNs }} }
spec:
  path: kubernetes
  openbaoNamespace: {{ $shared }}/
  kubernetesHost: {{ $kubeHost }}
  tokenReviewerJwtRef: { name: {{ $tokenReviewerSecret }} }
  kubernetesCaCertRef: { name: {{ $tokenReviewerSecret }}, key: ca.crt }
{{- range $t := .parameters.tenants }}
{{- $name := $t.metadata.name }}
{{- /* Skip a tenant with no labelled namespace. The child TI resolves
       serviceAccounts/deployments via a namespaceSelector (<tenantLabel>=
       <name>); with zero matching namespaces t-op-v2 fails parameter
       validation (NamespaceSelectorMatchedZero) and the child TI goes Failed.
       Emitting no child TI for an empty tenant keeps the parent green; it
       self-heals — the parent re-renders and emits the child once the tenant
       gets its first labelled namespace. Counted above from the label, not
       from spec.namespaces, so this asks exactly the question the child will
       answer. */ -}}
{{- $hasNs := gt (int (get $nsCount $name)) 0 }}
{{- if $hasNs }}
{{- /* One TI per enabled component, so a disabled integration has no TI at
       all. Optional suffixes use a dot because tenant names are RFC1123
       labels (no dots): with a hyphen, the core TI of tenant "<x>-eso" would
       collide with the eso TI of tenant "<x>". */ -}}
{{- $slices := list (dict "suffix" "" "tmpl" "") }}
{{- if eq $eso "enabled" }}{{- $slices = append $slices (dict "suffix" ".eso" "tmpl" "-eso") }}{{- end }}
{{- if eq $certManager "true" }}{{- $slices = append $slices (dict "suffix" ".certmanager" "tmpl" "-certmanager") }}{{- end }}
{{- if eq $crossTenantPki "true" }}{{- $slices = append $slices (dict "suffix" ".trust" "tmpl" "-trust") }}{{- end }}
{{- range $slice := $slices }}
---
apiVersion: templates.v2.stakater.com/v2alpha1
kind: TemplateInstance
metadata:
  name: openbao-config-mto-{{ $name }}{{ $slice.suffix }}
  namespace: {{ $opNs }}
spec:
  templateRef:
    name: {{ $childTemplate }}{{ $slice.tmpl }}
    namespace: {{ $opNs }}
  parameters:
    - name: tenant
      value: {{ $name }}
    - name: env
      value: {{ $env }}
    - name: ssoEnabled
      value: {{ $ssoEnabled | quote }}
{{- if $ssoIssuerUrl }}
    - name: ssoIssuerUrl
      value: {{ $ssoIssuerUrl | quote }}
{{- end }}
    - name: eso
      value: {{ $eso }}
    - name: externalSecretRefreshInterval
      value: {{ $esoRefresh | quote }}
    - name: sharedTenantName
      value: {{ $shared }}
    - name: knownTenants
      value: {{ $knownTenants | quote }}
    - name: serviceAccounts
      valueFrom:
        objectFieldRef:
          apiVersion: v1
          kind: ServiceAccount
          jsonPath: .items
          namespaceSelector:
            matchLabels:
              {{ $tenantLabel }}: {{ $name }}
    - name: deployments
      valueFrom:
        objectFieldRef:
          apiVersion: apps/v1
          kind: Deployment
          jsonPath: .items
          namespaceSelector:
            matchLabels:
              {{ $tenantLabel }}: {{ $name }}
{{- end }}
{{- end }}
{{- end }}
