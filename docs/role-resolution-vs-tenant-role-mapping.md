# roleResolution vs tenantRoleMapping

## Question

What is `roleResolution` in SSO and how does it differ from `tenantRoleMapping`?

## Answer

These two concepts work together in a pipeline but serve different purposes.

### The Flow

```
User logs in via OIDC
        ↓
IdP returns JWT with groups claim
        ↓
┌─────────────────────────────────────────────┐
│  roleResolution (SSO)                       │
│  "Which tenant role does this user have?"   │
│                                             │
│  groups: ["tenant-acme-owners",             │
│           "tenant-beta-editors"]            │
│           ↓                                 │
│  Result: owner of "acme", editor of "beta"  │
└─────────────────────────────────────────────┘
        ↓
┌─────────────────────────────────────────────┐
│  tenantRoleMapping                          │
│  "What OpenBao permissions for this role?"  │
│                                             │
│  owner  → admin  (full RW + delete)         │
│  editor → editor (RW, no delete)            │
│  viewer → viewer (read-only)                │
│           ↓                                 │
│  Result: admin policy for acme,             │
│          editor policy for beta             │
└─────────────────────────────────────────────┘
```

---

## roleResolution (in SSO)

**Purpose:** Extract tenant membership and role from IdP groups.

**Question it answers:** "Looking at this user's groups from the IdP, which tenants do they belong to and what role do they have in each?"

```yaml
sso:
  roleResolution:
    patterns:
      - role: owner
        match: "tenant-{{ .Tenant }}-owners"    # e.g., "tenant-acme-owners"
      - role: editor
        match: "tenant-{{ .Tenant }}-editors"   # e.g., "tenant-acme-editors"
      - role: viewer
        match: "tenant-{{ .Tenant }}-viewers"   # e.g., "tenant-acme-viewers"
    tieBreakStrategy: highest  # If user matches both owner and editor patterns
    fallback: deny             # If no pattern matches
```

**Example:**
- User has groups: `["tenant-acme-owners", "tenant-beta-editors", "random-group"]`
- Pattern matching extracts:
  - `tenant-acme-owners` → tenant=acme, role=owner
  - `tenant-beta-editors` → tenant=beta, role=editor
  - `random-group` → no match, ignored

**Output:** User is `owner` of `acme`, `editor` of `beta`

---

## tenantRoleMapping

**Purpose:** Map MTO tenant roles to OpenBao policy tiers (capabilities).

**Question it answers:** "Now that we know this user is an 'owner' of tenant X, what OpenBao capabilities should they get?"

```yaml
tenantRoleMapping:
  owner:
    policyTier: admin      # Owners get admin policies
  editor:
    policyTier: editor     # Editors get editor policies
  viewer:
    policyTier: viewer     # Viewers get viewer policies (or 'none' to deny)

  policyOverrides:         # Optional: customize what each tier means
    admin:
      capabilities: [create, read, update, delete, list]
    editor:
      capabilities: [create, read, update, list]  # no delete
    viewer:
      capabilities: [read, list]
```

**Example:**
- User is `owner` of `acme` (from roleResolution)
- tenantRoleMapping says: owner → admin
- Admin tier means: `[create, read, update, delete, list]`
- Result: User gets policy `acme-admin` with full capabilities on `secret/tenants/acme/*`

---

## Why Two Separate Configs?

| Aspect | roleResolution | tenantRoleMapping |
|--------|----------------|-------------------|
| **Scope** | SSO/OIDC only (humans) | Both humans AND workloads |
| **Input** | IdP group strings | Tenant role (owner/editor/viewer) |
| **Output** | Tenant + role | OpenBao policy tier + capabilities |
| **Depends on** | Your IdP's group naming | Your security requirements |

**Separation allows:**
1. Different IdPs can have different group naming conventions (change roleResolution, keep tenantRoleMapping)
2. Different security postures (e.g., make viewers have no access by setting `viewer: none`)
3. Workloads use tenantRoleMapping directly (they don't go through OIDC)

---

## Complete Example

**IdP groups for user "alice":**
```
["tenant-acme-owners", "tenant-beta-viewers", "cluster-admins"]
```

**roleResolution patterns:**
```yaml
patterns:
  - role: owner
    match: "tenant-{{ .Tenant }}-owners"
  - role: editor
    match: "tenant-{{ .Tenant }}-editors"
  - role: viewer
    match: "tenant-{{ .Tenant }}-viewers"
```

**Step 1 - roleResolution extracts:**
- `tenant-acme-owners` → tenant=acme, role=owner
- `tenant-beta-viewers` → tenant=beta, role=viewer
- `cluster-admins` → no match (doesn't fit pattern)

**tenantRoleMapping:**
```yaml
owner:
  policyTier: admin
editor:
  policyTier: editor
viewer:
  policyTier: none  # viewers get no access
```

**Step 2 - tenantRoleMapping applies:**
- acme + owner → admin → `acme-admin` policy (full access)
- beta + viewer → none → no policy (denied)

**Result for Alice:**
- Full admin access to `secret/tenants/acme/*`
- No access to `secret/tenants/beta/*` (even though she's a viewer there)

---

## For Workloads (Kubernetes Auth)

Workloads skip roleResolution entirely:

```
Pod in namespace "acme-payments"
        ↓
Kubernetes auth with ServiceAccount
        ↓
Operator knows: namespace belongs to tenant "acme"
        ↓
┌─────────────────────────────────────────────┐
│  rbac.defaultTier: editor                   │
│  (from engine spec)                         │
│           ↓                                 │
│  tenantRoleMapping: editor → editor tier    │
│           ↓                                 │
│  Result: editor policy for acme-payments    │
└─────────────────────────────────────────────┘
```

So `tenantRoleMapping` is used for **both** humans and workloads, but `roleResolution` is only for OIDC humans.

---

## Summary

| Concept | roleResolution | tenantRoleMapping |
|---------|----------------|-------------------|
| **Where** | `spec.sso.roleResolution` | `spec.tenantRoleMapping` |
| **When** | OIDC login (humans only) | Always (humans + workloads) |
| **Does** | Extracts tenant + role from IdP groups | Maps role to policy capabilities |
| **Pattern** | `"tenant-{{ .Tenant }}-owners"` | `owner: { policyTier: admin }` |
