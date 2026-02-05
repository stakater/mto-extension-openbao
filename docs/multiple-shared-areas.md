# Multiple Shared Secret Areas

This document explains how to configure multiple shared secret areas with different owners.

---

## Scenario

- **Platform** owns global shared secrets (readable by everyone)
- **Team-A** owns team-a shared secrets (readable by team-b, team-c, team-d)
- **Team-B** owns team-b shared secrets (readable by team-a, team-c only)

---

## CR Configuration

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
      # Multiple shared templates
      sharedGlobal: "secret/shared/global/{{ .name }}"
      sharedTeamA: "secret/shared/team-a/{{ .name }}"
      sharedTeamB: "secret/shared/team-b/{{ .name }}"

  tenancy:
    mode: path
    defaults:
      env: prod

  tenantRoleMapping:
    owner:
      policyTier: admin
    editor:
      policyTier: editor
    viewer:
      policyTier: viewer

  engines:
    - name: kv
      type: kv-v2
      enabled: true
      layoutRef: kv
      mount:
        path: secret
        manage: Adopt
        scope: Cluster

      policies:
        presets: [admin, editor, viewer]

      rbac:
        granularity: namespace
        defaultTier: editor
        tokenTTL: "1h"
        tokenMaxTTL: "4h"

      # ========================================================================
      # MULTIPLE SHARED AREAS
      # ========================================================================
      shared:
        # ----------------------------------------------------------------------
        # Global shared (owned by platform, readable by ALL)
        # ----------------------------------------------------------------------
        - name: global
          enabled: true
          layoutRef: sharedGlobal
          path: "secret/shared/global"

          ownerTenantRef:
            name: platform

          consumers:
            tenantSelector: "*"           # ALL tenants can read
            workloads:
              mode: ro
            tenantRoleMapping:
              owner: viewer
              editor: viewer
              viewer: none

        # ----------------------------------------------------------------------
        # Team-A shared (owned by team-a, readable by specific tenants)
        # ----------------------------------------------------------------------
        - name: team-a-exports
          enabled: true
          layoutRef: sharedTeamA
          path: "secret/shared/team-a"

          ownerTenantRef:
            name: team-a

          consumers:
            # Only these tenants can read team-a's shared secrets
            tenantSelector: "team-b,team-c,team-d"
            workloads:
              mode: ro
            tenantRoleMapping:
              owner: viewer
              editor: viewer
              viewer: none

        # ----------------------------------------------------------------------
        # Team-B shared (owned by team-b, readable by specific tenants)
        # ----------------------------------------------------------------------
        - name: team-b-exports
          enabled: true
          layoutRef: sharedTeamB
          path: "secret/shared/team-b"

          ownerTenantRef:
            name: team-b

          consumers:
            # Only team-a and team-c can read team-b's shared secrets
            tenantSelector: "team-a,team-c"
            workloads:
              mode: ro
            tenantRoleMapping:
              owner: viewer
              editor: none      # Only owners get access
              viewer: none

      injection:
        mode: external-secrets
        secretStore:
          scope: namespace
          name: openbao

  scaffolding:
    mode: OnAnnotation
    annotations:
      enable: "mto.secrets/enable"
      keys: "mto.secrets/keys"
      sharedKeys: "mto.secrets/sharedKeys"      # Format: "global:config,team-a:db-creds"
      env: "mto.secrets/env"

  safety:
    deletionProtection: true
    allowDeletes: false

  deletionPolicy: Orphan
```

---

## What This Creates

### Secret Structure

```
secret/
├── tenants/
│   ├── platform/...        ← Platform's private secrets
│   ├── team-a/...          ← Team-A's private secrets
│   ├── team-b/...          ← Team-B's private secrets
│   ├── team-c/...          ← Team-C's private secrets
│   └── team-d/...          ← Team-D's private secrets
│
└── shared/
    ├── global/             ← Platform owns, EVERYONE reads
    │   ├── feature-flags
    │   ├── external-apis
    │   └── common-config
    │
    ├── team-a/             ← Team-A owns, team-b/c/d read
    │   ├── shared-db-creds
    │   └── api-keys
    │
    └── team-b/             ← Team-B owns, team-a/c read
        ├── ml-model-keys
        └── data-lake-creds
```

---

## Access Matrix

### Who Can Write (RW)

| Shared Area | Owner | Can Write |
|-------------|-------|-----------|
| `shared/global/*` | platform | platform only |
| `shared/team-a/*` | team-a | team-a only |
| `shared/team-b/*` | team-b | team-b only |

### Who Can Read (RO)

| Shared Area | Consumers | team-a | team-b | team-c | team-d | platform |
|-------------|-----------|--------|--------|--------|--------|----------|
| `shared/global/*` | `*` (all) | RO | RO | RO | RO | **RW** |
| `shared/team-a/*` | team-b,c,d | **RW** | RO | RO | RO | ❌ |
| `shared/team-b/*` | team-a,c | RO | **RW** | RO | ❌ | ❌ |

---

## Generated Policies

### For Team-A (owner of team-a shared)

```hcl
# team-a-admin policy

# Private tenant secrets
path "secret/data/tenants/team-a/*" {
  capabilities = ["create", "read", "update", "list"]
}

# WRITE access to team-a shared (owner)
path "secret/data/shared/team-a/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "secret/metadata/shared/team-a/*" {
  capabilities = ["read", "list"]
}

# READ access to global shared
path "secret/data/shared/global/*" {
  capabilities = ["read", "list"]
}

# READ access to team-b shared (consumer)
path "secret/data/shared/team-b/*" {
  capabilities = ["read", "list"]
}
```

### For Team-B (owner of team-b shared, consumer of team-a)

```hcl
# team-b-admin policy

# Private tenant secrets
path "secret/data/tenants/team-b/*" {
  capabilities = ["create", "read", "update", "list"]
}

# WRITE access to team-b shared (owner)
path "secret/data/shared/team-b/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "secret/metadata/shared/team-b/*" {
  capabilities = ["read", "list"]
}

# READ access to global shared
path "secret/data/shared/global/*" {
  capabilities = ["read", "list"]
}

# READ access to team-a shared (consumer)
path "secret/data/shared/team-a/*" {
  capabilities = ["read", "list"]
}
```

### For Team-C (consumer only)

```hcl
# team-c-admin policy

# Private tenant secrets
path "secret/data/tenants/team-c/*" {
  capabilities = ["create", "read", "update", "list"]
}

# READ access to global shared
path "secret/data/shared/global/*" {
  capabilities = ["read", "list"]
}

# READ access to team-a shared
path "secret/data/shared/team-a/*" {
  capabilities = ["read", "list"]
}

# READ access to team-b shared
path "secret/data/shared/team-b/*" {
  capabilities = ["read", "list"]
}
```

### For Team-D (limited consumer)

```hcl
# team-d-admin policy

# Private tenant secrets
path "secret/data/tenants/team-d/*" {
  capabilities = ["create", "read", "update", "list"]
}

# READ access to global shared
path "secret/data/shared/global/*" {
  capabilities = ["read", "list"]
}

# READ access to team-a shared ONLY
path "secret/data/shared/team-a/*" {
  capabilities = ["read", "list"]
}

# NO access to team-b shared (not in consumer list)
```

---

## Visual: Sharing Relationships

```
                    ┌─────────────────────┐
                    │      platform       │
                    │  (global owner)     │
                    └──────────┬──────────┘
                               │ OWNS
                               ▼
                    ┌─────────────────────┐
                    │  shared/global/*    │
                    └──────────┬──────────┘
                               │ ALL READ
        ┌──────────┬───────────┼───────────┬──────────┐
        ▼          ▼           ▼           ▼          ▼
    ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
    │team-a  │ │team-b  │ │team-c  │ │team-d  │ │platform│
    └───┬────┘ └───┬────┘ └────────┘ └────────┘ └────────┘
        │          │
        │ OWNS     │ OWNS
        ▼          ▼
┌──────────────┐  ┌──────────────┐
│shared/team-a │  │shared/team-b │
└──────┬───────┘  └──────┬───────┘
       │                 │
       │ READ BY:        │ READ BY:
       │ team-b ✓        │ team-a ✓
       │ team-c ✓        │ team-c ✓
       │ team-d ✓        │ team-d ✗
       │ platform ✗      │ platform ✗
```

---

## Using Shared Secrets in Apps

### Annotation Format for Multiple Shared Areas

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: team-c-app
  annotations:
    mto.secrets/enable: "true"
    mto.secrets/keys: "db,api"                           # Private secrets
    mto.secrets/sharedKeys: "global:config,team-a:creds,team-b:ml-keys"
    #                        ↑       ↑      ↑      ↑      ↑       ↑
    #                        area    key    area   key    area    key
```

### Generated ExternalSecrets

```yaml
# Private secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-db
  namespace: team-c-app
spec:
  secretStoreRef:
    name: openbao
  target:
    name: my-app-db
  dataFrom:
    - extract:
        key: secret/data/tenants/team-c/prod/team-c-app/my-app/db

# Global shared
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-global-config
  namespace: team-c-app
spec:
  secretStoreRef:
    name: openbao
  target:
    name: my-app-global-config
  dataFrom:
    - extract:
        key: secret/data/shared/global/config

# Team-A shared
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-team-a-creds
  namespace: team-c-app
spec:
  secretStoreRef:
    name: openbao
  target:
    name: my-app-team-a-creds
  dataFrom:
    - extract:
        key: secret/data/shared/team-a/creds

# Team-B shared
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-team-b-ml-keys
  namespace: team-c-app
spec:
  secretStoreRef:
    name: openbao
  target:
    name: my-app-team-b-ml-keys
  dataFrom:
    - extract:
        key: secret/data/shared/team-b/ml-keys
```

---

## Type Definition Update

To support multiple shared areas, the `shared` field becomes an array:

```go
// SharedSpec defines a shared secret area
type SharedSpec struct {
    // Name identifies this shared area (e.g., "global", "team-a-exports")
    // +required
    Name string `json:"name"`

    // Enabled controls whether this shared area is active
    // +optional
    // +default=true
    Enabled bool `json:"enabled,omitempty"`

    // LayoutRef references a template from layout.templates
    // +required
    LayoutRef string `json:"layoutRef"`

    // Path is the full path prefix for this shared area
    // +required
    Path string `json:"path"`

    // OwnerTenantRef identifies the tenant that owns this shared area
    // +required
    OwnerTenantRef TenantRef `json:"ownerTenantRef"`

    // Consumers defines who can read this shared area
    // +optional
    Consumers SharedConsumersSpec `json:"consumers,omitempty"`
}

// In EngineSpec, shared becomes an array
type EngineSpec struct {
    // ... other fields ...

    // Shared defines shared secret areas (multiple allowed)
    // +optional
    Shared []SharedSpec `json:"shared,omitempty"`
}
```

---

## tenantSelector Options

| Selector | Meaning |
|----------|---------|
| `"*"` | All tenants |
| `"team-a,team-b"` | Only team-a and team-b |
| `"!platform"` | All except platform (future) |
| Label selector (future) | `"env=prod"` |

---

## Summary

| Feature | Single Shared | Multiple Shared |
|---------|---------------|-----------------|
| **CR field** | `shared: {}` | `shared: []` |
| **Owners** | 1 tenant | N tenants |
| **Areas** | 1 path | N paths |
| **Consumer control** | Global or all | Per-area granular |
| **Annotation format** | `sharedKeys: "key1,key2"` | `sharedKeys: "area:key,area:key"` |

---

## Common Patterns

### Pattern 1: Global + Team Exports

```yaml
shared:
  - name: global
    ownerTenantRef: { name: platform }
    consumers: { tenantSelector: "*" }

  - name: team-a-exports
    ownerTenantRef: { name: team-a }
    consumers: { tenantSelector: "team-b,team-c" }
```

### Pattern 2: Bidirectional Sharing

```yaml
shared:
  - name: team-a-to-team-b
    ownerTenantRef: { name: team-a }
    consumers: { tenantSelector: "team-b" }

  - name: team-b-to-team-a
    ownerTenantRef: { name: team-b }
    consumers: { tenantSelector: "team-a" }
```

### Pattern 3: Hub and Spoke

```yaml
shared:
  - name: hub-secrets
    ownerTenantRef: { name: platform }
    consumers: { tenantSelector: "*" }
    # All spokes read from hub, none write
```
