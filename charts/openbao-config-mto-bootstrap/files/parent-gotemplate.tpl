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
spec: { name: {{ $shared }} }
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoSecretEngine
metadata: { name: {{ $shared }}-kv, namespace: {{ $opNs }} }
spec: { path: kv, openbaoNamespace: {{ $shared }}/, kvV2: {} }
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoSecretEngine
metadata: { name: {{ $shared }}-transit, namespace: {{ $opNs }} }
spec:
  path: transit
  openbaoNamespace: {{ $shared }}/
  transit: {}
---
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoAuthMethod
metadata: { name: {{ $shared }}-kubernetes, namespace: {{ $opNs }} }
spec: { path: kubernetes, type: kubernetes, openbaoNamespace: {{ $shared }}/ }
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
---
apiVersion: templates.v2.stakater.com/v2alpha1
kind: TemplateInstance
metadata:
  name: openbao-config-mto-{{ $name }}
  namespace: {{ $opNs }}
spec:
  templateRef:
    name: {{ $childTemplate }}
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
