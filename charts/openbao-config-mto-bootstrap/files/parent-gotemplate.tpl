{{- $env := .parameters.env }}
{{- $opNs := .parameters.operatorNamespace }}
{{- $tokenReviewerSecret := .parameters.tokenReviewerSecretName }}
{{- $kubeHost := .parameters.kubernetesHost }}
{{- $childTemplate := .parameters.childTemplateName }}
{{- $tenantLabel := .parameters.tenantLabelKey }}
{{- $shared := .parameters.sharedTenantName }}
{{- $ssoEnabled := .parameters.ssoEnabled }}
{{- $ssoIssuerUrl := .parameters.ssoIssuerUrl }}
{{- $ssoSharedSpace := .parameters.ssoSharedSpace }}
{{- $eso := .parameters.eso }}
{{- $esoRefresh := .parameters.externalSecretRefreshInterval }}
{{- $certManager := .parameters.certManagerEnabled }}
{{- $crossTenantPki := .parameters.crossTenantPkiEnabled }}
{{- /* deletionPolicy for the shared tenant's data CRs. Only an exact
       "false" disables protection — anything unexpected fails toward
       Retain; the shared namespace holds every tenant's shared data. */ -}}
{{- $dataPolicy := ternary "Delete" "Retain" (eq .parameters.safetyDeletionProtection "false") }}
{{- /* Comma-separated roster of all real tenant names. Passed to each child so
       its chart can skip cross-tenant shares whose peer is not a real tenant
       (no dangling Policy/Role; self-heals when the peer appears). */ -}}
{{- $tenantNames := list }}
{{- range $t := .parameters.tenants }}{{- $tenantNames = append $tenantNames $t.metadata.name }}{{- end }}
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
{{- /* People's login to the shared space: one oidc mount for every tenant, on
       the same IdP client as the tenant mounts. Each tenant's chart adds its
       own roles to it (07-sso-shared-space.yaml). The bootstrap chart fails its
       render when the issuer or the client is empty, so none is empty here. */ -}}
{{- if and (eq $ssoEnabled "true") (eq $ssoSharedSpace "true") }}
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoAuthMethod
metadata: { name: {{ $shared }}-oidc, namespace: {{ $opNs }} }
spec: { path: oidc, type: oidc, openbaoNamespace: {{ $shared }}/, deletionPolicy: {{ $dataPolicy }} }
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoJWTOIDCAuthEngineConfig
metadata: { name: {{ $shared }}-oidc-config, namespace: {{ $opNs }} }
spec:
  path: oidc
  openbaoNamespace: {{ $shared }}/
  oidcDiscoveryUrl: {{ $ssoIssuerUrl | quote }}
  {{- if .parameters.ssoCaBundlePem }}
  oidcDiscoveryCaPem: {{ .parameters.ssoCaBundlePem | toJson }}
  {{- end }}
  oidcClientId: {{ .parameters.ssoClientId | quote }}
  oidcClientSecretRef: { name: {{ .parameters.ssoClientSecretName | quote }}, key: {{ .parameters.ssoClientSecretKey | quote }} }
{{- end }}
{{- range $t := .parameters.tenants }}
{{- $name := $t.metadata.name }}
{{- /* Skip tenants that declare no namespaces. The child TI resolves
       serviceAccounts/deployments via a namespaceSelector
       (<tenantLabel>=<name>); with zero matching namespaces t-op-v2 fails
       parameter validation (NamespaceSelectorMatchedZero) and the child TI
       goes Failed. Emitting no child TI for an empty tenant keeps the parent
       green; it self-heals — the parent re-renders and emits the child once
       the tenant declares its first namespace. */ -}}
{{- $tns := default dict $t.spec.namespaces }}
{{- $hasNs := or (gt (len (default list $tns.withTenantPrefix)) 0) (gt (len (default list $tns.withoutTenantPrefix)) 0) }}
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
