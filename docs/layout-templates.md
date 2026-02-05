# Layout Templates Explained

## What is Layout?

**Purpose:** Defines reusable path templates for organizing secrets in OpenBao.

```yaml
layout:
  templates:
    kv: "secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}"
    sharedKv: "secret/shared/{{ .name }}"
    transitKey: "ten-{{ .tenant }}-{{ .namespace }}-{{ .app }}"
    pkiMount: "pki/tenants/{{ .tenant }}"
```

---

## Why Layout Exists

Instead of hardcoding paths everywhere, layout provides:
1. **Single source of truth** for path patterns
2. **Reusability** - engines reference templates by name
3. **Consistency** - all components use same path structure
4. **Flexibility** - change path structure in one place

---

## Template Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `{{ .tenant }}` | Tenant name | `acme` |
| `{{ .env }}` | Environment | `prod`, `staging` |
| `{{ .namespace }}` | Kubernetes namespace | `acme-payments` |
| `{{ .app }}` | Application name | `api` |
| `{{ .name }}` | Secret name | `db`, `config` |

---

## How Templates Are Used

### 1. Engine references a template

```yaml
layout:
  templates:
    kv: "secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}"

engines:
  - name: kv
    type: kv-v2
    layoutRef: kv    # ← References the "kv" template
```

### 2. Operator resolves the template

When creating policies/roles for tenant "acme", namespace "acme-payments":

```
Template: secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}
    ↓
Resolved: secret/tenants/acme/prod/acme-payments/*/*
    ↓
Policy path: secret/data/tenants/acme/prod/acme-payments/*
```

### 3. Apps write secrets to resolved paths

```
secret/tenants/acme/prod/acme-payments/api/db
  └── username: "admin"
  └── password: "secret123"
```

---

## Common Templates

### KV (Tenant secrets)
```yaml
kv: "secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}"
```
**Result:** `secret/tenants/acme/prod/acme-payments/api/db`

**Use case:** Per-tenant, per-namespace, per-app secrets

---

### Shared KV (Global secrets)
```yaml
sharedKv: "secret/shared/{{ .name }}"
```
**Result:** `secret/shared/global-config`

**Use case:** Secrets shared across all tenants (read-only for consumers)

---

### Transit Keys
```yaml
transitKey: "ten-{{ .tenant }}-{{ .namespace }}-{{ .app }}"
```
**Result:** `ten-acme-acme-payments-api`

**Use case:** Encryption-as-a-service key naming

---

### PKI Mount
```yaml
pkiMount: "pki/tenants/{{ .tenant }}"
```
**Result:** `pki/tenants/acme`

**Use case:** Per-tenant PKI/certificate authority

---

## Path Structure Breakdown

For the KV template:
```
secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}
│      │       │             │          │               │          │
│      │       │             │          │               │          └── Secret name (db, config, api-key)
│      │       │             │          │               └── App name (api, worker, frontend)
│      │       │             │          └── K8s namespace (acme-payments)
│      │       │             └── Environment (prod, staging, dev)
│      │       └── Tenant name (acme, beta)
│      └── Organizational folder
└── KV mount path
```

---

## How Policies Use Templates

The operator generates policies based on templates:

### Namespace-level policy (RBAC granularity: namespace)
```hcl
# For tenant "acme", namespace "acme-payments", env "prod"

# Data operations (create/read/update secrets)
path "secret/data/tenants/acme/prod/acme-payments/*" {
  capabilities = ["create", "read", "update", "list"]
}

# Metadata operations (list secrets, read versions)
path "secret/metadata/tenants/acme/prod/acme-payments/*" {
  capabilities = ["read", "list"]
}
```

### App-level policy (RBAC granularity: app)
```hcl
# For tenant "acme", namespace "acme-payments", app "api", env "prod"

path "secret/data/tenants/acme/prod/acme-payments/api/*" {
  capabilities = ["create", "read", "update", "list"]
}

path "secret/metadata/tenants/acme/prod/acme-payments/api/*" {
  capabilities = ["read", "list"]
}
```

---

## Relationship: Layout → Engine → Policy

```
┌─────────────────────────────────────────────────────────────┐
│ layout.templates.kv                                         │
│ "secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/" │
└─────────────────────────┬───────────────────────────────────┘
                          │ referenced by
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ engines[0]                                                  │
│   name: kv                                                  │
│   layoutRef: kv  ◄─────────────────────────────────────────│
│   mount.path: secret                                        │
└─────────────────────────┬───────────────────────────────────┘
                          │ generates
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ Policy: acme-payments-editor                                │
│ path "secret/data/tenants/acme/prod/acme-payments/*" {...}  │
└─────────────────────────────────────────────────────────────┘
```

---

## Environment Override

Default env comes from `tenancy.defaults.env`:

```yaml
tenancy:
  defaults:
    env: prod
```

Apps can override via annotation:
```yaml
metadata:
  annotations:
    mto.secrets/env: "staging"
```

**Result with override:**
```
secret/tenants/acme/staging/acme-payments/api/db
                    ↑
                    overridden from "prod" to "staging"
```

---

## Example: Full Path Resolution

**Given:**
- Tenant: `acme`
- Namespace: `acme-payments`
- App: `checkout-api`
- Secret: `stripe-key`
- Env: `prod` (default)

**Template:**
```
secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}
```

**Resolved:**
```
secret/tenants/acme/prod/acme-payments/checkout-api/stripe-key
```

**In OpenBao (KV v2):**
```
# Write secret
PUT /v1/secret/data/tenants/acme/prod/acme-payments/checkout-api/stripe-key
{
  "data": {
    "key": "sk_live_xxx",
    "webhook_secret": "whsec_xxx"
  }
}

# Read secret
GET /v1/secret/data/tenants/acme/prod/acme-payments/checkout-api/stripe-key
```

---

## Summary

| Aspect | Description |
|--------|-------------|
| **What** | Named path templates with Go templating |
| **Why** | DRY, consistency, single source of truth |
| **Where** | `spec.layout.templates` |
| **Used by** | Engines via `layoutRef` field |
| **Variables** | `.tenant`, `.env`, `.namespace`, `.app`, `.name` |
