# authManagement Explained

## What is authManagement?

**Purpose:** Controls which authentication backends the operator manages in OpenBao.

```yaml
authManagement:
  kubernetes: Ensure   # Ensure | Off
  oidc: Ensure         # Ensure | Off
```

---

## What Each Setting Does

| Setting | `Ensure` | `Off` |
|---------|----------|-------|
| **kubernetes** | Operator mounts and configures `auth/kubernetes` for workloads | Operator assumes it's already configured manually |
| **oidc** | Operator mounts and configures `auth/oidc` for humans | Operator skips OIDC setup entirely |

---

## Why It Exists

**Scenario 1: Greenfield (new cluster)**
```yaml
authManagement:
  kubernetes: Ensure  # Operator creates auth/kubernetes
  oidc: Ensure        # Operator creates auth/oidc
```
Operator handles everything automatically.

**Scenario 2: Existing OpenBao with pre-configured auth**
```yaml
authManagement:
  kubernetes: Off     # Already configured by infra team
  oidc: Off           # Already configured by infra team
```
Operator skips auth setup, only manages policies/roles.

**Scenario 3: Workloads only, no human SSO**
```yaml
authManagement:
  kubernetes: Ensure  # Operator manages this
  oidc: Off           # No OIDC needed
sso:
  mode: disabled      # Matches - no SSO
```
Only Kubernetes auth for pods, no human login.

**Scenario 4: Shared OpenBao across multiple clusters**
```yaml
authManagement:
  kubernetes: Ensure  # Each cluster needs its own k8s auth
  oidc: Off           # Shared OIDC configured once centrally
```

---

## What "Ensure" Actually Does

### For `kubernetes: Ensure`

1. Check if `auth/kubernetes` mount exists
2. If not, enable it: `POST /v1/sys/auth/kubernetes`
3. Configure it with cluster's API server URL and CA

### For `oidc: Ensure`

1. Check if `auth/oidc` mount exists
2. If not, enable it: `POST /v1/sys/auth/oidc`
3. Configure it with SSO settings from `spec.sso`

---

## Relationship with SSO

```
authManagement.oidc: Ensure  +  sso.mode: inline   → Operator configures OIDC from inline config
authManagement.oidc: Ensure  +  sso.mode: secret   → Operator configures OIDC from secret
authManagement.oidc: Ensure  +  sso.mode: disabled → ERROR or skip OIDC (nothing to configure)
authManagement.oidc: Off     +  sso.mode: *        → Operator doesn't touch auth/oidc mount
```

---

## Summary Table

| Field | Controls | Values |
|-------|----------|--------|
| `authManagement.kubernetes` | `auth/kubernetes` mount for workloads | `Ensure` (manage) / `Off` (skip) |
| `authManagement.oidc` | `auth/oidc` mount for humans | `Ensure` (manage) / `Off` (skip) |

---

# Kubernetes Auth in OpenBao - Deep Dive

## The Problem

A pod running in Kubernetes needs to access secrets from OpenBao. But how does OpenBao know:
1. This pod is who it claims to be?
2. This pod is allowed to access these secrets?

**Solution:** Kubernetes Auth method - lets pods authenticate to OpenBao using their ServiceAccount token.

---

## What is "auth/kubernetes" Mount?

OpenBao has different ways to authenticate (auth methods):
- `auth/userpass` - username/password
- `auth/oidc` - SSO login for humans
- `auth/kubernetes` - for Kubernetes pods

Each auth method must be **mounted** (enabled) at a path before it can be used.

```
OpenBao Server
├── auth/
│   ├── kubernetes/    ← Auth method for pods
│   ├── oidc/          ← Auth method for humans
│   └── token/         ← Built-in (always exists)
├── secret/            ← KV secrets engine
└── sys/               ← System operations
```

---

## The Three Steps to Enable Kubernetes Auth

### Step 1: Check if mount exists

```
GET /v1/sys/auth
```

Response shows all enabled auth methods:
```json
{
  "kubernetes/": {
    "type": "kubernetes"
  },
  "oidc/": {
    "type": "oidc"
  },
  "token/": {
    "type": "token"
  }
}
```

If `kubernetes/` is not in the list → need to enable it.

---

### Step 2: Enable the auth method

```
POST /v1/sys/auth/kubernetes
{
  "type": "kubernetes"
}
```

This "mounts" the Kubernetes auth method at `auth/kubernetes/`.

Now OpenBao knows: "I can accept Kubernetes ServiceAccount tokens for authentication."

But it still doesn't know HOW to verify those tokens...

---

### Step 3: Configure it

```
POST /v1/auth/kubernetes/config
{
  "kubernetes_host": "https://kubernetes.default.svc:443",
  "kubernetes_ca_cert": "-----BEGIN CERTIFICATE-----\nMIIC5z..."
}
```

This tells OpenBao:
- **kubernetes_host**: Where is the Kubernetes API server?
- **kubernetes_ca_cert**: What certificate to use to trust it?

Now when a pod sends a ServiceAccount token, OpenBao can:
1. Call Kubernetes API to verify the token is real
2. Get info about which ServiceAccount/namespace the pod belongs to

---

## The Full Authentication Flow

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│      Pod        │         │    OpenBao      │         │  Kubernetes API │
│  (acme-app)     │         │                 │         │                 │
└────────┬────────┘         └────────┬────────┘         └────────┬────────┘
         │                           │                           │
         │ 1. "Login with my SA token"                           │
         │   POST /v1/auth/kubernetes/login                      │
         │   { "role": "acme-editor",                            │
         │     "jwt": "eyJhbG..." }                              │
         │ ─────────────────────────>│                           │
         │                           │                           │
         │                           │ 2. "Is this token valid?" │
         │                           │   TokenReview API         │
         │                           │ ─────────────────────────>│
         │                           │                           │
         │                           │ 3. "Yes, it's SA 'default'│
         │                           │    in namespace 'acme-ns'"│
         │                           │ <─────────────────────────│
         │                           │                           │
         │                           │ 4. Check: Does role       │
         │                           │    "acme-editor" allow    │
         │                           │    SA "default" in        │
         │                           │    namespace "acme-ns"?   │
         │                           │    → YES                  │
         │                           │                           │
         │ 5. Here's your OpenBao token                          │
         │    (with policies attached)                           │
         │ <─────────────────────────│                           │
         │                           │                           │
         │ 6. Now use token to read secrets                      │
         │   GET /v1/secret/data/tenants/acme/...                │
         │ ─────────────────────────>│                           │
```

---

## What the Operator Creates After Auth is Configured

After auth/kubernetes is configured, the operator creates **roles** that define who can authenticate:

```
POST /v1/auth/kubernetes/role/ten-acme-ns-acme-payments-editor
{
  "bound_service_account_names": ["default"],
  "bound_service_account_namespaces": ["acme-payments"],
  "policies": ["acme-payments-editor"],
  "token_ttl": "1h",
  "token_max_ttl": "4h"
}
```

This role says:
- Only ServiceAccount `default`
- Only from namespace `acme-payments`
- Gets policy `acme-payments-editor`
- Token valid for 1 hour

---

## Summary of Steps

| Step | API Call | Purpose |
|------|----------|---------|
| **Check mount exists** | `GET /v1/sys/auth` | Check if kubernetes auth is enabled |
| **Enable mount** | `POST /v1/sys/auth/kubernetes` | Turn on kubernetes auth method |
| **Configure** | `POST /v1/auth/kubernetes/config` | Tell OpenBao how to talk to K8s API |
| **Create roles** | `POST /v1/auth/kubernetes/role/<name>` | Define which pods can get which policies |

The configuration (step 3) is critical because without it, OpenBao can't verify that the ServiceAccount tokens are legitimate.

---

## OIDC Auth (Similar Pattern)

OIDC auth follows the same pattern for human users:

### Enable
```
POST /v1/sys/auth/oidc
{
  "type": "oidc"
}
```

### Configure
```
POST /v1/auth/oidc/config
{
  "oidc_discovery_url": "https://dex.example.com",
  "oidc_client_id": "openbao",
  "oidc_client_secret": "<secret>",
  "default_role": "default"
}
```

### Create Role
```
POST /v1/auth/oidc/role/default
{
  "user_claim": "email",
  "groups_claim": "groups",
  "allowed_redirect_uris": [
    "https://bao.example.com/ui/vault/auth/oidc/oidc/callback"
  ]
}
```

The difference: OIDC verifies tokens against an external identity provider (Dex, Keycloak, etc.) instead of Kubernetes API.
