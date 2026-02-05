# Safety & DeletionPolicy Explained

These are **guardrails** to prevent accidental data loss or destructive operations.

---

## Safety

**Purpose:** Controls what destructive operations the operator is allowed to perform.

```yaml
safety:
  deletionProtection: true    # Never delete OpenBao resources
  allowDeletes: false         # Strip "delete" capability from policies
```

---

### deletionProtection

Controls whether the operator can DELETE resources in OpenBao.

| Value | Operator Can Delete |
|-------|---------------------|
| `true` (default) | **NO** - Create/update only |
| `false` | Yes - Full lifecycle management |

**When `deletionProtection: true`:**
```
Operator actions:
  ✅ Create policy
  ✅ Update policy
  ❌ Delete policy         ← BLOCKED

  ✅ Create auth role
  ✅ Update auth role
  ❌ Delete auth role      ← BLOCKED

  ✅ Enable auth mount
  ❌ Disable auth mount    ← BLOCKED
```

**Why?** In production, you don't want a bug or misconfiguration to wipe out:
- Policies (locking out users)
- Auth roles (breaking workload auth)
- Identity groups (breaking OIDC)

---

### allowDeletes

Controls whether the **"delete" capability** is included in generated policies.

| Value | "delete" in policies |
|-------|----------------------|
| `false` (default) | **NO** - Stripped from all policies |
| `true` | Yes - Included for admin tier |

**When `allowDeletes: false`:**
```hcl
# Admin policy (delete REMOVED)
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "list"]  # no "delete"
}
```

**When `allowDeletes: true`:**
```hcl
# Admin policy (delete INCLUDED)
path "secret/data/tenants/acme/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

**Why?** In KV v2:
- `delete` hides a secret version (soft delete)
- `destroy` permanently deletes (hard delete)
- By default, prevent even soft deletes to avoid accidents

---

## DeletionPolicy

**Purpose:** Controls what happens to OpenBao resources when the CR or tenant is deleted from Kubernetes.

```yaml
deletionPolicy: Orphan    # Orphan | Delete
```

### Orphan (Default, Recommended)

When CR/tenant is deleted → **Keep OpenBao resources**

```
Before deletion:
  K8s: Tenant "acme" exists
  OpenBao: policies, roles, secrets exist

After deletion:
  K8s: Tenant "acme" GONE
  OpenBao: policies, roles, secrets STILL EXIST ← Orphaned
```

**Why Orphan?**
- Secrets are valuable, don't lose them accidentally
- Can recreate tenant and reconnect to existing secrets
- Audit trail preserved
- Safe for production

### Delete

When CR/tenant is deleted → **Delete OpenBao resources**

```
Before deletion:
  K8s: Tenant "acme" exists
  OpenBao: policies, roles, secrets exist

After deletion:
  K8s: Tenant "acme" GONE
  OpenBao: policies, roles DELETED, secrets ???
```

**What gets deleted:**
- ✅ Policies (e.g., `acme-admin`, `acme-editor`)
- ✅ Auth roles (e.g., `ten-acme-ns-acme-payments-editor`)
- ✅ Identity groups and aliases
- ❓ Secrets - **depends on `safety.deletionProtection`**

**Why Delete?**
- Dev/test environments
- Clean teardown needed
- Ephemeral tenants

---

## Interaction Matrix

| deletionProtection | allowDeletes | deletionPolicy | Behavior |
|--------------------|--------------|----------------|----------|
| `true` | `false` | `Orphan` | **Safest** - No deletes anywhere |
| `true` | `false` | `Delete` | Contradictory - Delete blocked by protection |
| `true` | `true` | `Orphan` | Users can delete secrets, operator can't delete resources |
| `false` | `false` | `Orphan` | Operator can delete, users can't delete secrets |
| `false` | `true` | `Delete` | **Most dangerous** - Full delete everywhere |

---

## Visual: What Each Setting Protects

```
┌─────────────────────────────────────────────────────────────────────┐
│                         OpenBao Resources                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐    │
│  │   Auth Mounts   │   │    Policies     │   │   Auth Roles    │    │
│  │                 │   │                 │   │                 │    │
│  │ auth/kubernetes │   │ acme-admin      │   │ ten-acme-ns-... │    │
│  │ auth/oidc       │   │ acme-editor     │   │                 │    │
│  └────────┬────────┘   └────────┬────────┘   └────────┬────────┘    │
│           │                     │                     │             │
│           └─────────────────────┼─────────────────────┘             │
│                                 │                                   │
│                    ┌────────────▼────────────┐                      │
│                    │  deletionProtection     │                      │
│                    │  (operator actions)     │                      │
│                    └────────────┬────────────┘                      │
│                                 │                                   │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      Secret Data                            │    │
│  │                                                             │    │
│  │  secret/tenants/acme/prod/...                               │    │
│  │  secret/shared/...                                          │    │
│  │                                                             │    │
│  │                    ┌────────────────────┐                   │    │
│  │                    │    allowDeletes    │                   │    │
│  │                    │  (user actions)    │                   │    │
│  │                    └────────────────────┘                   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                   On CR/Tenant Deletion                     │    │
│  │                                                             │    │
│  │                    ┌────────────────────┐                   │    │
│  │                    │   deletionPolicy   │                   │    │
│  │                    │  Orphan | Delete   │                   │    │
│  │                    └────────────────────┘                   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Recommended Settings by Environment

### Production
```yaml
safety:
  deletionProtection: true   # Never delete OpenBao resources
  allowDeletes: false        # Users can't delete secrets
deletionPolicy: Orphan       # Keep everything on tenant deletion
```

### Staging
```yaml
safety:
  deletionProtection: true   # Still protect infrastructure
  allowDeletes: true         # Allow cleaning up test secrets
deletionPolicy: Orphan       # Keep for debugging
```

### Development / CI
```yaml
safety:
  deletionProtection: false  # Allow full cleanup
  allowDeletes: true         # Allow deleting test data
deletionPolicy: Delete       # Clean teardown
```

---

## Example Scenarios

### Scenario 1: Tenant Deleted Accidentally (Production)

**Settings:**
```yaml
safety:
  deletionProtection: true
deletionPolicy: Orphan
```

**What happens:**
```
1. Admin accidentally: kubectl delete tenant acme
2. Kubernetes: Tenant CR deleted
3. Operator: Sees deletion, but deletionPolicy=Orphan
4. OpenBao: ALL resources preserved
   - Policies: acme-admin, acme-editor ✅
   - Roles: ten-acme-ns-... ✅
   - Secrets: secret/tenants/acme/... ✅

5. Admin recreates: kubectl apply -f tenant-acme.yaml
6. Operator: Reconnects to existing OpenBao resources
7. Result: No data loss!
```

### Scenario 2: Cleanup Dev Environment

**Settings:**
```yaml
safety:
  deletionProtection: false
deletionPolicy: Delete
```

**What happens:**
```
1. Dev: kubectl delete tenant test-tenant
2. Kubernetes: Tenant CR deleted
3. Operator: Sees deletion, deletionPolicy=Delete
4. Operator deletes from OpenBao:
   - Policies: test-tenant-admin ❌
   - Roles: ten-test-tenant-ns-... ❌
   - Secrets: NOT deleted (separate concern)

5. Result: Clean slate for next test
```

### Scenario 3: User Tries to Delete Secret

**Settings:**
```yaml
safety:
  allowDeletes: false
```

**What happens:**
```
1. User (acme owner) tries:
   vault kv delete secret/tenants/acme/prod/payments/api/db

2. Policy check:
   acme-admin policy has: ["create", "read", "update", "list"]
   NO "delete" capability

3. Result: 403 Forbidden
   User cannot delete the secret
```

---

## Summary

| Setting | What it controls | Default | Recommendation |
|---------|------------------|---------|----------------|
| `safety.deletionProtection` | Can operator DELETE from OpenBao? | `true` | Keep `true` in prod |
| `safety.allowDeletes` | Can users DELETE secrets? | `false` | Keep `false` in prod |
| `deletionPolicy` | What happens on CR/tenant deletion? | `Orphan` | Keep `Orphan` in prod |

### Quick Reference

| Setting | `true` / `Delete` | `false` / `Orphan` |
|---------|-------------------|---------------------|
| `deletionProtection` | Operator can delete | Operator create/update only |
| `allowDeletes` | "delete" in policies | "delete" stripped |
| `deletionPolicy` | Remove OpenBao resources | Keep OpenBao resources |
