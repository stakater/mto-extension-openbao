# Complete OpenBaoExtension CR Example

This document provides a complete, production-ready CR with all fields explained.

---

## Full CR

```yaml
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoExtension
metadata:
  name: cluster-default
  namespace: mto-system
spec:
  # ============================================================================
  # SERVER - Connection to OpenBao
  # ============================================================================
  server:
    # OpenBao server URL
    url: https://bao.example.com:8200

    # Secret containing the operator's OpenBao token (least-privilege)
    tokenSecretRef:
      name: openbao-credentials
      key: token

    # Optional: CA bundle for TLS verification
    # caBundleSecretRef:
    #   name: openbao-ca
    #   key: ca.crt

    # Optional: Skip TLS verification (dev only!)
    # insecureSkipVerify: false

  # ============================================================================
  # AUTH MANAGEMENT - Which auth backends operator manages
  # ============================================================================
  authManagement:
    kubernetes: Ensure    # Ensure | Off - Manage auth/kubernetes for workloads
    oidc: Ensure          # Ensure | Off - Manage auth/oidc for humans

  # ============================================================================
  # SSO - Single Sign-On for human users via OIDC
  # ============================================================================
  sso:
    mode: inline          # secret | inline | disabled

    # When mode: secret
    # secretRef:
    #   name: sso-openbao-config

    # When mode: inline
    inline:
      issuer: https://dex.example.com
      clientId: openbao
      clientSecretRef:
        name: sso-openbao-client
        key: clientSecret
      groupsClaim: groups
      redirectUris:
        - https://bao.example.com/ui/vault/auth/oidc/oidc/callback
        - https://bao.example.com/v1/auth/oidc/oidc/callback

    # How to extract tenant role from IdP groups
    roleResolution:
      patterns:
        - role: owner
          match: "tenant-{{ .Tenant }}-owners"
        - role: editor
          match: "tenant-{{ .Tenant }}-editors"
        - role: viewer
          match: "tenant-{{ .Tenant }}-viewers"
      tieBreakStrategy: highest   # highest | lowest | deny
      fallback: deny              # deny | viewer | editor | owner

  # ============================================================================
  # TENANCY - Path schema and isolation model
  # ============================================================================
  tenancy:
    mode: path            # path (OSS) | namespace (Enterprise)
    defaults:
      env: prod           # Default environment for path templates

  # ============================================================================
  # LAYOUT - Reusable path templates
  # ============================================================================
  layout:
    templates:
      # Tenant-private secrets
      kv: "secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}"
      # Shared secrets (multiple areas supported)
      sharedGlobal: "secret/shared/global/{{ .name }}"
      sharedTeamA: "secret/shared/team-a/{{ .name }}"
      sharedTeamB: "secret/shared/team-b/{{ .name }}"
      # Transit key naming
      transitKey: "ten-{{ .tenant }}-{{ .namespace }}-{{ .app }}"
      # PKI mount path
      pkiMount: "pki/tenants/{{ .tenant }}"

  # ============================================================================
  # TENANT ROLE MAPPING - MTO roles → OpenBao policy tiers
  # ============================================================================
  tenantRoleMapping:
    # Tenant owners get admin policies
    owner:
      policyTier: admin
      pattern: "tenant-{{ .Tenant }}-owners"

    # Tenant editors get editor policies
    editor:
      policyTier: editor
      pattern: "tenant-{{ .Tenant }}-editors"

    # Tenant viewers get viewer policies (or 'none' to deny)
    viewer:
      policyTier: viewer
      pattern: "tenant-{{ .Tenant }}-viewers"

    # Optional: Override default capabilities per tier
    policyOverrides:
      admin:
        capabilities: [create, read, update, delete, list]
      editor:
        capabilities: [create, read, update, list]    # no delete
      viewer:
        capabilities: [read, list]

  # ============================================================================
  # ENGINES - Secret engines configuration
  # ============================================================================
  engines:
    # --------------------------------------------------------------------------
    # KV v2 Engine (Primary)
    # --------------------------------------------------------------------------
    - name: kv
      type: kv-v2
      enabled: true
      layoutRef: kv

      # Mount configuration
      mount:
        path: secret
        manage: Adopt       # Off | Adopt | Ensure
        scope: Cluster      # Cluster (shared) | Tenant (per-tenant mounts)

      # Policy presets to generate
      policies:
        presets: [admin, editor, viewer]

      # RBAC for workloads (Kubernetes auth)
      rbac:
        granularity: namespace    # namespace | app
        defaultTier: editor       # Default policy tier for workloads
        tokenTTL: "1h"
        tokenMaxTTL: "4h"

      # Shared secret areas (array - multiple areas supported)
      shared:
        # Global shared (owned by platform, readable by ALL)
        - name: global
          enabled: true
          layoutRef: sharedGlobal
          path: "secret/shared/global"

          ownerTenantRef:
            name: platform

          consumers:
            tenantSelector: "*"     # "*" = all tenants
            workloads:
              mode: ro              # ro | none
            tenantRoleMapping:
              owner: viewer         # Tenant owners get read-only to shared
              editor: viewer        # Tenant editors get read-only to shared
              viewer: none          # Tenant viewers get no shared access

        # Team-A shared (owned by team-a, readable by specific tenants)
        - name: team-a-exports
          enabled: true
          layoutRef: sharedTeamA
          path: "secret/shared/team-a"

          ownerTenantRef:
            name: team-a

          consumers:
            tenantSelector: "team-b,team-c"
            workloads:
              mode: ro
            tenantRoleMapping:
              owner: viewer
              editor: viewer
              viewer: none

      # How secrets reach pods
      injection:
        mode: external-secrets    # external-secrets | csi | none
        secretStore:
          scope: namespace        # namespace | cluster
          name: openbao

    # --------------------------------------------------------------------------
    # Transit Engine (Optional - Encryption as a Service)
    # --------------------------------------------------------------------------
    - name: transit
      type: transit
      enabled: false              # Set to true to enable
      layoutRef: transitKey

      mount:
        path: transit
        manage: Adopt
        scope: Cluster

      policies:
        presets: [admin]

      rbac:
        granularity: app
        defaultTier: admin
        tokenTTL: "1h"
        tokenMaxTTL: "4h"

      transit:
        autoCreateKeyPerApp: true
        keyType: "aes256-gcm96"

      injection:
        mode: none

    # --------------------------------------------------------------------------
    # PKI Engine (Optional - Certificate Authority)
    # --------------------------------------------------------------------------
    - name: pki
      type: pki
      enabled: false              # Set to true to enable
      layoutRef: pkiMount

      mount:
        path: pki
        manage: Ensure
        scope: Tenant             # Per-tenant PKI mounts

      policies:
        presets: [admin, viewer]

      rbac:
        granularity: namespace
        defaultTier: viewer       # Workloads can read certs
        tokenTTL: "1h"
        tokenMaxTTL: "4h"

      pki:
        maxLeaseTTL: "8760h"      # 1 year
        intermediate: true
        roles:
          - name: "{{ .tenant }}-svc"
            allowedDomains:
              - "{{ .namespace }}.svc.cluster.local"
            allowSubdomains: true
            maxTTL: "720h"        # 30 days

      injection:
        mode: none

  # ============================================================================
  # SCAFFOLDING - Auto-create K8s resources for apps
  # ============================================================================
  scaffolding:
    mode: OnAnnotation      # OnAnnotation | Always | Never
    annotations:
      enable: "mto.secrets/enable"
      keys: "mto.secrets/keys"
      sharedKeys: "mto.secrets/sharedKeys"   # Format: "area:key,area:key"
      env: "mto.secrets/env"

  # ============================================================================
  # SAFETY - Guardrails for production
  # ============================================================================
  safety:
    deletionProtection: true    # Operator never deletes OpenBao resources
    allowDeletes: false         # Strip "delete" capability from policies

  # ============================================================================
  # DELETION POLICY - What happens on CR/tenant deletion
  # ============================================================================
  deletionPolicy: Orphan        # Orphan | Delete
```

---

## What This CR Creates

### For Each Tenant (e.g., "acme")

#### Policies

**acme-admin (for tenant owners):**
```hcl
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "list"]  # delete stripped by safety
}
path "secret/metadata/tenants/acme/*" {
  capabilities = ["read", "list"]
}
# READ access to global shared (consumer)
path "secret/data/shared/global/*" {
  capabilities = ["read", "list"]
}
# READ access to team-a shared (if acme is in consumer list)
path "secret/data/shared/team-a/*" {
  capabilities = ["read", "list"]
}
```

**acme-editor (for tenant editors):**
```hcl
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "secret/metadata/tenants/acme/*" {
  capabilities = ["read", "list"]
}
# READ access to global shared
path "secret/data/shared/global/*" {
  capabilities = ["read", "list"]
}
# READ access to team-a shared (if acme is in consumer list)
path "secret/data/shared/team-a/*" {
  capabilities = ["read", "list"]
}
```

**acme-viewer (for tenant viewers):**
```hcl
path "secret/data/tenants/acme/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/tenants/acme/*" {
  capabilities = ["read", "list"]
}
# No shared access (tenantRoleMapping.viewer: none)
```

#### Namespace-scoped Policies (for workloads)

**acme-payments-editor (for pods in acme-payments namespace):**
```hcl
path "secret/data/tenants/acme/prod/acme-payments/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "secret/metadata/tenants/acme/prod/acme-payments/*" {
  capabilities = ["read", "list"]
}
# READ access to global shared
path "secret/data/shared/global/*" {
  capabilities = ["read", "list"]
}
# READ access to team-a shared (if acme is in consumer list)
path "secret/data/shared/team-a/*" {
  capabilities = ["read", "list"]
}
```

#### Kubernetes Auth Roles

```json
{
  "name": "ten-acme-ns-acme-payments-editor",
  "bound_service_account_names": ["default"],
  "bound_service_account_namespaces": ["acme-payments"],
  "policies": ["acme-payments-editor"],
  "token_ttl": "1h",
  "token_max_ttl": "4h"
}
```

#### Identity Groups (for OIDC)

```
Group: acme-owners
  - Policies: [acme-admin]
  - Alias: "tenant-acme-owners" (from IdP)

Group: acme-editors
  - Policies: [acme-editor]
  - Alias: "tenant-acme-editors" (from IdP)

Group: acme-viewers
  - Policies: [acme-viewer]
  - Alias: "tenant-acme-viewers" (from IdP)
```

#### SecretStore (ESO)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: openbao
  namespace: acme-payments
spec:
  provider:
    vault:
      server: "https://bao.example.com:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "ten-acme-ns-acme-payments-editor"
          serviceAccountRef:
            name: "default"
```

---

## RBAC Summary

### Granularity Levels

| Granularity | Roles Created | Use Case |
|-------------|---------------|----------|
| `namespace` | One role per namespace | Simple, most common |
| `app` | One role per app ServiceAccount | Tighter isolation |

### Policy Tiers

| Tier | Capabilities (default) | Capabilities (with allowDeletes: true) |
|------|------------------------|----------------------------------------|
| `admin` | create, read, update, list | create, read, update, delete, list |
| `editor` | create, read, update, list | create, read, update, list |
| `viewer` | read, list | read, list |
| `none` | (no policy attached) | (no policy attached) |

### Role to Tier Mapping

| Who | Tenant Role | Policy Tier | Access |
|-----|-------------|-------------|--------|
| **Human (OIDC)** | owner | admin | Full tenant access + shared RO |
| **Human (OIDC)** | editor | editor | RW tenant access + shared RO |
| **Human (OIDC)** | viewer | viewer | RO tenant access, no shared |
| **Workload (K8s)** | - | editor (default) | RW namespace access + shared RO |

---

## Complete Access Matrix

### Tenant "acme" with namespaces: acme-payments, acme-frontend

| Entity | Type | tenants/acme/* | acme-payments/* | acme-frontend/* | shared/global/* | shared/team-a/* |
|--------|------|----------------|-----------------|-----------------|-----------------|-----------------|
| Alice (owner) | Human | **RW** | RW | RW | RO | RO* |
| Bob (editor) | Human | **RW** | RW | RW | RO | RO* |
| Carol (viewer) | Human | **RO** | RO | RO | ❌ | ❌ |
| Pod in acme-payments | Workload | ❌ | **RW** | ❌ | RO | RO* |
| Pod in acme-frontend | Workload | ❌ | ❌ | **RW** | RO | RO* |

*Only if acme is in team-a's consumer list (tenantSelector)

### Tenant "platform" (global shared owner)

| Entity | Type | tenants/platform/* | shared/global/* |
|--------|------|-------------------|-----------------|
| Platform CI (owner) | Human/SA | **RW** | **RW** |

### Tenant "team-a" (team-a shared owner)

| Entity | Type | tenants/team-a/* | shared/global/* | shared/team-a/* |
|--------|------|------------------|-----------------|-----------------|
| team-a owners | Human | **RW** | RO | **RW** |

---

## Usage Example

### Developer Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: acme-payments
  annotations:
    mto.secrets/enable: "true"
    mto.secrets/keys: "db,stripe"
    # Format: "area:key,area:key" for multiple shared areas
    mto.secrets/sharedKeys: "global:feature-flags,team-a:api-creds"
spec:
  template:
    spec:
      containers:
        - name: api
          envFrom:
            - secretRef:
                name: checkout-api-db
            - secretRef:
                name: checkout-api-stripe
            - secretRef:
                name: checkout-api-global-feature-flags
            - secretRef:
                name: checkout-api-team-a-api-creds
```

### Secrets in OpenBao

```
# Written by acme team (tenant-private)
secret/tenants/acme/prod/acme-payments/checkout-api/db
  └── username: admin
  └── password: secret123

secret/tenants/acme/prod/acme-payments/checkout-api/stripe
  └── api_key: sk_live_xxx

# Written by platform team (global shared)
secret/shared/global/feature-flags
  └── enable_new_checkout: true
  └── max_items: 100

# Written by team-a (team-a shared)
secret/shared/team-a/api-creds
  └── api_key: xxx
  └── api_secret: yyy
```

### Generated ExternalSecrets

```yaml
# For tenant-private secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-api-db
  namespace: acme-payments
spec:
  secretStoreRef:
    name: openbao
  target:
    name: checkout-api-db
  dataFrom:
    - extract:
        key: secret/data/tenants/acme/prod/acme-payments/checkout-api/db

# For global shared secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-api-global-feature-flags
  namespace: acme-payments
spec:
  secretStoreRef:
    name: openbao
  target:
    name: checkout-api-global-feature-flags
  dataFrom:
    - extract:
        key: secret/data/shared/global/feature-flags

# For team-a shared secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-api-team-a-api-creds
  namespace: acme-payments
spec:
  secretStoreRef:
    name: openbao
  target:
    name: checkout-api-team-a-api-creds
  dataFrom:
    - extract:
        key: secret/data/shared/team-a/api-creds
```

---

## Environment-Specific Examples

### Production

```yaml
spec:
  safety:
    deletionProtection: true
    allowDeletes: false
  deletionPolicy: Orphan

  engines:
    - name: kv
      rbac:
        tokenTTL: "1h"
        tokenMaxTTL: "4h"
```

### Staging

```yaml
spec:
  safety:
    deletionProtection: true
    allowDeletes: true        # Allow cleanup of test secrets
  deletionPolicy: Orphan

  tenancy:
    defaults:
      env: staging
```

### Development

```yaml
spec:
  safety:
    deletionProtection: false  # Allow full cleanup
    allowDeletes: true
  deletionPolicy: Delete       # Clean teardown

  tenancy:
    defaults:
      env: dev

  engines:
    - name: kv
      rbac:
        tokenTTL: "8h"         # Longer TTL for dev
        tokenMaxTTL: "24h"
```

---

## Minimal CR (Defaults Applied)

```yaml
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoExtension
metadata:
  name: cluster-default
  namespace: mto-system
spec:
  server:
    url: https://bao.example.com:8200
    tokenSecretRef:
      name: openbao-credentials
      key: token

  layout:
    templates:
      kv: "secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}"

  engines:
    - name: kv
      type: kv-v2
      layoutRef: kv
      mount:
        path: secret
```

All other fields use sensible defaults:
- `authManagement`: Both Ensure
- `sso.mode`: disabled
- `tenancy.mode`: path
- `tenancy.defaults.env`: prod
- `scaffolding.mode`: OnAnnotation
- `safety.deletionProtection`: true
- `safety.allowDeletes`: false
- `deletionPolicy`: Orphan
