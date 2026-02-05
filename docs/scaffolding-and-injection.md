# Scaffolding & Injection Explained

These two concepts work together to get secrets from OpenBao into your pods.

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│   Scaffolding   │         │    Injection    │         │      Pod        │
│                 │         │                 │         │                 │
│ "WHEN to create │────────>│ "HOW secrets    │────────>│ "App uses       │
│  K8s resources" │         │  reach pods"    │         │  secrets"       │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

---

## Scaffolding

**Purpose:** Controls WHEN the operator creates Kubernetes resources (SecretStore, ExternalSecret) for apps.

```yaml
scaffolding:
  mode: OnAnnotation       # OnAnnotation | Always | Never
  annotations:
    enable: "mto.secrets/enable"
    keys: "mto.secrets/keys"
    sharedKeys: "mto.secrets/sharedKeys"
    env: "mto.secrets/env"
```

### Scaffolding Modes

| Mode | Behavior |
|------|----------|
| **OnAnnotation** | Only create resources when app has `mto.secrets/enable: "true"` |
| **Always** | Create resources for ALL apps in tenant namespaces |
| **Never** | Don't create any resources (manual setup required) |

---

### How OnAnnotation Works

**Step 1:** Developer adds annotations to their Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: acme-payments
  annotations:
    mto.secrets/enable: "true"           # Opt-in
    mto.secrets/keys: "db,stripe,config" # Which secrets
    mto.secrets/sharedKeys: "feature-flags"  # From global shared
    mto.secrets/env: "prod"              # Optional override
spec:
  template:
    spec:
      containers:
        - name: api
          envFrom:
            - secretRef:
                name: checkout-api-db      # Will be created by operator
            - secretRef:
                name: checkout-api-stripe
```

**Step 2:** Operator detects the annotation and creates:

```yaml
# ExternalSecret for "db" key
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-api-db
  namespace: acme-payments
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: openbao
    kind: SecretStore
  target:
    name: checkout-api-db
  dataFrom:
    - extract:
        key: secret/data/tenants/acme/prod/acme-payments/checkout-api/db
```

```yaml
# ExternalSecret for "stripe" key
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-api-stripe
  namespace: acme-payments
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: openbao
    kind: SecretStore
  target:
    name: checkout-api-stripe
  dataFrom:
    - extract:
        key: secret/data/tenants/acme/prod/acme-payments/checkout-api/stripe
```

**Step 3:** ESO syncs secrets from OpenBao → Kubernetes Secrets

**Step 4:** Pod mounts the Kubernetes Secrets

---

## Injection

**Purpose:** Controls HOW secrets get from OpenBao into pods.

```yaml
injection:
  mode: external-secrets    # external-secrets | csi | none
  secretStore:
    scope: namespace        # namespace | cluster
    name: openbao
```

### Injection Modes

| Mode | How it works | Pros | Cons |
|------|--------------|------|------|
| **external-secrets** | ESO syncs to K8s Secrets | Simple, works everywhere | Secrets stored in etcd |
| **csi** | CSI driver mounts secrets as files | No etcd storage | More complex setup |
| **none** | App calls OpenBao API directly | Most secure | App must handle auth |

---

## Mode 1: external-secrets (Recommended)

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│   OpenBao    │      │     ESO      │      │  K8s Secret  │      │     Pod      │
│              │      │              │      │              │      │              │
│ secret/data/ │─────>│ ExternalSec  │─────>│ checkout-db  │─────>│ env: DB_PASS │
│ tenants/...  │ sync │ rets Operator│create│              │mount │              │
└──────────────┘      └──────────────┘      └──────────────┘      └──────────────┘
```

### What operator creates:

**1. SecretStore (per namespace):**
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

**2. ExternalSecret (per app secret):**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-api-db
  namespace: acme-payments
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: openbao
    kind: SecretStore
  target:
    name: checkout-api-db
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: secret/data/tenants/acme/prod/acme-payments/checkout-api/db
```

**3. Resulting K8s Secret (created by ESO):**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: checkout-api-db
  namespace: acme-payments
type: Opaque
data:
  username: YWRtaW4=      # base64: admin
  password: c2VjcmV0MTIz  # base64: secret123
```

---

## Mode 2: csi (Secrets Store CSI Driver)

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│   OpenBao    │      │  CSI Driver  │      │     Pod      │
│              │      │              │      │              │
│ secret/data/ │─────>│ SecretProv   │─────>│ /mnt/secrets │
│ tenants/...  │ fetch│ iderClass    │mount │ /db/password │
└──────────────┘      └──────────────┘      └──────────────┘
```

### What operator creates:

**1. SecretProviderClass:**
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: checkout-api-secrets
  namespace: acme-payments
spec:
  provider: vault
  parameters:
    vaultAddress: "https://bao.example.com:8200"
    roleName: "ten-acme-ns-acme-payments-editor"
    objects: |
      - objectName: "db-password"
        secretPath: "secret/data/tenants/acme/prod/acme-payments/checkout-api/db"
        secretKey: "password"
      - objectName: "db-username"
        secretPath: "secret/data/tenants/acme/prod/acme-payments/checkout-api/db"
        secretKey: "username"
```

**2. Pod mounts the volume:**
```yaml
spec:
  containers:
    - name: api
      volumeMounts:
        - name: secrets
          mountPath: "/mnt/secrets"
          readOnly: true
  volumes:
    - name: secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "checkout-api-secrets"
```

**3. Secrets appear as files:**
```
/mnt/secrets/
├── db-password    # Contains: secret123
└── db-username    # Contains: admin
```

---

## Mode 3: none (Direct API)

```
┌──────────────┐                           ┌──────────────┐
│   OpenBao    │                           │     Pod      │
│              │<─────────────────────────>│              │
│ secret/data/ │  App calls API directly   │  App code    │
│ tenants/...  │  using SA token           │  fetches     │
└──────────────┘                           └──────────────┘
```

**No operator-created resources.** App handles everything:

```go
// App code
func getSecret() {
    // 1. Read SA token
    token, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")

    // 2. Login to OpenBao
    resp, _ := http.Post("https://bao.example.com:8200/v1/auth/kubernetes/login",
        "application/json",
        bytes.NewBuffer([]byte(`{"role":"ten-acme-ns-acme-payments-editor","jwt":"` + token + `"}`)))

    // 3. Use returned token to read secrets
    vaultToken := parseToken(resp)
    secret, _ := http.Get("https://bao.example.com:8200/v1/secret/data/tenants/acme/prod/...")
}
```

---

## Complete Flow: Scaffolding + Injection

```
Developer adds annotation
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│                     SCAFFOLDING                             │
│                                                             │
│  mode: OnAnnotation                                         │
│  annotations:                                               │
│    mto.secrets/enable: "true"  ──┐                          │
│    mto.secrets/keys: "db"        │                          │
│                                  ▼                          │
│                    Operator detects & creates               │
│                    SecretStore + ExternalSecret             │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│                      INJECTION                              │
│                                                             │
│  mode: external-secrets                                     │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐      │
│  │ SecretStore │───>│ExternalSec. │───>│  K8s Secret │      │
│  │ (how to     │    │(what to     │    │(synced      │      │
│  │  connect)   │    │ fetch)      │    │ data)       │      │
│  └─────────────┘    └─────────────┘    └─────────────┘      │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│                        POD                                  │
│                                                             │
│  envFrom:                                                   │
│    - secretRef:                                             │
│        name: checkout-api-db   ◄── mounted from K8s Secret  │
│                                                             │
│  env:                                                       │
│    DB_USER: admin                                           │
│    DB_PASS: secret123                                       │
└─────────────────────────────────────────────────────────────┘
```

---

## Annotations Reference

| Annotation | Required | Description | Example |
|------------|----------|-------------|---------|
| `mto.secrets/enable` | Yes | Opt-in to scaffolding | `"true"` |
| `mto.secrets/keys` | Yes* | Tenant-private secret keys | `"db,stripe,config"` |
| `mto.secrets/sharedKeys` | No | Global shared secret keys | `"feature-flags"` |
| `mto.secrets/env` | No | Override environment | `"staging"` |

*At least one of `keys` or `sharedKeys` required.

---

## What Gets Created Where

| Resource | Created By | Scope | When |
|----------|------------|-------|------|
| **SecretStore** | OBX Operator | Per namespace | When namespace added to tenant |
| **ExternalSecret** | OBX Operator | Per app/key | When app has annotations |
| **K8s Secret** | ESO | Per app/key | When ExternalSecret syncs |

---

## SecretStore Scope Options

```yaml
injection:
  secretStore:
    scope: namespace    # namespace | cluster
    name: openbao
```

### scope: namespace (Default)

One SecretStore per tenant namespace:

```
acme-payments/
└── SecretStore: openbao    ← Uses role: ten-acme-ns-acme-payments-editor

acme-frontend/
└── SecretStore: openbao    ← Uses role: ten-acme-ns-acme-frontend-editor
```

**Pros:** Fine-grained RBAC per namespace
**Cons:** More resources to manage

### scope: cluster

One ClusterSecretStore for all namespaces:

```
ClusterSecretStore: openbao    ← Shared by all namespaces
```

**Pros:** Simpler management
**Cons:** Less granular control

---

## Example: Full Scaffolding Configuration

```yaml
apiVersion: security.mto.stakater.com/v1alpha1
kind: OpenBaoExtension
metadata:
  name: cluster-default
  namespace: mto-system
spec:
  # ... other config ...

  engines:
    - name: kv
      type: kv-v2
      layoutRef: kv
      mount:
        path: secret
        scope: Cluster

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
      sharedKeys: "mto.secrets/sharedKeys"
      env: "mto.secrets/env"
```

---

## Comparison: Injection Modes

| Aspect | external-secrets | csi | none |
|--------|------------------|-----|------|
| **Setup complexity** | Low | Medium | High (app changes) |
| **Secrets in etcd** | Yes | No | No |
| **Auto-refresh** | Yes (interval) | Yes (rotation) | Manual |
| **App changes needed** | No | Volume mount | API calls |
| **Works with** | Any app | Any app | Apps you control |
| **Operator creates** | SecretStore + ExternalSecret | SecretProviderClass | Nothing |

---

## Summary

| Concept | What | Controls |
|---------|------|----------|
| **Scaffolding** | Auto-create K8s resources | WHEN resources are created |
| **Injection** | Get secrets into pods | HOW secrets reach pods |

### Scaffolding Modes

| Mode | Behavior |
|------|----------|
| `OnAnnotation` | Only when app opts in |
| `Always` | For all apps |
| `Never` | Manual setup |

### Injection Modes

| Mode | Method | Best For |
|------|--------|----------|
| `external-secrets` | ESO → K8s Secrets | Most use cases |
| `csi` | CSI driver → file mount | No etcd storage |
| `none` | App calls API | Maximum control |
