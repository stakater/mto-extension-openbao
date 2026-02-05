# Tenancy Model Explained

## What is Tenancy Model?

**Purpose:** Defines how tenant secrets are isolated from each other in OpenBao.

```yaml
tenancy:
  mode: path        # path | namespace
  defaults:
    env: prod       # default environment
```

---

## The Two Modes

### Mode 1: `path` (Default, works everywhere)

Isolation via **path prefixes** within a shared secrets engine.

```
secret/                          ← Single KV mount (shared)
├── tenants/
│   ├── acme/                    ← Tenant "acme" secrets
│   │   ├── prod/
│   │   │   ├── acme-payments/   ← Namespace
│   │   │   │   └── api/db       ← Secret
│   │   │   └── acme-frontend/
│   │   └── staging/
│   ├── beta/                    ← Tenant "beta" secrets
│   │   └── prod/
│   └── platform/                ← Tenant "platform" secrets
└── shared/                      ← Global shared secrets
```

**How isolation works:**
- Policies restrict access by path
- Tenant "acme" gets policy: `path "secret/data/tenants/acme/*" { capabilities = [...] }`
- Tenant "acme" cannot access `secret/data/tenants/beta/*`

**Pros:**
- Works with OpenBao OSS (free)
- Simple setup
- Single mount to manage

**Cons:**
- Softer isolation (policy-based, not physical)
- All tenants share same storage backend

---

### Mode 2: `namespace` (Enterprise only)

Isolation via **OpenBao Enterprise namespaces**.

```
root/                            ← Root namespace
├── tenants/
│   ├── acme/                    ← Namespace for tenant "acme"
│   │   └── secret/              ← Dedicated KV mount
│   │       └── prod/
│   │           └── payments/
│   ├── beta/                    ← Namespace for tenant "beta"
│   │   └── secret/
│   └── platform/
└── secret/                      ← Root-level shared secrets
```

**How isolation works:**
- Each tenant gets a separate OpenBao namespace
- Namespaces are physically isolated
- Tenant "acme" literally cannot see "beta" namespace exists

**Pros:**
- Stronger isolation (physical separation)
- Separate audit logs per tenant
- Separate policies/auth per tenant
- Quotas per tenant

**Cons:**
- Requires OpenBao/Vault Enterprise
- More complex management
- More resources needed

---

## Path Template with Tenancy

The `tenancy.defaults.env` affects the secret path:

```yaml
tenancy:
  mode: path
  defaults:
    env: prod    # Default environment
```

**Path template:**
```
secret/tenants/{{ .tenant }}/{{ .env }}/{{ .namespace }}/{{ .app }}/{{ .name }}
```

**Example with defaults:**
```
Tenant: acme
Namespace: acme-payments
App: api
Secret: db
Env: (not specified, uses default "prod")

→ secret/tenants/acme/prod/acme-payments/api/db
```

**Example with override:**
```yaml
# App annotation
mto.secrets/env: "staging"

→ secret/tenants/acme/staging/acme-payments/api/db
```

---

## Visual Comparison

### Path Mode (OSS)
```
┌─────────────────────────────────────────────┐
│              OpenBao Server                 │
│  ┌───────────────────────────────────────┐  │
│  │         secret/ (KV mount)            │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │
│  │  │ acme/*  │ │ beta/*  │ │ gamma/* │  │  │
│  │  │(policy) │ │(policy) │ │(policy) │  │  │
│  │  └─────────┘ └─────────┘ └─────────┘  │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
         Shared mount, policy isolation
```

### Namespace Mode (Enterprise)
```
┌─────────────────────────────────────────────┐
│              OpenBao Server                 │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐  │
│  │ NS: acme  │ │ NS: beta  │ │ NS: gamma │  │
│  │ ┌───────┐ │ │ ┌───────┐ │ │ ┌───────┐ │  │
│  │ │secret/│ │ │ │secret/│ │ │ │secret/│ │  │
│  │ └───────┘ │ │ └───────┘ │ │ └───────┘ │  │
│  └───────────┘ └───────────┘ └───────────┘  │
└─────────────────────────────────────────────┘
         Separate namespaces, physical isolation
```

---

## When to Use Which

| Scenario | Recommended Mode |
|----------|------------------|
| Small/medium multi-tenant | `path` |
| Using OpenBao OSS | `path` (only option) |
| Strict compliance requirements | `namespace` |
| Need per-tenant audit logs | `namespace` |
| Need per-tenant quotas | `namespace` |
| Enterprise license available | `namespace` |

---

## What the Operator Does Differently

### Path Mode
```go
// Create policy with path prefix
policy := fmt.Sprintf(`
path "secret/data/tenants/%s/*" {
  capabilities = ["create", "read", "update", "list"]
}
`, tenantName)
```

### Namespace Mode
```go
// Create namespace first
client.CreateNamespace("tenants/" + tenantName)

// Then create resources INSIDE that namespace
client.SetNamespace("tenants/" + tenantName)
client.EnableSecretsEngine("secret", "kv-v2")
client.CreatePolicy("admin", policy)
```

---

## Environment Defaults

The `defaults.env` field provides the default environment for path templating:

```yaml
tenancy:
  defaults:
    env: prod
```

This is used when:
1. Building secret paths
2. App doesn't specify `mto.secrets/env` annotation
3. Creating policies and roles

**Common environments:**
- `prod` - Production
- `staging` - Staging/QA
- `dev` - Development

**Per-workload override:**
```yaml
metadata:
  annotations:
    mto.secrets/env: "staging"  # Override default "prod"
```

---

## Summary

| Aspect | `path` mode | `namespace` mode |
|--------|-------------|------------------|
| **Isolation** | Policy-based (soft) | Physical (hard) |
| **License** | OSS (free) | Enterprise |
| **Complexity** | Simple | Complex |
| **Path** | `secret/tenants/{tenant}/...` | `{tenant}/secret/...` |
| **Audit** | Shared logs | Per-tenant logs |
| **Quotas** | Not possible | Per-tenant quotas |

For most cases, **`path` mode is sufficient** and works with the free OpenBao. Use `namespace` mode only if you have Enterprise and need stronger isolation guarantees.
