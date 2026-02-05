# Engines, Policies, and Sharing Explained

## What is an Engine?

An **engine** (or "secrets engine") is a component in OpenBao that stores, generates, or encrypts data.

Think of it like different types of storage systems:

| Engine Type | What it does | Example Use |
|-------------|--------------|-------------|
| **KV v2** | Key-value store with versioning | Store passwords, API keys, config |
| **Transit** | Encryption-as-a-service | Encrypt/decrypt data without exposing keys |
| **PKI** | Certificate authority | Issue TLS certificates |
| **Database** | Dynamic credentials | Generate short-lived DB passwords |

---

## What is a Mount?

Engines must be **mounted** at a path to be used:

```
OpenBao
├── secret/          ← KV v2 engine mounted here
├── transit/         ← Transit engine mounted here
├── pki/             ← PKI engine mounted here
└── database/        ← Database engine mounted here
```

One engine type can be mounted multiple times at different paths:
```
├── secret/          ← KV v2 for general use
├── secret-prod/     ← KV v2 for production only
└── secret-staging/  ← KV v2 for staging only
```

---

## What is a Policy?

A **policy** defines WHO can do WHAT on WHICH paths.

```hcl
# Policy: acme-editor
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "list"]
}
```

This says: "Anyone with policy `acme-editor` can create/read/update/list secrets under `secret/data/tenants/acme/*`"

---

## How Many Engines Are Created?

**Answer: It depends on `mount.scope`**

### Scope: Cluster (Default)

```yaml
engines:
  - name: kv
    mount:
      path: secret
      scope: Cluster    # ← ONE mount for everyone
```

**Result: 1 engine mount total**

```
secret/                    ← Single KV v2 engine
├── tenants/acme/          ← Policy isolation
├── tenants/beta/          ← Policy isolation
├── tenants/platform/      ← Policy isolation
└── shared/                ← Global shared area
```

### Scope: Tenant

```yaml
engines:
  - name: kv
    mount:
      path: secret
      scope: Tenant     # ← ONE mount PER tenant
```

**Result: N engine mounts (one per tenant)**

```
secret-acme/               ← KV v2 engine for acme only
├── prod/
└── staging/

secret-beta/               ← KV v2 engine for beta only
├── prod/
└── staging/

secret-platform/           ← KV v2 engine for platform only
```

---

## Engine Count Summary

| Configuration | Engine Mounts Created |
|---------------|----------------------|
| `scope: Cluster` | **1 total** (shared by all tenants) |
| `scope: Tenant` | **N** (one per tenant) |
| `scope: Cluster` + sharing | **1 total** (policies handle isolation) |

**Key insight:** With `scope: Cluster`, you always have **1 engine**. Sharing is handled entirely by **policies**, not by creating more engines.

---

## How Engine is Shared Between Tenants

**Key concept:** The ENGINE (mount) is shared, but POLICIES restrict access to specific paths.

```
┌─────────────────────────────────────────────────────────────┐
│                    secret/ (KV v2 Engine)                   │
│                      SHARED MOUNT                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐  │
│  │ tenants/acme/*  │  │ tenants/beta/*  │  │  shared/*   │  │
│  │                 │  │                 │  │             │  │
│  │ Policy:         │  │ Policy:         │  │ Policy:     │  │
│  │ acme-editor     │  │ beta-editor     │  │ shared-ro   │  │
│  │ (RW)            │  │ (RW)            │  │ (RO)        │  │
│  └─────────────────┘  └─────────────────┘  └─────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

# Sharing Types

## 1. Global Shared (Current Design)

One "platform" tenant owns shared secrets, ALL other tenants can read.

```yaml
shared:
  enabled: true
  path: "secret/shared"
  ownerTenantRef:
    name: platform         # Platform WRITES
  consumers:
    tenantSelector: "*"    # Everyone READS
```

```
                    ┌─────────────────────┐
                    │  platform (owner)   │
                    │  CAN WRITE          │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │   secret/shared/    │
                    │   (global secrets)  │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │   acme   │    │   beta   │    │  gamma   │
        │ CAN READ │    │ CAN READ │    │ CAN READ │
        └──────────┘    └──────────┘    └──────────┘
```

**This is NOT acme ↔ beta sharing. This is platform → everyone sharing.**

---

## 2. Bilateral Sharing (Tenant-to-Tenant)

Sharing secrets between SPECIFIC tenants only.

### Option A: Cross-Tenant Policy (Manual)

Create a policy that gives beta read access to specific acme paths:

```hcl
# Policy: acme-to-beta-readonly
path "secret/data/tenants/acme/prod/shared-with-beta/*" {
  capabilities = ["read", "list"]
}
```

Attach this policy to beta's roles.

### Option B: Extended CR Design for Bilateral Sharing

```yaml
engines:
  - name: kv
    type: kv-v2
    mount:
      path: secret
      scope: Cluster

    # Tenant-to-tenant sharing
    tenantSharing:
      - name: acme-beta-shared
        path: "secret/bilateral/acme-beta"
        owners:
          - acme      # Can write
          - beta      # Can write

      - name: acme-exports
        path: "secret/exports/acme"
        owner: acme   # Only acme can write
        readers:
          - beta      # Beta can read
          - gamma     # Gamma can read
```

**This would create:**

```
secret/
├── tenants/
│   ├── acme/              ← Private to acme
│   └── beta/              ← Private to beta
├── bilateral/
│   └── acme-beta/         ← Shared between acme AND beta (both RW)
├── exports/
│   └── acme/              ← Acme writes, beta+gamma read
└── shared/                ← Global (platform owns, all read)
```

---

## Visual: Cluster Scope with All Sharing Types

```
secret/                              ← 1 KV v2 ENGINE
│
├── tenants/                         ← PRIVATE (per-tenant)
│   ├── acme/                        Policy: only acme
│   ├── beta/                        Policy: only beta
│   └── platform/                    Policy: only platform
│
├── shared/                          ← GLOBAL SHARED
│   └── *                            Policy: platform=RW, others=RO
│
├── bilateral/                       ← BILATERAL SHARED
│   └── acme-beta/                   Policy: acme=RW, beta=RW
│
└── exports/                         ← ONE-WAY SHARED
    └── acme/                        Policy: acme=RW, beta=RO, gamma=RO
```

**Still only 1 engine mount!** Policies do all the access control.

---

# Practical Example: Two Tenants Sharing KV Engine

## Setup

- **Tenant 1:** `acme` (e-commerce company)
  - Namespaces: `acme-payments`, `acme-frontend`
  - Users: Alice (owner), Bob (editor)

- **Tenant 2:** `beta` (fintech startup)
  - Namespaces: `beta-api`, `beta-worker`
  - Users: Charlie (owner), Dave (viewer)

- **Shared:** Global secrets owned by `platform` tenant

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
      sharedKv: "secret/shared/{{ .name }}"

  tenancy:
    mode: path
    defaults:
      env: prod

  tenantRoleMapping:
    owner:
      policyTier: admin    # Full access
    editor:
      policyTier: editor   # RW, no delete
    viewer:
      policyTier: viewer   # Read-only

  engines:
    - name: kv
      type: kv-v2
      enabled: true
      layoutRef: kv
      mount:
        path: secret           # Single shared mount
        manage: Adopt
        scope: Cluster         # Cluster-wide (not per-tenant)
      policies:
        presets: [admin, editor, viewer]
      rbac:
        granularity: namespace
        defaultTier: editor

      # Shared secrets configuration
      shared:
        enabled: true
        layoutRef: sharedKv
        path: "secret/shared"
        ownerTenantRef:
          name: platform       # "platform" tenant owns shared secrets
        consumers:
          tenantSelector: "*"  # All tenants can read
          workloads:
            mode: ro           # Pods get read-only
          tenantRoleMapping:
            owner: viewer      # Human owners get read-only to shared
            editor: viewer
            viewer: none       # Human viewers get nothing

      injection:
        mode: external-secrets
        secretStore:
          scope: namespace
          name: openbao
```

---

## What the Operator Creates

### Policies for Tenant "acme"

**acme-admin** (for Alice - owner):
```hcl
# Full access to acme's secrets
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/tenants/acme/*" {
  capabilities = ["read", "list", "delete"]
}

# Read-only access to shared secrets
path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/shared/*" {
  capabilities = ["read", "list"]
}
```

**acme-editor** (for Bob - editor):
```hcl
# RW access to acme's secrets (no delete)
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "secret/metadata/tenants/acme/*" {
  capabilities = ["read", "list"]
}

# Read-only access to shared secrets
path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}
```

**acme-payments-editor** (for workloads in acme-payments namespace):
```hcl
# Namespace-scoped access
path "secret/data/tenants/acme/prod/acme-payments/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "secret/metadata/tenants/acme/prod/acme-payments/*" {
  capabilities = ["read", "list"]
}

# Read-only access to shared secrets
path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}
```

### Policies for Tenant "beta"

**beta-admin** (for Charlie - owner):
```hcl
# Full access to beta's secrets
path "secret/data/tenants/beta/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/tenants/beta/*" {
  capabilities = ["read", "list", "delete"]
}

# Read-only access to shared secrets
path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}
```

**beta-viewer** (for Dave - viewer):
```hcl
# Read-only access to beta's secrets
path "secret/data/tenants/beta/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/tenants/beta/*" {
  capabilities = ["read", "list"]
}

# No access to shared (tenantRoleMapping.viewer: none)
```

### Policies for Tenant "platform" (shared owner)

**platform-admin**:
```hcl
# Full access to platform's own secrets
path "secret/data/tenants/platform/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# WRITE access to shared secrets (owner)
path "secret/data/shared/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/shared/*" {
  capabilities = ["read", "list", "delete"]
}
```

---

## Resulting Access Matrix

### Human Users

| User | Tenant | Role | acme/* | beta/* | shared/* |
|------|--------|------|--------|--------|----------|
| Alice | acme | owner | **RW+D** | ❌ | RO |
| Bob | acme | editor | **RW** | ❌ | RO |
| Charlie | beta | owner | ❌ | **RW+D** | RO |
| Dave | beta | viewer | ❌ | **RO** | ❌ |
| Platform CI | platform | owner | ❌ | ❌ | **RW+D** |

### Workloads

| Workload | Namespace | acme/* | beta/* | shared/* |
|----------|-----------|--------|--------|----------|
| Pod in acme-payments | acme-payments | **RW** (scoped) | ❌ | RO |
| Pod in beta-api | beta-api | ❌ | **RW** (scoped) | RO |

---

## Visual: How Secrets Are Organized

```
secret/                              ← Single KV v2 mount (SHARED)
├── tenants/
│   ├── acme/                        ← Tenant "acme" boundary
│   │   └── prod/
│   │       ├── acme-payments/       ← Namespace
│   │       │   └── checkout/        ← App
│   │       │       ├── db           ← Secret: DB credentials
│   │       │       └── stripe       ← Secret: Stripe API key
│   │       └── acme-frontend/
│   │           └── web/
│   │               └── config
│   │
│   ├── beta/                        ← Tenant "beta" boundary
│   │   └── prod/
│   │       ├── beta-api/
│   │       │   └── main/
│   │       │       └── db
│   │       └── beta-worker/
│   │
│   └── platform/                    ← Tenant "platform" (shared owner)
│       └── prod/
│           └── infra/
│
└── shared/                          ← Global shared secrets
    ├── global-config                ← Available to all tenants (RO)
    ├── feature-flags
    └── external-api-keys
```

---

## What Happens When Alice (acme owner) Tries to Access beta's Secrets?

```
Alice authenticates via OIDC
    ↓
Gets token with policy: acme-admin
    ↓
Tries: GET /v1/secret/data/tenants/beta/prod/beta-api/main/db
    ↓
OpenBao checks: Does "acme-admin" policy allow this path?
    ↓
Policy only allows: secret/data/tenants/acme/*
    ↓
DENIED (403 Forbidden)
```

---

# Example: Acme Shares Database Credentials with Beta

## Scenario
- Acme has a shared database that Beta's apps also need to access
- Acme should be able to update credentials
- Beta should only read

## CR Configuration with Tenant Sharing

```yaml
engines:
  - name: kv
    type: kv-v2
    mount:
      path: secret
      scope: Cluster

    # Global shared (owned by platform)
    shared:
      enabled: true
      path: "secret/shared"
      ownerTenantRef:
        name: platform
      consumers:
        tenantSelector: "*"
        workloads:
          mode: ro

    # Tenant-to-tenant sharing
    tenantSharing:
      - name: acme-shared-db
        path: "secret/cross-tenant/acme-shared-db"
        owner: acme
        readers:
          - beta
```

## Resulting Policies

**acme-admin** (acme owner):
```hcl
# Private acme secrets
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Acme's cross-tenant share (WRITE)
path "secret/data/cross-tenant/acme-shared-db/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

**beta-admin** (beta owner):
```hcl
# Private beta secrets
path "secret/data/tenants/beta/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Acme's cross-tenant share (READ ONLY)
path "secret/data/cross-tenant/acme-shared-db/*" {
  capabilities = ["read", "list"]
}
```

## Secret Structure

```
secret/
├── tenants/
│   ├── acme/prod/...           ← Only acme
│   └── beta/prod/...           ← Only beta
├── cross-tenant/
│   └── acme-shared-db/         ← Acme writes, beta reads
│       └── postgres            ← Shared DB credentials
└── shared/                     ← Platform writes, all read
```

## Access Matrix for Cross-Tenant Sharing

| Path | acme | beta | platform |
|------|------|------|----------|
| `tenants/acme/*` | **RW** | ❌ | ❌ |
| `tenants/beta/*` | ❌ | **RW** | ❌ |
| `cross-tenant/acme-shared-db/*` | **RW** | **RO** | ❌ |
| `shared/*` | RO | RO | **RW** |

---

# Summary

## Sharing Types

| Sharing Type | Who Writes | Who Reads | Engine Count |
|--------------|------------|-----------|--------------|
| **Private** | Tenant | Same tenant | 1 (cluster) or N (tenant) |
| **Global Shared** | Platform tenant | All tenants | Same engine |
| **Bilateral** | Both tenants | Both tenants | Same engine |
| **One-way Export** | Owner tenant | Specific tenants | Same engine |

## Key Concepts

| Concept | What it is | Example |
|---------|------------|---------|
| **Engine** | Type of secrets backend | KV v2, Transit, PKI |
| **Mount** | Path where engine is accessible | `/secret`, `/transit` |
| **Mount Scope** | Cluster (shared) vs Tenant (isolated) | `scope: Cluster` |
| **Policy** | Access rules for paths | `acme-editor` |
| **Policy Tier** | Capability level | admin/editor/viewer |
| **Shared** | Global secrets readable by all | `secret/shared/*` |
| **Tenant Sharing** | Secrets shared between specific tenants | `secret/cross-tenant/*` |
