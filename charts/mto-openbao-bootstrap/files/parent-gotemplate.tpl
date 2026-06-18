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
---
apiVersion: templates.v2.stakater.com/v2alpha1
kind: TemplateInstance
metadata:
  name: mto-openbao-tenant-{{ $name }}
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
    - name: ssoIssuerUrl
      value: {{ $ssoIssuerUrl | quote }}
    - name: eso
      value: {{ $eso }}
    - name: externalSecretRefreshInterval
      value: {{ $esoRefresh | quote }}
    - name: sharedTenantName
      value: {{ $shared }}
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
