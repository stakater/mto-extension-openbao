<!-- markdownlint-disable MD013 MD024 -->

# OpenBao Config — Helm Charts

These charts give each [Multi-Tenant Operator](https://github.com/stakater/multi-tenant-operator) (MTO) tenant its own OpenBao setup, with no manual work per tenant.

When you create an MTO `Tenant`, the charts automatically create:

- a private space in OpenBao for that tenant;
- a place to store secrets (KV);
- encryption keys (Transit);
- a certificate authority (PKI);
- human login through your company's single sign-on (SSO).

Each application then opts in to what it needs by adding a few annotations to its `ServiceAccount` and `Deployment`. The charts turn those annotations into OpenBao policies, roles, and Kubernetes resources.

> **You need the operator first.** These charts only describe configuration. The [OpenBao Config Operator](https://github.com/stakater-ab/openbao-config-operator) is what actually talks to OpenBao and applies it. Install the operator before the charts.

---

## Contents

- [The charts](#the-charts)
- [How it works](#how-it-works)
- [Before you start](#before-you-start)
- [Install](#install)
- [Key ideas](#key-ideas)
- [The workload contract](#the-workload-contract)
- [Connecting a workload to OpenBao](#connecting-a-workload-to-openbao)
- [Delivering secrets with External Secrets Operator (ESO)](#delivering-secrets-with-external-secrets-operator-eso)
- [Feature: KV secrets](#feature-kv-secrets)
- [Feature: Transit (encryption)](#feature-transit-encryption)
- [Feature: PKI (certificates)](#feature-pki-certificates)
- [Feature: Human SSO (OIDC login)](#feature-human-sso-oidc-login)
- [Which auth methods the charts set up](#which-auth-methods-the-charts-set-up)
- [Checking health](#checking-health)
- [Drift protection](#drift-protection)
- [Deletion policy (safety guardrails)](#deletion-policy-safety-guardrails)
- [Configuration](#configuration)
- [Going to production](#going-to-production)

---

## The charts

This repo holds the two MTO charts. The operator's own install chart lives with
the operator, in [stakater-ab/openbao-config-operator](https://github.com/stakater-ab/openbao-config-operator).

| Chart | Install it? | What it does |
|---|---|---|
| [`openbao-config-mto-bootstrap`](openbao-config-mto-bootstrap/) | Yes | Sets up the MTO integration once per cluster. Watches `Tenant` CRs and fans out to one render per tenant. |
| [`openbao-config-mto`](openbao-config-mto/) | No (pulled automatically) | The per-tenant template. The bootstrap chart pulls it from a registry and renders it once per tenant. You don't install this one by hand. |

So in practice you install **two** charts: the operator from its own repo, then
the bootstrap chart from here.

---

## How it works

```text
MTO Tenant
   │
   ▼
bootstrap chart (installed once)  ──one render per tenant──▶  openbao-config-mto (pulled from registry)
                                                                   │
                                                                   ▼
                                              per-tenant OpenBao CRs + ConfigMaps + ExternalSecrets
                                                                   │
                                                              (watched by)
                                                                   ▼
                                                     OpenBao Config Operator ──HTTP API──▶ OpenBao server
```

1. You install the operator and the bootstrap chart once.
2. You (or MTO) create a `Tenant`.
3. The bootstrap chart notices the new tenant and renders the per-tenant chart for it.
4. That render produces OpenBao custom resources (and helper Kubernetes objects).
5. The operator reads those resources and configures OpenBao.

This all happens through [template-operator-v2](https://github.com/stakater/template-operator), which does the "one render per tenant" step.

**Each tenant gets up to four renders, not one.** The core render
(`openbao-config-mto-<tenant>`) holds everything OpenBao needs: the tenant's
private space, secret engines, policies, and login roles. (One exception:
the OpenBao policy and login role that exist only so cert-manager can log
in travel with the cert-manager render — they are useless without it.)
Optional integrations live in their own renders:

- `openbao-config-mto-<tenant>.eso` — the ESO `SecretStore` and
  `ExternalSecret` objects. Only exists when `parent.eso` is `enabled`.
- `openbao-config-mto-<tenant>.certmanager` — the cert-manager `Issuer`
  wiring. Only exists when `parent.certManager.enabled` is `true`.
- `openbao-config-mto-<tenant>.trust` — the trust-manager `Bundle` for
  cross-tenant PKI trust. Only exists when `crossTenantPki.enabled` is
  `true`.

Why split? template-operator-v2 checks every object in a render against the
cluster before applying, and one bad object fails the whole render. Each
optional render matches exactly one operator, so if ESO, cert-manager, or
trust-manager is not installed, only that small render fails — the tenant's
core OpenBao setup still works. Install the missing operator later and the
failed render fixes itself within a minute, with no manual steps.

**If you ever need to force a render to start over,** turn its integration off
and back on — set the value to `false` (or `disabled`) so the bootstrap stops
emitting that render, then set it back. Do not delete the render's
`TemplateInstance` by hand. The bootstrap is still generating it, so the delete
cannot finish: the objects it created are removed, but the name stays held by a
terminating `TemplateInstance` that the bootstrap cannot replace, and that
render stays down until the value is toggled.

**Turning an integration off leaves its permissions in place.** The bootstrap
`ClusterRole` gates only `create` on an integration's object kinds; read,
update and delete stay granted whether the integration is on or off. That is
deliberate. Turning an integration off in one `helm upgrade` removes its
render and rewrites the `ClusterRole` at the same moment, but the objects the
render created are cleaned up *afterwards* — and that cleanup needs to list
them, remove a finalizer from each, and delete them. Revoking those verbs
together with the toggle wedges the cleanup permanently: the render sticks in
`Terminating`, and every object it created is left behind holding a finalizer
that nothing will ever remove. Gating `create` alone keeps the property worth
having — a cluster with an integration off cannot be made to mint new
`Issuer`s, `Bundle`s, `SecretStore`s, `ServiceAccount`s or RBAC — while
letting cleanup finish.

**Tenant name length.** The render's name is stamped as a label on every
object it produces, and Kubernetes caps label values at 63 characters. That
puts a ceiling on tenant names: 44 characters for the core render, 40 with
`.eso`, 38 with `.trust`, 32 with `.certmanager`. A tenant name over the
limit for an enabled render fails that render with a message naming the
budget, so this shows up at install time rather than as an unexplained
invalid-label error.

Installing the per-tenant chart directly with `helm install` renders
everything in one pass (`component: all`) and none of this applies.

---

## Before you start

Install these in the cluster first. The charts do **not** install them for you.

| Dependency | Needed for | Always required? |
|---|---|---|
| [OpenBao Config Operator](https://github.com/stakater-ab/openbao-config-operator) | Everything | Yes |
| [Multi-Tenant Operator (MTO)](https://github.com/stakater/multi-tenant-operator) | Provides `Tenant` CRs and labels tenant namespaces | Yes |
| [template-operator-v2](https://github.com/stakater/template-operator) | Renders the per-tenant chart | Yes |
| [External Secrets Operator (ESO)](https://external-secrets.io/) | Delivering secrets as Kubernetes Secrets | Only if `eso=enabled` (the default) |
| [cert-manager](https://cert-manager.io/) | The template-operator-v2 webhook, and PKI certificate issuance | Yes for the webhook; also for PKI Issuer injection |
| [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) | Cross-tenant PKI trust | Only if you turn on cross-tenant PKI trust |
| An OIDC identity provider (e.g. [Dex](https://dexidp.io/)) | Human SSO login | Only if you turn on SSO |

MTO must label each tenant namespace with `stakater.com/tenant=<tenant-name>`. The charts rely on that label to find a tenant's namespaces.

---

## Install

Install the operator first (see the [operator README](https://github.com/stakater-ab/openbao-config-operator)), then the bootstrap chart:

```bash
helm install openbao-config-mto-bootstrap \
  oci://ghcr.io/stakater/charts/openbao-config-mto-bootstrap \
  -n openbao-config-operator-system
```

Set cluster-wide defaults (OpenBao address, environment name, SSO on/off, and so on) under `parent.*` in the bootstrap [values.yaml](openbao-config-mto-bootstrap/values.yaml). Set the per-tenant engine details (transit keys, PKI roles, tier permissions, SSO tiers) in the per-tenant chart's [values.yaml](openbao-config-mto/values.yaml).

After a tenant exists, see what was created for it:

```bash
# the per-tenant renders — core, plus .eso / .certmanager / .trust when enabled
kubectl -n openbao-config-operator-system get ti

# the OpenBao resources for one tenant (core render)
kubectl -n openbao-config-operator-system get \
  obns,obse,obam,obkac,obkar,obp,obtk,obpkic,obpkir \
  -l templates.v2.stakater.com/instance=openbao-config-mto-team-a
```

ESO objects carry the `.eso` render's label instead
(`templates.v2.stakater.com/instance=openbao-config-mto-team-a.eso`), and
the per-workload sync status (`externalSecretSync`) shows on that render's
`TemplateInstance` status, not on the core one.

### Upgrading

To openbao-config-mto 0.21.0 and openbao-config-mto-bootstrap 0.17.0:

- **Check the tenant names first.** A tenant now fails its render when its name
  is the shared space's (`parent.sharedTenantName`, default `shared`), or the
  platform CA's namespace while `platformPki.enabled` is on
  (`platformPki.openbaoNamespace` without the `/`, default `platform`). Such a
  tenant's objects have the same names as the shared space's or the platform
  CA's. After the upgrade, its `TemplateInstance` fails, and its objects are no
  longer updated. Before the upgrade, run this with your own two names. It must
  print nothing:

  ```bash
  kubectl get tenants.tenantoperator.stakater.com -o name | sed 's|.*/||' \
    | grep -x -e shared -e platform
  ```

  If it prints a name, that tenant needs another name. Before the first install
  of the bootstrap chart, you can change `parent.sharedTenantName` or
  `platformPki.openbaoNamespace` instead.

- **The bootstrap chart reads a quoted `platformPki.enabled: "false"` as off.**
  Earlier versions rendered the platform CA for this value (its
  `OpenBaoNamespace`, `OpenBaoSecretEngine` and `OpenBaoPKISecretEngineConfig`),
  but told the tenants that it is off, so no tenant used it. The upgrade
  removes these three objects. With the default `safety.deletionProtection:
  true`, they carry `deletionPolicy: Retain`, and OpenBao keeps the platform
  namespace and its PKI mount.

- **A standalone render reads a quoted `"false"` as off.** This applies only to
  the tenant chart rendered without the bootstrap chart, which passes these
  switches as booleans. Earlier versions read the string `"false"` as on. If
  your values or `--set-string` flags give one of these switches the string
  `"false"`, it was on, and the upgrade turns it off:

  - `transit.enabled`, `pki.enabled`, `pki.certManager.enabled`,
    `pki.crossTenant.enabled`, `sso.enabled`, `networkPolicy.enabled`,
    `monitoring.enabled`: the feature's objects are removed. OpenBao revokes
    the grants among them, unless `safety.grantDeletionProtection` is on.
  - `pki.hierarchy.enabled`: the tenant CA changes from the intermediate at
    `pki.hierarchy.mountPath` to a self-signed root at `pki.mountPath`.
  - `sso.dex.perTenantClient`: the OIDC mount uses `sso.dex.clientId` and
    `sso.dex.clientSecretRef.name` as they are, without the `<tenant>-` prefix.

  To keep a switch on, set it to `true` before the upgrade.

---

## Key ideas

A few words are used throughout this guide:

- **Tenant** — a team or unit, defined by an MTO `Tenant`. Each tenant gets its own OpenBao namespace (e.g. `team-a/`).
- **Namespace** — a Kubernetes namespace owned by a tenant (e.g. `team-a-api`).
- **Tier** — how much access a workload gets: `viewer`, `editor`, `admin`, or `audit-read`. You set it with an annotation.
- **The shared space** — one extra OpenBao namespace (called `shared/` by default) where cross-tenant data lives. The bootstrap chart creates it once. No tenant may have its name: the tenant chart fails that tenant's render, because its namespace and objects would be the shared space's. The same applies to the platform CA's namespace (`platform/` by default) while `platformPki.enabled` is on.
- **Environment (`env`)** — a label in every secret path (default `dev`). It lets one OpenBao serve several environments.

Throughout this guide the examples use two tenants — **`team-a`** and **`team-b`** — each with a namespace like `team-a-api`.

---

## The workload contract

A workload opts in by adding annotations. The chart reads them and creates the matching OpenBao policy, login role, a `bao-config-<sa>` ConfigMap, and (if ESO is on) `SecretStore` / `ExternalSecret` resources.

**How the names are formed.** Every key follows one grammar, so you can predict a name instead of looking it up:

- `bao.stakater.com/<engine>` — opt-in boolean (`kv`, `transit`, `pki`).
- `bao.stakater.com/<engine>-<verb>-<scope>` — a sharing **grant**, always on the ServiceAccount. Verbs: `export`/`import` when data crosses tenants, `subscribe` for intra-tenant reads. Values are comma-separated peer lists.
- `bao.stakater.com/<engine>-<request>.<name>` — a **consumption** request, always on the Deployment; `<name>` names the Kubernetes Secret it produces.
- `tier` and `app` are the two engine-less keys: they qualify the identity, not an engine.

Grants live on the ServiceAccount (the identity OpenBao authenticates); consumption lives on the Deployment (the workload). A grant key on a Deployment — or vice versa — is reported as an error next to the workload.

> **This vocabulary is stable.** New keys may be added; existing keys will not be renamed. The same promise covers the `VAULT_*` names in `bao-config-<sa>` and the field names in `bao-apps`.

**Annotations on the `ServiceAccount`:**

| Annotation | Feature | What it does |
|---|---|---|
| `bao.stakater.com/kv` | KV | `"true"` → read/write the app's own KV prefix at the tier below. |
| `bao.stakater.com/transit` | Transit | `"true"` → use the app's own key, the namespace key, and the tenant's shared key. |
| `bao.stakater.com/pki` | PKI | `"true"` → issue certificates directly from OpenBao. |
| `bao.stakater.com/tier` | all | **Required alongside any engine.** `viewer` / `editor` / `admin` / `audit-read`. One level for every engine enabled above. |
| `bao.stakater.com/app` | KV, Transit | Optional. Names the app that owns this ServiceAccount's secrets and key; defaults to the ServiceAccount name. Lowercase letters, digits, hyphens; unique within the namespace. |
| `bao.stakater.com/kv-subscribe-ns` | KV | Read secrets shared by other namespaces in the same tenant (comma-separated list). |
| `bao.stakater.com/kv-export-tenant` | KV | Share secrets out to other tenants (comma-separated list). |
| `bao.stakater.com/kv-import-tenant` | KV | Read secrets shared in by other tenants (comma-separated list). |
| `bao.stakater.com/transit-export-tenant` | Transit | Share an encryption key out to other tenants (list). |
| `bao.stakater.com/transit-import-tenant` | Transit | Use an encryption key shared in by other tenants (list). |
| `bao.stakater.com/pki-allow-tenant` | PKI | Accept these other tenants as inbound mTLS clients (list). Implies trusting their CA. |
| `bao.stakater.com/pki-trust-tenant` | PKI | Trust these other tenants' server certificates outbound only, without accepting them as clients (list). |

> **Why `allow`/`trust` and not `export`/`import`?** PKI trust is not data flow. Both directions ingest the peer's CA — the difference is whether it lands in your server-side client trust (accepting them *inbound*: `allow`) or only in your outbound bundle (calling them: `trust`), so data-flow verbs would mislead.

**Annotations on the `Deployment`** (each one creates a Kubernetes Secret through ESO, named `<sa>-<name>`):

| Annotation | Reads from | Pairs with (on the ServiceAccount) |
|---|---|---|
| `bao.stakater.com/kv-secret.<name>` | Your own app's prefix | `kv` |
| `bao.stakater.com/kv-subscribe.<name>` | A sibling namespace's shared folder | `kv-subscribe-ns` |
| `bao.stakater.com/kv-import.<name>` | Another tenant's shared space | `kv-import-tenant` |

**One app = one ServiceAccount.** The app identity is 1:1 with the ServiceAccount OpenBao authenticates. Several Deployments or Jobs of one app share a single ServiceAccount (identical secret requests are deduplicated); two *different* apps that need the same value share it through the namespace's shared folder (`_shared/from-<ns>/`). Two ServiceAccounts resolving to one app name are rejected on both sides. OpenBao-enabled ServiceAccount *names* must themselves be dot-free lowercase RFC 1123 labels (letters, digits, hyphens): the chart embeds the name in generated object names whose reserved suffixes are dot-separated.

Everything the chart renders for an app into its namespace — `bao-config-<sa>`, the SecretStores, the ExternalSecrets — carries a `bao.stakater.com/app` label, so `kubectl get cm,secretstore,externalsecret -l bao.stakater.com/app=payments` collects one app's plumbing in one command.

Each feature section below explains these in full, with examples.

---

## Connecting a workload to OpenBao

KV, Transit, and PKI are all reached the same way: the workload logs in with its own ServiceAccount token and gets a short-lived OpenBao token. You only need to learn this once.

The chart writes everything the workload needs into a ConfigMap named `bao-config-<sa>` in the workload's namespace. Load it into the pod:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: team-a-api
spec:
  template:
    spec:
      serviceAccountName: web          # the ServiceAccount you annotated with a tier
      containers:
        - name: web
          image: my/web:1.0
          envFrom:
            - configMapRef:
                name: bao-config-web    # created by the chart
```

Kubernetes mounts the ServiceAccount token automatically at `/var/run/secrets/kubernetes.io/serviceaccount/token`.

### Reading a secret — three ways

- **Call OpenBao directly** (shown below — works from any language, no extra tools).
- **Use the `bao` command-line tool** — handy for scripts and debugging.
- **Let ESO deliver it as a Kubernetes Secret** — no OpenBao code at all (see [ESO](#delivering-secrets-with-external-secrets-operator-eso)).

### Call OpenBao directly with `curl`

```bash
# All VAULT_* values below come from the bao-config-web ConfigMap.
SA_JWT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

# 1. Trade the ServiceAccount token for an OpenBao token.
VAULT_TOKEN="$(curl -s --request POST \
  --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  --data "{\"role\":\"${VAULT_K8S_ROLE}\",\"jwt\":\"${SA_JWT}\"}" \
  "${VAULT_ADDR}/v1/auth/kubernetes/login" | jq -r '.auth.client_token')"

# 2. Write a secret into your own namespace path.
curl -s --request POST \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  --data '{"data":{"username":"app","password":"s3cret"}}' \
  "${VAULT_ADDR}/v1/${VAULT_KV_APP_PATH}postgres"

# 3. Read it back.
curl -s \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/${VAULT_KV_APP_PATH}postgres" | jq '.data.data'
```

### The same thing with the `bao` CLI

```bash
export VAULT_ADDR VAULT_NAMESPACE

# 1. Log in and keep the token for the next commands.
export VAULT_TOKEN="$(bao write -field=token auth/kubernetes/login \
  role="${VAULT_K8S_ROLE}" \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)"

# 2. Write a secret (KV v2 nests the values under "data").
echo '{"data":{"username":"app","password":"s3cret"}}' \
  | bao write "${VAULT_KV_APP_PATH}postgres" -

# 3. Read it back — the same path the ConfigMap gives you.
bao read "${VAULT_KV_APP_PATH}postgres"
```

> The `bao kv get`/`bao kv put` shortcuts also work, but they take the path **without** `/data/` (e.g. `bao kv get -mount=kv dev/team-a-api/web/postgres`). The `VAULT_KV_APP_PATH` variable is the raw-API form (`kv/data/...`), which `bao read`/`bao write` use directly. The same applies in the OpenBao web UI: open the `kv` mount and browse `dev/team-a-api/web/` — no `/data/` segment.

### What's in the ConfigMap

The first four rows are always present (`VAULT_CACERT` only when the install ships a CA bundle); the four KV rows appear when `kv` is enabled. Sharing, Transit, and PKI add more (shown in each feature section).

| Key | Example | Meaning |
|---|---|---|
| `VAULT_ADDR` | `http://openbao.openbao:8200` | OpenBao server URL |
| `VAULT_CACERT` | `/etc/bao/ca/ca.crt` | CA file path (only when the install ships a CA bundle) |
| `VAULT_NAMESPACE` | `team-a/` | the tenant's OpenBao namespace |
| `VAULT_K8S_ROLE` | `team-a-team-a-api-web` | the login role for this ServiceAccount |
| `VAULT_KV_APP` | `web` | the app that owns this ServiceAccount's secrets |
| `VAULT_KV_APP_PATH` | `kv/data/dev/team-a-api/web/` | the app's own secrets live here |
| `VAULT_KV_APP_META_PATH` | `kv/metadata/dev/team-a-api/web/` | metadata for the app's own secrets |
| `VAULT_KV_SHARED_OUT_PATH` | `kv/data/dev/_shared/from-team-a-api/` | the namespace's shared folder (write with `editor`+) |

> **Tip:** don't hardcode these values — read them from the ConfigMap. The names follow the chart's conventions and can change between tenants.

### Finding an app's path — the `bao-apps` directory

Someone has to put the first secret *into* OpenBao — a teammate with SSO access, or a pipeline. They need to know where. Every namespace with at least one OpenBao-enabled ServiceAccount gets a ConfigMap named `bao-apps` that answers it in one command:

```console
$ kubectl get cm bao-apps -n team-a-api -o jsonpath='{.data.web}'
serviceAccount: "web"
tier: "editor"
engines: kv
kvPath: kv/data/dev/team-a-api/web/
requestedSecrets: "postgres"
```

One entry per app, keyed by app name. `serviceAccount`, `tier` and `engines` are always present; `kvPath` and `requestedSecrets` appear when `kv` is on, `transitKey` when transit is on — a PKI-only app has just the first three. `requestedSecrets` lists the leaves the app's Deployments currently *request* via `kv-secret.*` annotations; a request is listed even while its Deployment has a reported error, so treat it as intent, not as proof an ExternalSecret rendered. The `_namespace` entry carries the shared-folder path (when the namespace has a kv app) and the namespace transit key (when it has a transit app); a namespace with neither — PKI-only, say — has no `_namespace` entry at all. An app whose annotations are invalid appears under `<serviceaccount>.error`, pointing at its error ConfigMap. While the shared-space login is on and the tenant has a cross-tenant share, a `_sharedSpace` entry holds web UI links to those shares (see [See your tenant's shares in the web UI](#see-your-tenants-shares-in-the-web-ui)). The `_format` key versions this layout (`v1`); the field names and these presence rules are covered by the stability promise above.

Paths in `bao-apps` are API data paths. In the OpenBao web UI, open the `kv` mount and browse `<env>/<namespace>/<app>/` — the `/data/` segment is an API artifact.

The index is a signpost, never an input: the chart derives it from the same facts as the policies, nothing reads it back, and editing it changes no access. If you run ArgoCD or Flux in your namespaces, exclude the chart-rendered `bao-*` ConfigMaps (`bao-apps`, `bao-config-*`, `bao-ca-bundle`) from pruning.

---

## Delivering secrets with External Secrets Operator (ESO)

**What it is.** Instead of calling OpenBao yourself, you can let [ESO](https://external-secrets.io/) do it. ESO logs in for the workload, fetches the secret, and keeps a normal Kubernetes `Secret` in sync. Your app just mounts that Secret.

**Turn it on & what you need.** ESO is on by default (`eso: enabled`). Set `eso: disabled` to skip all ESO resources and use the direct method instead.
> **Needs:** External Secrets Operator installed in the cluster.

All ESO objects live in their own per-tenant render
(`openbao-config-mto-<tenant>.eso`). If you enable ESO but the operator is
missing, only that render fails — the tenant's core OpenBao setup is
untouched, and everything heals on its own once ESO is installed.

**What the chart creates.** For each ServiceAccount you give a tier:

- a `SecretStore` named `<sa>-bao` that logs into OpenBao with the same role as the workload;
- for each cross-tenant import, an extra `SecretStore` named `<sa>.share-<peer>-bao`;
- one `ExternalSecret` for each Deployment annotation.

**How to use it.** Add an annotation to the `Deployment`. The value is `<reference>[#<field>]`:

| Annotation | Reads from | Through store |
|---|---|---|
| `bao.stakater.com/kv-secret.<name>: <leaf>[#<field>]` | your own app's prefix | `<sa>-bao` |
| `bao.stakater.com/kv-subscribe.<name>: <writer-ns>/<leaf>[#<field>]` | a sibling namespace's shared folder | `<sa>-bao` |
| `bao.stakater.com/kv-import.<name>: <peer>/<leaf>[#<field>]` | another tenant's shared space | `<sa>.share-<peer>-bao` |

- **With `#<field>`** → only that one field is copied into the Secret.
- **Without `#<field>`** → the whole secret is copied (every field becomes a key).

**Complete example.**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: team-a-api
  annotations:
    bao.stakater.com/kv-secret.db-creds: postgres        # the whole secret
    bao.stakater.com/kv-secret.api-key:  external#token  # just the "token" field
spec:
  template:
    spec:
      serviceAccountName: web
      containers:
        - name: web
          image: my/web:1.0
          envFrom:
            - secretRef:
                name: web-db-creds   # the Kubernetes Secret ESO creates, named <sa>-<name>
```

You write only the annotation. The chart generates the `ExternalSecret` for you:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: web-db-creds
  namespace: team-a-api
spec:
  refreshInterval: 1h            # from externalSecretRefreshInterval
  secretStoreRef:
    name: web-bao
    kind: SecretStore
  target:
    name: web-db-creds
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: dev/team-a-api/web/postgres
```

**Refresh.** ESO re-reads on `externalSecretRefreshInterval` (default `1h`). Every refresh is an OpenBao login, so don't set it too low.

---

## Feature: KV secrets

**What it is.** Each tenant gets a private key/value store (KV v2). A workload reads and writes secrets under its own namespace.

**Turn it on & what you need.** On by default — every tenant gets a `kv` store automatically. Cross-tenant sharing also needs the bootstrap chart (it creates the shared space). ESO is optional (see above).

### Access levels (tiers)

| Tier | KV access |
|---|---|
| `audit-read` | List names only — cannot read values |
| `viewer` | Read and list |
| `editor` | Create, read, update, list |
| `admin` | Everything `editor` has, plus delete (and delete/undelete/destroy of old versions) |

### Use it in your own namespace

Enable KV and set a tier on the ServiceAccount:

```yaml
# ServiceAccount for team-a's web app
metadata:
  name: web
  namespace: team-a-api
  annotations:
    bao.stakater.com/kv: "true"
    bao.stakater.com/tier: editor
```

The chart creates a policy and a login role scoped to the app's own prefix, `kv/data/dev/team-a-api/web/*`, plus the `bao-config-web` ConfigMap. The last path segment is the **app** — the ServiceAccount name, unless `bao.stakater.com/app` overrides it. Scoping to the app (not the namespace) is what stops two workloads in one namespace reading each other's secrets; to share deliberately inside the namespace, use its shared folder (next section).

> **Needs:** nothing extra to call OpenBao directly. ESO if you use the `kv-secret.<name>` Deployment annotation.
> **Consume:** read/write `VAULT_KV_APP_PATH` — see [Connecting a workload](#connecting-a-workload-to-openbao) — or have it delivered as a Secret with [ESO](#delivering-secrets-with-external-secrets-operator-eso).

### Share inside a tenant (namespace → namespace)

This works like a noticeboard. Each namespace owns a "shared folder" at `kv/data/dev/_shared/from-<namespace>/`. The owning namespace **writes** notes into its own folder; other namespaces in the same tenant **subscribe** to read them. The folder is named after the writer, so a reader always knows where a secret came from.

**Who writes, and how.** The folder `from-team-a-api/` belongs to namespace `team-a-api`. An `editor` or `admin` workload in `team-a-api` can write there **with no extra annotation** — write access to its own shared folder comes with the tier. The path is already in its ConfigMap as `VAULT_KV_SHARED_OUT_PATH`.

```yaml
# team-a-api's ServiceAccount — editor, so it may write its own shared folder
metadata:
  name: web
  namespace: team-a-api
  annotations:
    bao.stakater.com/tier: editor
```

The `team-a-api` workload writes to `VAULT_KV_SHARED_OUT_PATH` (= `kv/data/dev/_shared/from-team-a-api/`), the same way it writes its own secrets:

```bash
echo '{"data":{"token":"shared-value"}}' \
  | bao write "${VAULT_KV_SHARED_OUT_PATH}svc-token" -
```

**Who reads, and how.** A workload always reads its **own** shared folder automatically. To read **another** namespace's folder in the same tenant, it subscribes:

```yaml
# team-a-worker's ServiceAccount — reads what team-a-api shared
metadata:
  name: worker
  namespace: team-a-worker
  annotations:
    bao.stakater.com/tier: viewer
    bao.stakater.com/kv-subscribe-ns: team-a-api   # comma-separated for several
```

The subscriber's ConfigMap gains `VAULT_FROM_TEAM_A_API_PATH` (= `kv/data/dev/_shared/from-team-a-api/`); it reads `${VAULT_FROM_TEAM_A_API_PATH}svc-token`.

What each tier may do with a shared folder it can reach:

| Tier | Shared folder |
|---|---|
| `audit-read` | list names only — no values |
| `viewer` | read |
| `editor` | read + write (own folder only) |
| `admin` | read + write + delete (own folder only) |

Writing is always to your **own** folder; subscribing only ever grants **read**. So no namespace can write into another's folder — the direction is fixed.

> **Needs:** nothing extra to use OpenBao directly. ESO if you use the Deployment annotation `bao.stakater.com/kv-subscribe.<name>: team-a-api/<leaf>`.
> **Note:** you can only subscribe to namespaces in your own tenant. Naming an outside namespace stops the render with an error.

### Share across tenants (tenant → tenant)

Cross-tenant secrets don't live in either tenant — they go to a neutral **shared space** (the `shared/` OpenBao namespace, created once by the bootstrap chart), under `kv/data/dev/from-<writer>/to-<reader>/`. The folder name encodes both ends, so a secret from `team-a` for `team-b` sits at `from-team-a/to-team-b/`.

The important difference from same-tenant sharing: because the secret lives in the shared space, a workload logs into the **`shared/` namespace** (not its own tenant) using a dedicated role. The chart puts the namespace, role, and path in the ConfigMap so you don't have to know them.

**Who writes, and how.** The writer opts in on its ServiceAccount:

```yaml
# team-a's ServiceAccount — may write to team-b
bao.stakater.com/kv-export-tenant: team-b   # comma-separated for several peers
```

This creates a policy + login role (`share-team-a-<ns>-<sa>-out-team-b`) **in the shared space**, granting create/read/update/list on `from-team-a/to-team-b/*`. The workload logs into `shared/` with that role and writes — all values from its ConfigMap:

```bash
export VAULT_NAMESPACE="$VAULT_OUT_TEAM_B_NAMESPACE"   # shared/
export VAULT_TOKEN="$(bao write -field=token auth/kubernetes/login \
  role="$VAULT_OUT_TEAM_B_ROLE" \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)"
echo '{"data":{"api-key":"xyz"}}' | bao write "${VAULT_OUT_TEAM_B_PATH}creds" -
```

**Who reads, and how.** The reader opts in on its ServiceAccount:

```yaml
# team-b's ServiceAccount — may read what team-a sent
bao.stakater.com/kv-import-tenant: team-a
```

This creates a read-only policy + role (`share-team-b-<ns>-<sa>-in-team-a`) in the shared space, plus an ESO `SecretStore` named `<sa>.share-team-a-bao`. The reader logs into `shared/` with its IN role and reads `${VAULT_IN_TEAM_A_PATH}creds`, or has it delivered as a Kubernetes Secret:

```yaml
# team-b's Deployment
bao.stakater.com/kv-import.partner-key: team-a/creds   # → Secret via the share-in SecretStore
```

The two sides are independent: `team-a` exposing to `team-b` grants nothing until `team-b` also imports from `team-a`. Removing the import revokes `team-b`'s read. Removing the export only stops new writes: what `team-a` already wrote stays in the shared space, and `team-b` can still read it, older versions included. To withdraw a value, destroy it with all its versions first, then remove the export:

```bash
bao kv metadata delete -namespace=shared -mount=kv dev/from-team-a/to-team-b/creds
```

A plain `bao kv delete` is not enough: it marks only the latest version deleted, and `team-b` still reads the older ones with `?version=N`. The command needs a bao admin, or a `team-a` admin through the shared-space login below. Both revocation sentences assume the default `safety.grantDeletionProtection: false`; see [Deletion policy](#deletion-policy-safety-guardrails) for what stays behind with `true`.

**Who else can read it.** By default, only the workloads named above. The shared space can also get a login for people (`parent.sso.sharedSpace.enabled`, off by default). With it on, every viewer, editor and admin of `team-b` can read what `team-a` sent to `team-b`, not only the importing app — and those of `team-a` can read what `team-a` sent; `audit-read` lists names only. People see only the peers their own tenant's `kv-export-tenant` / `kv-import-tenant` annotations name. See [the shared-space login](#see-your-tenants-shares-in-the-web-ui).

> **Needs:** the bootstrap chart (creates the shared space) and MTO. ESO only for the Deployment delivery form.
> **Note:** if the peer tenant isn't in the roster yet, the share is skipped quietly and starts working on its own once that tenant is created.

---

## Feature: Transit (encryption)

**What it is.** Transit is "encryption as a service." A workload sends data to OpenBao and gets ciphertext back (and the reverse). The keys never leave OpenBao.

**Turn it on & what you need.** On by default (`transit.enabled`). Each tenant gets a `transit` engine and one **shared key** created up front; each namespace that opts in gets a **namespace key**, and each opted-in app gets its **own key** on top. All keys rotate automatically (default every 90 days).
> **Needs:** nothing beyond OpenBao. There is no ESO path — Transit is an operation, not a stored value.

### Access levels (tiers)

| Tier | Transit access |
|---|---|
| `viewer`, `audit-read` | None — Transit needs write access |
| `editor` | Encrypt, decrypt, rewrap |
| `admin` | Everything `editor` has, plus create/read/list/delete keys, rotate, data keys, sign/verify |

### Use it in your own namespace

```yaml
metadata:
  namespace: team-a-api
  annotations:
    bao.stakater.com/tier: editor
    bao.stakater.com/transit: "true"
```

This grants encrypt/decrypt/rewrap on **three** keys: the app's own key (private to this app), the namespace key (shared by every opted-in app in the namespace), and the tenant's shared key (shared across the tenant).

**Consume:** the ConfigMap gains, for each of the three keys, the key name and its encrypt/decrypt endpoints, plus the mount:

| Key | Variables |
|---|---|
| app (private) | `VAULT_TRANSIT_APP_KEY`, `VAULT_TRANSIT_APP_ENCRYPT`, `VAULT_TRANSIT_APP_DECRYPT` |
| namespace | `VAULT_TRANSIT_NS_KEY`, `VAULT_TRANSIT_NS_ENCRYPT`, `VAULT_TRANSIT_NS_DECRYPT` |
| tenant-shared | `VAULT_TRANSIT_SHARED_KEY`, `VAULT_TRANSIT_SHARED_ENCRYPT`, `VAULT_TRANSIT_SHARED_DECRYPT` |
| (mount) | `VAULT_TRANSIT_MOUNT` |

POST your data to an encrypt/decrypt path after logging in:

```bash
curl -s --request POST \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  --data '{"plaintext":"'"$(echo -n 'hello' | base64)"'"}' \
  "${VAULT_ADDR}/v1/${VAULT_TRANSIT_APP_ENCRYPT}"
```

### Share inside a tenant (namespace → namespace)

There's no producer/subscriber split here — Transit's shared key is symmetric, and **every** app that opts in with `transit: "true"` is granted the same tenant key. So any opted-in workload can encrypt, and any other can decrypt. (Each namespace also keeps a namespace key its own apps share, and each app keeps a private key nothing else can use.)

Both namespaces opt in the same way — no extra annotation:

```yaml
# team-a-api (producer) and team-a-worker (consumer) — each opts in
bao.stakater.com/tier: editor
bao.stakater.com/transit: "true"
```

Each pod logs into its own tenant (`team-a/`, where the shared key lives) and uses `VAULT_TRANSIT_SHARED_ENCRYPT` / `VAULT_TRANSIT_SHARED_DECRYPT` from its ConfigMap — the same key name on both sides:

```bash
# in team-a-api's pod — encrypt
ct=$(curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
  -d '{"plaintext":"'"$(echo -n hello | base64)"'"}' \
  "$VAULT_ADDR/v1/$VAULT_TRANSIT_SHARED_ENCRYPT" | jq -r .data.ciphertext)

# in team-a-worker's pod — decrypt the same ciphertext
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
  -d "{\"ciphertext\":\"$ct\"}" \
  "$VAULT_ADDR/v1/$VAULT_TRANSIT_SHARED_DECRYPT" | jq -r .data.plaintext | base64 -d
```

### Share across tenants (tenant → tenant)

For two different tenants, OpenBao creates one symmetric key per (writer, reader) pair in the **shared space**, named `from-team-a-to-team-b-dev`. The writer may encrypt, decrypt and rewrap; the reader may only decrypt and rewrap. Opt in on both sides:

```yaml
# team-a's ServiceAccount (writer)
bao.stakater.com/transit-export-tenant: team-b

# team-b's ServiceAccount (reader)
bao.stakater.com/transit-import-tenant: team-a
```

Each side gets a login role in the `shared/` space and the paths in its ConfigMap. Because the key lives in the shared space, both log into `shared/` (not their own tenant):

```bash
# team-a (writer) — log into the shared space, then encrypt
export VAULT_NAMESPACE="$VAULT_TRANSIT_OUT_TEAM_B_NAMESPACE"   # shared/
export VAULT_TOKEN="$(bao write -field=token auth/kubernetes/login \
  role="$VAULT_TRANSIT_OUT_TEAM_B_ROLE" \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)"
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
  -d '{"plaintext":"'"$(echo -n hello | base64)"'"}' \
  "$VAULT_ADDR/v1/$VAULT_TRANSIT_OUT_TEAM_B_ENCRYPT"
```

team-b (reader) logs into `shared/` with `$VAULT_TRANSIT_IN_TEAM_A_ROLE` and decrypts at `$VAULT_TRANSIT_IN_TEAM_A_DECRYPT`.

> **Needs:** the bootstrap chart (creates the shared space). No ESO — Transit is an operation, not a stored value.

---

## Feature: PKI (certificates)

**What it is.** Each tenant gets its own certificate authority (CA) and can issue TLS certificates for its services — for example for HTTPS and for service-to-service mTLS.

**Turn it on & what you need.** On by default (`pki.enabled`). Each tenant gets a `pki` engine, a CA, and one or more issuing roles. The default role lets a tenant issue certificates for `*.svc.cluster.local` names in its own namespaces, valid for 7 days.

There are two CA setups:

- **Shared trust (default).** The tenant CA is an **intermediate**, cross-signed by a cluster-wide **platform** CA that the bootstrap chart creates — so every tenant chains back to one anchor. The platform CA itself comes in two flavours:
  - `platformPki.mode=root` (default): the platform CA is a self-signed root.
    Chain: **platform root CA → tenant intermediate CA → leaf**.
  - `platformPki.mode=intermediate` (production): the platform CA is itself an intermediate, signed by *your own offline root*.
    Chain: **offline root CA → platform intermediate CA → tenant intermediate CA → leaf**.
- **Standalone.** Set `pki.hierarchy.enabled=false` and each tenant gets its own self-signed root CA, with no common anchor.
  Chain: **tenant root CA → leaf**.

> **Needs:** [cert-manager](https://cert-manager.io/) for certificate issuance through Kubernetes; the platform CA (from the bootstrap chart) for the default shared-trust setup.

### What bounds a certificate, and what doesn't

Two separate limits apply, and they behave differently over time.

**The role** decides what it will issue: `allowedDomainsTemplate` becomes the role's allowed names, one entry per tenant namespace. The role is rewritten on every render, so it tracks namespaces as they come and go.

**The tenant CA** carries *name constraints* — a limit baked into the CA certificate itself, which every verifier enforces on the whole chain. In shared-trust mode the chart sets them from the same domains. Unlike the role, **a CA's constraints are fixed when the CA is created**: OpenBao treats an existing CA as final (regenerating one would destroy its private key), so later renders cannot widen them. Two consequences worth knowing before you turn PKI on:

- A namespace added to the tenant *after* the CA exists is not in the CA's constraints. The role will happily issue a certificate for it and every verifier will then reject the chain. If you add namespaces to a tenant that has been running a while and certificates start failing validation for the new namespace only, this is why — the fix is to re-create the tenant CA (which invalidates certificates already issued from it), so prefer creating the tenant's namespaces before enabling PKI.
- **The CA waits for the tenant's first namespace.** A `Tenant` is normally created before its namespaces carry the tenant label, and in that window there are no per-namespace domains to constrain the CA with — the only limit derivable from the templates alone is their literal suffix (`{namespace}.svc.cluster.local` → `svc.cluster.local`), which permits every namespace in the cluster, including every other tenant's. Because constraints are fixed at creation that would be permanent, so the chart does not create the CA at all until the tenant has a namespace: the engine mount and the roles render, the CA follows on the next render. Nothing can issue in that window anyway. The cross-tenant trust `Bundle` waits with it, since it sources the CA's own ConfigMap.
- **The same rule runs backwards, so un-labelling a tenant's last namespace is destructive.** A render cannot see that a CA already exists, so a running tenant whose namespaces stop matching — labels removed, `tenantLabelKey` changed, tenant scaled to zero namespaces — loses the CA object and the `<tenant>-ca` ConfigMap with it, and every peer trusting this tenant gets an unresolvable Bundle source. Whether the CA *in OpenBao* survives is down to `safety.deletionProtection` (on by default, which orphans rather than destroys it) — but if the namespaces come back the chart recomputes name constraints while OpenBao keeps the CA it already had, so the resource then advertises constraints nothing enforces.
- The CA is constrained in **both** modes. A self-signed tenant root is not automatically safer than an intermediate: under cross-tenant trust a peer trusts it directly as an anchor, so there is nothing above it to bound what it signs. A catalog that yields no domains for any namespace fails the render rather than producing an unconstrained CA.

Name constraints cover **DNS names only**. An IP address in a certificate is bounded by neither the CA's constraints nor `allowedDomains`, which is why the shipped role sets `allowIpSans: false` (OpenBao's own default is `true`). Turn it on only for a workload that genuinely presents certificates by IP.

Everything in a `pki.roles[]` entry other than the two template fields is passed straight through to the role and **left out when you don't set it**, meaning OpenBao's default applies. `values.yaml` lists each field with that default; a misspelled key is rejected by the values schema rather than silently ignored.

**Changing the catalog.** Set `parent.pki.roles` in the bootstrap chart (or `pki.roles` when using the per-tenant chart standalone) — the bootstrap value is passed straight through to every tenant, so the catalog is install-wide. Leave it empty to keep the shipped single-role default. `nameTemplate` must render a distinct, valid Kubernetes name per entry: it becomes the OpenBao role, the `OpenBaoPKISecretEngineRole` and the cert-manager `Issuer`, so the chart fails the render on a collision, on a name the API server would reject, and on one over 253 characters.

### Two ways to get a certificate

**1. Through cert-manager (recommended).** Turn on `parent.certManager.enabled` in the bootstrap chart (or `pki.certManager.enabled` when using the per-tenant chart standalone). The chart creates a cert-manager `Issuer` (named after the tenant's PKI role) in each namespace that opts in, all inside a separate per-tenant render (`openbao-config-mto-<tenant>.certmanager`) — so a cluster without cert-manager fails only that render, never the tenant's core setup. Your app then requests a certificate the normal cert-manager way:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: team-a-api
spec:
  secretName: web-tls
  issuerRef:
    name: team-a-svc          # the Issuer the chart created
    kind: Issuer
  commonName: web.team-a-api.svc.cluster.local   # required — see below
  dnsNames:
    - web.team-a-api.svc.cluster.local
```

`commonName` is not optional here. The tenant's PKI role keeps OpenBao's
default `require_cn`, so a `Certificate` with only `dnsNames` is refused at
signing time — the `Certificate` sits at `Ready=False`, and the reason is on
the `CertificateRequest`, not the `Certificate`:

```text
kubectl describe certificaterequest -n team-a-api
  ... the common_name field is required, or must be provided in a CSR with
      "use_csr_common_name" set to true, unless "require_cn" is set to false
```

cert-manager logs into OpenBao with its own identity, so the workload does **not** need the `bao.stakater.com/pki` annotation here. cert-manager also generates the private key **inside the cluster** and only sends a CSR to OpenBao — the key never leaves your cluster (the same best practice as `sign`, below).

**Where cert-manager's permission comes from.** To log into OpenBao,
cert-manager mints a short-lived token for the `bao-cert-manager` ServiceAccount
in the workload namespace. The bootstrap chart defines that permission once, as
a `ClusterRole` named `bao-cert-manager-token-create`, and the `.certmanager`
render binds it per namespace with an ordinary `RoleBinding`. A `RoleBinding`
grants a `ClusterRole`'s rules **only inside its own namespace**, so
cert-manager can mint that one token in the namespaces that opted into PKI and
nowhere else — and `resourceNames` pins it to the `bao-cert-manager`
ServiceAccount alone, not to every ServiceAccount in those namespaces.

The definition has to sit in the bootstrap chart rather than in the render.
template-operator-v2 checks an entire render against the cluster before applying
any of it, and that check never writes anything — so a `Role` shipped alongside
its own `RoleBinding` does not exist at the moment Kubernetes resolves the
binding's `roleRef`. The binding is rejected, the whole render is abandoned, and
the `Role` that would have unblocked it never gets written. Kubernetes treats
this as working as designed ([kubernetes/kubectl#1575](https://github.com/kubernetes/kubectl/issues/1575)),
so the chart works around it by having helm — which runs as a cluster admin and
writes for real — create the definition up front.

Installing the per-tenant chart standalone (`component: all`) keeps a plain
namespaced `Role` instead, because helm writes it for real and there is no
check to fail.

**2. Directly from OpenBao.** Add `bao.stakater.com/pki: "true"` to the ServiceAccount. The ConfigMap then gives the workload two endpoints, and **which one you use matters for security**:

- `VAULT_PKI_SIGN_PATH` (`pki/sign/<role>`) — **you generate the private key**, send only a certificate signing request (CSR), and OpenBao returns just the signed certificate. The key never leaves the pod. **Prefer this.**
- `VAULT_PKI_ISSUE_PATH` (`pki/issue/<role>`) — **OpenBao generates the private key** and returns it together with the certificate. Convenient, but the private key travels over the network and ends up wherever the response goes.

(`VAULT_PKI_CA_PATH` returns the CA chain for verifying what you get back; `VAULT_PKI_MOUNT` and `VAULT_PKI_ROLE` name the mount and the primary role the paths above are built from.)

**Recommended — sign your own CSR (key stays in the pod):**

```bash
# 1. Generate a key + CSR locally — the key never leaves this container.
openssl req -newkey rsa:2048 -nodes -keyout tls.key \
  -subj "/CN=web.team-a-api.svc.cluster.local" -out req.csr

# 2. Send only the CSR; OpenBao returns just the signed certificate.
jq -n --rawfile csr req.csr --arg ttl 72h '{csr: $csr, ttl: $ttl}' \
  | curl -s --request POST \
      --header "X-Vault-Token: ${VAULT_TOKEN}" \
      --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
      --data @- \
      "${VAULT_ADDR}/v1/${VAULT_PKI_SIGN_PATH}" \
  | jq -r '.data.certificate'
```

**Quick but less safe — let OpenBao make the key:**

```bash
curl -s --request POST \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  --data '{"common_name":"web.team-a-api.svc.cluster.local","ttl":"72h"}' \
  "${VAULT_ADDR}/v1/${VAULT_PKI_ISSUE_PATH}"
# the response holds .data.certificate AND .data.private_key — the key crossed the wire
```

### Trust within a tenant

There's nothing to set up — PKI has no per-namespace sharing. Every namespace in a tenant gets its certificates from the **same** tenant CA, so they already trust one another. A workload validates a sibling's certificate against that CA, which it can read at `VAULT_PKI_CA_PATH` (or from the trust bundle below). Trust only has to be granted when you cross a tenant boundary.

### Trust across tenants

Different tenants have different CAs, so by default they don't trust each other. Trust is **opt-in**, **directional**, and decided by the **consuming** side — a peer can never grant itself trust. Turn it on with `crossTenantPki.enabled` in the bootstrap chart (or `pki.crossTenant.enabled` when using the per-tenant chart standalone), then opt in with an annotation on one of your ServiceAccounts. The trust bundle lives in its own per-tenant render (`openbao-config-mto-<tenant>.trust`), independent of the cert-manager toggle — a cluster without trust-manager fails only that render. The two annotations match the two directions of a call:

- **`pki-trust-tenant: team-b`** — *outbound.* "I call team-b and need to trust the **server** certificate it presents." Adds team-b's CA to your trust bundle — nothing more.
- **`pki-allow-tenant: team-b`** — *inbound.* "I accept team-b as a **client** calling me." You can't accept a client you can't authenticate, so this **implies trust**: it adds team-b's CA to your bundle *and* lists team-b in your accepted-clients (the authorization layer). This one annotation covers the whole inbound case — you don't add `pki-trust-tenant` as well.

| Annotation (on a `team-a` ServiceAccount) | Use when | Peer CA in team-a's bundle | Peer in team-a's accepted-clients |
|---|---|---|---|
| `bao.stakater.com/pki-trust-tenant: team-b` | team-a **calls** team-b (outbound) | yes | no |
| `bao.stakater.com/pki-allow-tenant: team-b` | team-b **calls** team-a (inbound) | yes | yes |

**The rule that keeps this safe:** `allow` implies `trust`, but `trust` never implies `allow`. Deriving trust from allow is fine — you can't accept a client you can't authenticate. Deriving allow *from* trust would be **fails-open**: a peer you trust only so you can *call* it must never silently become an accepted *inbound* client. So `pki-trust-tenant: team-b` lets team-a call team-b, but does **not** let team-b call team-a. Both annotations take a comma-separated list of peers.

**Worked example — `team-b` calls `team-a` over mTLS.** team-a is the server, team-b is the client. Each side must trust the other's CA, and the server also authorizes the client. So each side adds one annotation:

```yaml
# a team-a ServiceAccount (server side) — accept team-b as a client
bao.stakater.com/pki-allow-tenant: team-b
```

```yaml
# a team-b ServiceAccount (client side) — trust team-a's server certificate
bao.stakater.com/pki-trust-tenant: team-a
```

**What the chart creates** (for `team-a`, opting into `team-b`):

- `team-a-ca` — a ConfigMap holding team-a's CA cert (the operator publishes it; `team-b` gets `team-b-ca` the same way).
- `team-a-trust` — a trust-manager `Bundle` that merges team-a's own CA with each opted-in peer's CA and syncs it into every team-a namespace (shown below).
- `team-a-pki-allowed-tenants` — a ConfigMap (in the operator namespace) listing the accepted client tenants, e.g. `allowed-tenants: team-b`. Created only for `pki-allow-tenant`.

The Bundle the chart writes:

```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: team-a-trust              # cluster-scoped, chart-authored — tenants can't self-grant
spec:
  sources:
    - configMap: { name: team-a-ca, key: ca.crt }   # own CA
    - configMap: { name: team-b-ca, key: ca.crt }   # opted-in peer
  target:
    configMap: { key: trust-bundle.pem }
    namespaceSelector:
      matchLabels: { stakater.com/tenant: team-a }   # synced into team-a namespaces only
```

trust-manager writes a ConfigMap named `team-a-trust` (key `trust-bundle.pem`) into each of those namespaces.

**How a workload uses it.** Mount that ConfigMap and point your TLS stack at `trust-bundle.pem` as its CA trust store:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: team-a-api
spec:
  template:
    spec:
      volumes:
        - name: tenant-trust
          configMap:
            name: team-a-trust            # synced here by trust-manager
      containers:
        - name: api
          volumeMounts:
            - name: tenant-trust
              mountPath: /etc/ssl/tenant-trust
              readOnly: true
          # set your server/client CA bundle to /etc/ssl/tenant-trust/trust-bundle.pem
```

**Fails closed.** The bundle holds only team-a's own CA plus the peers it explicitly opted into — never the whole platform. A certificate from any other tenant fails the TLS handshake. Keep the two decisions separate: trusting a peer's CA lets you *verify* its certs; the `team-a-pki-allowed-tenants` list is what your app or service mesh checks to *authorize* an inbound caller.

**Limiting to one app is the app's (or mesh's) job — not the chart's.** The chart works at **tenant** granularity: `pki-allow-tenant: team-b` accepts *any* team-b workload, and `team-a-pki-allowed-tenants` lists accepted peer **tenants**, not apps. It does not matter which ServiceAccount you put the annotation on — the chart aggregates them across the whole tenant. To allow only one app — say team-b may call `payments` but not `admin` — your app or service mesh enforces it using the caller's certificate name (its SAN). For example `payments` accepts a client whose SAN is `*.team-b-prod.svc.cluster.local` (or just `web.team-b-prod.svc.cluster.local` for one app), while `admin` accepts none. The chart hands you the trusted CA plus the allowed-tenant list; turning that into a per-app rule is done in your app config or a mesh `AuthorizationPolicy`.

> **Needs:** [trust-manager](https://cert-manager.io/docs/trust/trust-manager/), installed with its trust namespace set to the operator namespace (that's where the `<tenant>-ca` source ConfigMaps live).

---

## Feature: Human SSO (OIDC login)

**What it is.** People can log into OpenBao with your company's single sign-on, instead of using a token. Their access is decided by the groups they belong to in the identity provider (IdP).

**Turn it on & what you need.** Off by default. Set `sso.enabled: true` and point `sso.dex.issuerUrl` at your IdP.
> **Needs:** an OIDC identity provider (such as Dex) and a Kubernetes Secret holding the client secret. People log in with the `bao` CLI, or with the web UI once its callback is allowed (see **Redirect URIs** below).

### How access maps

For each tier in `sso.tiers`, the chart creates a login role bound to an IdP group. By default the group name is `<tenant>-<tier>s` — so members of the IdP group `team-a-admins` get the `admin` tier in `team-a`. Unlike a workload (which is limited to one namespace), a logged-in person gets that tier across the whole tenant.

| Tier | What a person can do |
|---|---|
| `admin` | Full KV (including delete), full Transit, issue certificates and manage roles. Cannot destroy the CA. |
| `editor` | Read/create/update KV; encrypt/decrypt with Transit; issue certificates. |
| `viewer` | Read KV; read Transit and PKI. No changes. |
| `audit-read` | List KV names; list Transit keys; read PKI. No values. |

**No tier can replace the tenant CA.** The CA's key and its name constraints are the tenant's whole PKI trust boundary, and every OpenBao path that can replace it is a way out of that boundary rather than just a destructive button: `root/sign-intermediate` and `root/sign-self-issued` sign a CSR the caller supplies, making the holder an issuer under the tenant CA, and `intermediate/set-signed` accepts a certificate from *any* issuer, so the holder could install an unconstrained CA of their own into the mount and then issue for a peer's names on a chain that peer trusts. Replacing a tenant CA is a platform-operator action against OpenBao, not an SSO tier. (A `super-admin` tier holding exactly these grants was removed.)

> **Upgrade note — removing `super-admin` does not always revoke it.** Only relevant if SSO was already on before this tier was dropped; with `sso.enabled: false` (the default) it was never created and there is nothing to do. The chart stops rendering `sso-<tenant>-super-admin`, and the operator then deletes the OpenBao policy and OIDC role — *unless* `safety.grantDeletionProtection: true`, which renders grants as `deletionPolicy: Retain`, so the OpenBao objects are orphaned rather than removed and the login keeps working with its old grants. Check the live posture:
>
> ```bash
> kubectl -n openbao-config-operator-system \
>   get openbaopolicy,openbaojwtoidcauthengineroles \
>   -o custom-columns=KIND:.kind,NAME:.metadata.name,DELETION:.spec.deletionPolicy \
>   | grep super-admin
> ```
>
> `Delete` (what the default `grantDeletionProtection: false` produces) means the upgrade revokes it and no action is needed. If it says `Retain`, set `safety.grantDeletionProtection: false` and let the CRs re-render as `Delete` *before* upgrading. Hand-patching the CR does not work: template-operator-v2 owns those fields via server-side apply and `sync.mode: revert` undoes it.

**Redirect URIs.** OpenBao rejects an OIDC role with an empty `allowed_redirect_uris`, so the chart fails the render when SSO is on and the list is empty rather than emitting a role nobody can log in through. The default is the `bao` CLI's loopback listener (`http://localhost:8250/oidc/callback`); set `parent.sso.allowedRedirectUris` in the bootstrap chart to add a browser console callback.

For the web UI, one entry serves every namespace — each tenant's and the shared space:

```yaml
parent:
  sso:
    allowedRedirectUris:
      - "http://localhost:8250/oidc/callback"
      - "https://openbao.example.com/ui/vault/auth/oidc/oidc/callback"
```

The UI does send the namespace (`…/oidc/callback?namespace=team-a`), but OpenBao takes it out of the URL and carries it in the OIDC `state` before it checks the list (`namespace_in_state`, on by default), so the IdP also sees only the bare URL. Allow that same URL on the IdP client.

**The IdP client.** Every OIDC mount — each tenant's, and the shared space's when its login is on — uses one client, set once in the bootstrap chart: `parent.sso.clientId`, `parent.sso.clientSecretRef` (a Secret in the operator namespace), `parent.sso.caBundlePem` and `parent.sso.audience`. Every role checks `audience` against the token's `aud` claim, which Dex and Keycloak set to the client ID, so change the two together. With SSO on, the render fails if `clientId`, `clientSecretRef.name`, `clientSecretRef.key` or `audience` is null or empty.

> **Upgrade note — `helm upgrade --reuse-values` with SSO on stops.** `--reuse-values` replaces the new chart's defaults with the old chart's, so the four client values above are missing and the render fails with `parent.sso.enabled=true requires parent.sso.clientId`. Use `--reset-then-reuse-values` (Helm 3.14+), which keeps your values on top of the new defaults, or set the four values yourself.

SSO tokens are short-lived (default 15 minutes, renewable up to 1 hour), because a group change in the IdP applies only at the next login: a person removed from a group keeps the old access until the token expires.

### Logging in

```bash
bao login -method=oidc -namespace=team-a role=sso-team-a-admin
```

### Optional: a fallback role

A standalone render of the tenant chart (no bootstrap chart) can set `sso.tenantRoleMapping.fallback` to a tier name to also create `sso-<tenant>-fallback`. That role has no group requirement — anyone with a valid login from the IdP gets that tier. The default `deny` creates no fallback role. The bootstrap chart does not pass `sso.tenantRoleMapping` through, so under it the fallback role never exists.

### See your tenant's shares in the web UI

Shares between tenants live in the shared space (`shared/`), not in the tenant's own namespace, so a login to `team-a` does not show them. The shared space has its own login for people. It is off by default; turn it on in the bootstrap chart:

```yaml
parent:
  sso:
    enabled: true
    issuerUrl: https://keycloak.example.com/realms/platform
    allowedRedirectUris:
      - "http://localhost:8250/oidc/callback"
      - "https://openbao.example.com/ui/vault/auth/oidc/oidc/callback"
    sharedSpace:
      enabled: true
```

This adds one OIDC mount to the shared space, on the same IdP client as the tenant mounts (see [The IdP client](#how-access-maps) above). Each tenant then gets one role per tier there, with the **same name and the same IdP group** as its tenant role. The bootstrap chart fails the render if `issuerUrl`, `clientId`, `clientSecretRef.name`, `clientSecretRef.key` or `audience` is empty, or if `openbaoConfigMto.version` names a tenant chart older than 0.21.0 (one that renders no shared-space role).

**Log in.** In the web UI: set **Namespace** to `shared`, **Method** to OIDC, and **Role** to your tier's role, for example `sso-team-a-viewer`. With the CLI:

```bash
bao login -method=oidc -namespace=shared role=sso-team-a-viewer
```

**Open a share by its link.** A person cannot browse `dev/`: that list would show which tenants share with which, and an OpenBao list cannot be filtered. Every `bao-apps` ConfigMap of the tenant has a `_sharedSpace` entry with the login link, the tenant's role names, and one link per partner tenant:

```console
$ kubectl get cm bao-apps -n team-a-worker -o jsonpath='{.data._sharedSpace}'
namespace: shared
login: "https://openbao.example.com/ui/vault/auth?namespace=shared&with=oidc"
roles: "sso-team-a-admin, sso-team-a-editor, sso-team-a-viewer, sso-team-a-audit-read"
received:
  team-b: "https://openbao.example.com/ui/vault/secrets/kv/list/dev/from-team-b/to-team-a/?namespace=shared"
sent:
  team-b: "https://openbao.example.com/ui/vault/secrets/kv/list/dev/from-team-a/to-team-b/?namespace=shared"
```

The address is the UI callback in `sso.allowedRedirectUris` without its path. Without a UI callback there, the links start at `/ui/`. The entry exists while the shared-space login is on and the tenant has a share, and it follows the share annotations. The folders, by path:

| You want | Path | Web UI address |
|---|---|---|
| What `team-b` sent to `team-a` | `dev/from-team-b/to-team-a/` | `https://openbao.example.com/ui/vault/secrets/kv/list/dev/from-team-b/to-team-a/?namespace=shared` |
| What `team-a` sends (lists its peers) | `dev/from-team-a/` | `https://openbao.example.com/ui/vault/secrets/kv/list/dev/from-team-a/?namespace=shared` |

**What each tier can do here:**

| Tier | Shares the tenant sends | Shares the tenant receives |
|---|---|---|
| `admin` | read, create, update, delete | read |
| `editor` | read, create, update | read |
| `viewer` | read | read |
| `audit-read` | list names | list names |

A received share is read-only for every tier: the sending tenant owns it.

**Who sees what.** A role names only the peers that the tenant's own `kv-export-tenant` and `kv-import-tenant` annotations name — the same peers its workloads can reach. A share that another tenant sends, but that no app of this tenant imports, stays hidden. A tenant with no share gets no role in the shared space.

**Taking access away.** With the default `safety.grantDeletionProtection: false`, OpenBao follows within one re-render of the tenant, and live tokens lose access on their next request after that:

- Removing one of several share annotations rewrites the tier policies without that peer.
- Removing the tenant's last share, or turning `parent.sso.sharedSpace.enabled` off, deletes its roles and policies in the shared space.

Turning the login off leaves the empty `oidc` mount in the shared space under the default `safety.deletionProtection: true`, because a mount is data (`Retain`); with `false` the mount is removed too. Either way no role is left, so nobody can log in through it.

With `safety.grantDeletionProtection: true`, the rewrite of a remaining policy still applies. But every grant whose CR is deleted is kept in OpenBao, and its login keeps working. A bao admin must delete it in the shared space:

```bash
# a person's login and policy, per tier (admin, editor, viewer, audit-read)
bao delete        -namespace=shared auth/oidc/role/sso-<tenant>-<tier>
bao policy delete -namespace=shared sso-<tenant>-<tier>
# a workload's share grant, after its kv-import-tenant / kv-export-tenant is removed
bao delete        -namespace=shared auth/kubernetes/role/share-<tenant>-<ns>-<sa>-in-<peer>
bao policy delete -namespace=shared share-<tenant>-<ns>-<sa>-in-<peer>   # -out-<peer> for an export
```

**Limits.**

- **No fallback role in the shared space.** The tenant's fallback role (above) lets any IdP user into that tenant's own data. Under the bootstrap chart it never exists — `sso.tenantRoleMapping` is not passed through, so the tenant chart's packaged `deny` holds — and only a standalone render or a repackaged chart turns it on. In the shared space it would also open what *other* tenants sent, and they agreed to share with the tenant, not with every IdP user.
- **KV only.** The shared transit keys are not exposed to people.
- **Every viewer, editor and admin of the receiving tenant reads every received share** (`audit-read` lists names). A share goes to a tenant, not to one person. If a value must reach only one app, do not send it across tenants.

---

## Which auth methods the charts set up

OpenBao supports several login methods. **These charts set up two:**

| Method | Set up by the charts? | Used for |
|---|---|---|
| Kubernetes | Yes, always | Workloads log in with their ServiceAccount token |
| OIDC | Yes, when SSO is on | People log in through the IdP — in their tenant's namespace, and in the shared space when `parent.sso.sharedSpace.enabled` is on |
| JWT | No | — |
| cert | No | — |

The operator itself can manage JWT and cert login too, but the charts don't generate them. If you need those, create the resources yourself (see the [operator README](https://github.com/stakater-ab/openbao-config-operator) and [CRD reference](https://github.com/stakater-ab/openbao-config-operator/blob/main/docs/crd-reference.md)).

---

## Checking health

The parent `TemplateInstance` aggregates the health of everything the charts render into one object, so a single read covers the whole install:

```bash
kubectl -n openbao-config-operator-system get templateinstances.templates.v2.stakater.com \
  openbao-config-mto-parent -o jsonpath='{.status.outputs}' | jq .
```

Note the fully-qualified resource name — `kubectl get ti` resolves to the older `templateinstances.tenantoperator.stakater.com`.

The map has two halves. The `shared*` fields cover the singletons the parent renders itself — the shared bao namespace, its KV and transit engines, the kubernetes auth mount and that mount's config, and, with the shared-space login on, its OIDC mount and config. Nothing else reports on these, and they sit behind every tenant: if `sharedAuthConfigReady` is not `True`, no workload in any tenant can log into bao; if `sharedOidcConfigReady` is not `True`, no person can log in to the shared space. The `ti*` fields cover one child `TemplateInstance` per tenant per slice, and which one is `False` says who fixes it:

| Field | `False` means |
|---|---|
| `tiNsAllowed` | the TI landed outside the operator namespace — chart or bootstrap misconfiguration |
| `tiParamsValid` | a parameter would not resolve, usually the tenant has no matching namespaces |
| `tiRendered` | the chart itself failed to render for this tenant |
| `tiApplied` | apply was refused — a missing CRD for an optional integration, or a missing RBAC grant |
| `tiSynced` | drift watches are not active (absent entirely when `sync.mode: off`) |
| `tiReady` | the roll-up; consult the others to place the fault |

Two things to know before trusting the values.

**Read `OutputsResolved` and `outputsObservedAt` alongside the map.** When the serialized outputs exceed template-operator-v2's size cap, the previous values are retained rather than replaced — so a fully populated, plausible map can be arbitrarily old. A failed source watch means the same thing more quietly: correct now, never refreshed again. Both states are reported on the condition, not in the values.

```bash
kubectl -n openbao-config-operator-system get templateinstances.templates.v2.stakater.com \
  openbao-config-mto-parent \
  -o jsonpath='{.status.outputsObservedAt}{"\n"}{.status.conditions[?(@.type=="OutputsResolved")].message}{"\n"}'
```

**Each field holds at most 50 entries.** Past that, entries are dropped and `OutputsResolved` reports the overflow. Since `ti*` carries one entry per child TI, the aggregate covers 50 children — with four slices enabled per tenant, twelve tenants. Beyond that scale, read the child TemplateInstances directly rather than the parent's roll-up.

A `True` value is stored as the string `["True"]`, not `True` — the jsonPaths are condition filters and a filter result is JSON-encoded. To list what is unhealthy:

```bash
kubectl -n openbao-config-operator-system get templateinstances.templates.v2.stakater.com \
  openbao-config-mto-parent -o jsonpath='{.status.outputs.tiReady}' \
  | jq -r 'to_entries[] | select(.value != "[\"True\"]") | .key'
```

That also catches entries reading `[]`, which is a child that has not reported the condition yet.

## Drift protection

The bootstrap chart turns on template-operator-v2's drift protection (`sync.mode: revert`, the chart's default — template-operator-v2's own default is `off`) for everything the Templates render: the per-tenant OpenBao resources, the `bao-config-<sa>` ConfigMaps, the ESO stores, and so on.

**Minimum version: template-operator-v2 ≥ 0.0.5** — the chart's child TemplateInstances need `namespaceSelector`, which released CRDs carry only from 0.0.5. `spec.sync` itself exists since 0.0.3; on a pre-0.0.3 install the API server silently prunes the block (the chart installs cleanly and drift protection is simply absent). `strict` was verified working on 0.0.5; see the `strict` notes below.

**The enforcement webhook fails closed, in every mode.** template-operator-v2 installs a cluster-wide `sync-enforcement` ValidatingWebhookConfiguration with `failurePolicy: Fail`, and its CEL `matchConditions` select on the `templates.v2.stakater.com/instance` label — not on `sync.mode`. The mode check lives inside the handler, which never runs when the operator pod is unreachable. So while template-operator-v2 is down, every update and delete of a rendered resource is refused whatever mode you set:

```text
Error from server (InternalError): failed calling webhook
"sync-enforcement.templates.v2.stakater.com": no endpoints available
```

The flip side is that rendered resources cannot drift during an outage either — edits, key additions, deletes, and removing the ownership label are all refused — so no window exists in which drift accumulates unwatched. Verified with `sync.mode: revert` and template-operator-v2 scaled to zero. This is not a cost `strict` introduces; `revert` and `off` already pay it.

**What it does.**

- If someone edits a rendered resource out of band — say, changes a value in a `bao-config-<sa>` ConfigMap — template-operator-v2 notices and puts it back within seconds. Each revert leaves a `Drift detected` line in the template-operator-v2 logs.
- If a rendered resource is missing entirely, it is recreated immediately — the deletion event itself triggers the re-apply.
- Every per-tenant render reports a `Synced` condition — `True` means the drift watches are active, not that no drift has ever occurred. It is aggregated per tenant on the parent (with `sync.mode: off` the condition doesn't exist, so `tiSynced` reads empty):

  ```bash
  kubectl -n openbao-config-operator-system \
    get templateinstances.templates.v2.stakater.com openbao-config-mto-parent \
    -o jsonpath='{.status.outputs.tiSynced}'
  ```

  See [Checking health](#checking-health) for the rest of the aggregate and how to read it.

**What it does not do.**

- **A direct delete does not come back on its own.** Rendered resources carry a template-operator-v2 finalizer in every mode (`off` included), so `kubectl delete` leaves the object stuck in `Terminating` instead of removing it — its data keeps being served, but it is not recreated fresh. To force a clean recreate, remove the finalizer; the delete then completes and the resource is recreated immediately:

  ```bash
  kubectl -n team-a-api patch cm bao-config-web --type=merge \
    -p '{"metadata":{"finalizers":null}}'
  ```

- **Deleting a per-tenant `TemplateInstance` is not blocked.** That removes the tenant's whole rendered config — `revert` has no admission webhook; only `strict` blocks deletes.
- The bootstrap chart's own resources (the Templates, the parent `TemplateInstance`, RBAC, the platform PKI) are managed by helm/GitOps, not by sync.

**Turning it off.** Set `sync.mode: off` in the bootstrap values. The Templates are then rendered without a `spec.sync` block.

**Upgrading from 0.3.x.** A plain `helm upgrade` turns drift protection on — `revert` is the chart's default. If anyone has been hand-editing rendered resources and relying on those edits sticking, they stop sticking at that moment. Set `sync.mode: off` in your values alongside the upgrade to keep the old behavior.

**About `strict`.** `strict` adds an admission webhook that blocks updates and deletes of rendered resources by anyone other than template-operator-v2 itself (the webhook exempts exactly one identity — template-operator-v2's own ServiceAccount, configured at operator startup; there is no user-facing allowlist). Before enabling it, know that:

- The webhook registers for UPDATE and DELETE on `*` with `failurePolicy: Fail`, narrowed by a CEL `matchConditions` guard to objects carrying the `templates.v2.stakater.com/instance` label. Creates are unaffected, and unlabelled objects are not intercepted. (This webhook is installed regardless of the mode you choose — see the fails-closed note above.) Confirm the guard is present on your install before enabling: `kubectl get validatingwebhookconfiguration <name> -o jsonpath='{.webhooks[0].matchConditions}'` — an empty result means interception is cluster-wide.
- The guard also evaluates `oldObject`, so removing the ownership label to escape enforcement is itself blocked.
- Subresources are not intercepted (`*` does not match `*/status`), so controllers that only write status — including the OpenBao operator — are unaffected.
- You must set `sync.ignoreFields: ["metadata.finalizers"]` so the OpenBao operator can add its finalizers to the rendered CRs. Without it, every newly rendered CR sticks at `Ready=False` with the operator's finalizer patch denied. **Note the cost:** that entry exempts the whole finalizers array from enforcement, so anyone with `patch` on a rendered resource can replace it — dropping template-operator-v2's own finalizer and adding one no controller will ever clear, which makes the object permanently undeletable. template-operator-v2 restores its finalizer only on the next real re-apply.
- **Deleting a namespace that holds rendered resources can wedge it.** DELETE is refused unless the owning TemplateInstance is itself being deleted, so the namespace controller's cleanup of a rendered ConfigMap or CR is denied and the namespace can sit in `Terminating`. Delete the per-tenant TemplateInstance first. `revert` is unaffected — it has no admission enforcement at all.

Test on a non-production cluster first.

**RBAC note.** The bootstrap chart grants template-operator-v2's ServiceAccount cluster-wide access to the kinds the per-tenant chart renders into tenant workload namespaces — ConfigMaps, SecretStores/ExternalSecrets, Issuers, NetworkPolicies — because those namespaces are created per tenant and cannot be enumerated at install time. Two grants are cluster-wide for other reasons: trust-manager `Bundle`s are a cluster-scoped kind, and `PrometheusRule`s render into a single configurable namespace that the bootstrap chart does not plumb, so the target isn't knowable at install time. It also grants `create` on `serviceaccounts/token` limited to ServiceAccounts named `bao-cert-manager` (Kubernetes escalation rules require a covering grant to create the per-tenant cert-manager token Role; the limit keeps template-operator-v2 from minting tokens for any other ServiceAccount). Three grants are deliberately narrowed or conditional:

- **OpenBao CRs and child TemplateInstances: mutation only in the operator namespace.** These kinds render exclusively into `operatorNamespace`, so a namespaced Role there carries `get`/`list`/`watch`/`create`/`update`/`patch`/`delete` — the Role's `list`/`watch` serve the per-namespace drift watches. The ClusterRole keeps cluster-wide `list` on these kinds (nothing more): template-operator-v2's orphan discovery lists every rendered kind across the cluster on each reconcile and during TemplateInstance deletion, and revoking it wedges teardown. Renaming `operatorNamespace` on an existing install leaves the objects in the old namespace discoverable but no longer deletable by template-operator-v2 — clean up the old namespace by hand. Net-effect caveat for `templateinstances`: template-operator-v2's own manager ClusterRole grants full TI CRUD cluster-wide regardless; this chart's grant is scoped so it stands on its own, but it cannot narrow upstream's.
- **Secrets: `delete` only.** The chart renders no Secret — `bao-ca-bundle` is a ConfigMap, because a CA bundle is a public certificate. No `create`, `update`, or `patch` is granted; cluster-wide Secret write is the largest grant this chart could hand out. The lone `delete` exists so the legacy-Secret upgrade below can converge. (template-operator-v2's own `secret-reader` ClusterRole grants `get`/`list`/`watch` on Secrets independently of this chart.)
- **ESO access only when `parent.eso: enabled`.** The `secretstores`/`externalsecrets` rule is gated on the same switch that decides whether those resources are rendered.

Installs that already run template-operator-v2 with its cluster-admin binding gain nothing new from these grants.

**Upgrading from a release that rendered `bao-ca-bundle` as a Secret.** Only affects installs that set `baoCABundle` — it is empty by default. The new ConfigMap is created normally, but the old Secret is left behind: template-operator-v2 issues the delete, then cannot strip its own finalizer without Secret `update`, so the object sits in `Terminating` and the operator retries in the background. Nothing surfaces on the TemplateInstance — all conditions stay `True`, so this is log-only. Clear it once per workload namespace:

```bash
kubectl -n <workload-ns> patch secret bao-ca-bundle --type=merge \
  -p '{"metadata":{"finalizers":null}}'
```

---

## Deletion policy (safety guardrails)

Deleting an `OpenBao*` CR does not destroy data by default. Two cluster-global
values (in the bootstrap chart, plumbed to every tenant render) set the posture:

```yaml
safety:
  deletionProtection: true        # mounts, auth mounts, bao namespaces → Retain
  grantDeletionProtection: false  # policies, roles, groups, aliases   → Delete
```

| | CR deleted / renamed | Default |
|---|---|---|
| **Data-bearing** (`OpenBaoSecretEngine`, `OpenBaoNamespace`, `OpenBaoAuthMethod`) | `Retain`: the bao object and everything stored under it survives as a logged orphan (+ a `BaoObjectOrphaned` Event). Re-applying an identical CR adopts it. | protected |
| **Grants** (policies, auth/PKI roles, groups, aliases) | `Delete`: removing the CR revokes the access it granted — offboarding a tenant or removing an opt-in annotation closes the login door. | revokes |

Consequences worth knowing:

- **Deleting an MTO Tenant does not destroy its OpenBao data.** The tenant's
  bao namespace, KV data, transit keys and PKI CA are retained; its policies
  and login roles are removed (access is revoked). The data is recoverable by
  re-creating the Tenant (identical CRs adopt the retained objects) — or
  removable by a bao admin.
- **A new Tenant with an old name gets the old tenant's data.** That is the
  recovery path above, and it does not check who the new tenant is. It
  includes the tenant's cross-tenant KV shares, which stay in the shared
  space: what it sent (`from-<tenant>/`) and what other tenants sent to it
  (`from-<peer>/to-<tenant>/`). The new tenant's apps read them when they
  import or export again; with the shared-space SSO login on, its people do
  too. Before giving an old tenant name to other people, delete the old data
  (below).
- **A values edit that moves a mount path keeps the old mount.**
  The rename is treated as retain-and-recreate; the old mount (for PKI: the CA
  and its private key) stays in bao.
- **Flipping `safety.deletionProtection: false` re-arms destructive teardown
  for every tenant at once.** Prefer the per-tenant flow below.

**Decommissioning one tenant's data for real.** The rendered CRs are
drift-protected — the shipped default is `sync.mode: revert`, which reverts a
manual `deletionPolicy` patch within its watch window (and `strict` rejects
the patch outright). Don't fight the sync. Delete the Tenant first, then
remove the retained data as a bao admin:

```bash
kubectl delete tenant <tenant>   # CRs are reaped; the bao namespace and data are retained
# then, with a bao-admin token — this cascades through everything inside:
bao namespace delete <tenant>
```

That does not reach the tenant's cross-tenant KV shares: they live in the
shared space. Delete what it sent and what it received (`dev` is the env):

```bash
t=<tenant>
ls_keys() { # ls_keys <folder>: its keys, one per line; nothing when it has no keys (bao prints {}); other errors are printed
  local out
  if out="$(bao kv list -namespace=shared -mount=kv -format=json "$1" 2>&1)"; then jq -r '.[]' <<<"$out"
  elif [ "$out" != "{}" ]; then echo "ERROR listing $1: $out" >&2; return 1
  fi
}
n=0
purge() { # purge <folder>: every secret below it, with all its versions
  local k
  while IFS= read -r k; do
    case "$k" in
      "") ;;
      */) purge "$1$k" ;;
      *)  bao kv metadata delete -namespace=shared -mount=kv "$1$k" >/dev/null && n=$((n + 1)) ;;
    esac
  done <<<"$(ls_keys "$1")"
}
walk() { # walk <command>: run it on what the tenant sent, and on what each writer sent to it
  local w
  while IFS= read -r w; do
    case "$w" in
      "") ;;
      "from-$t/") "$1" "dev/$w" ;;
      *) "$1" "dev/${w}to-$t/" ;;
    esac
  done <<<"$(ls_keys dev/)"
}
walk purge
echo "deleted $n secrets"   # 0 for a mistyped t= as well — check the name
# check: any line printed after this is left over, or an ERROR
walk ls_keys
```

The shared transit keys of the tenant (`from-<tenant>-to-<peer>-<env>` and
`from-<peer>-to-<tenant>-<env>`) also stay; a transit key can be deleted only
after `deletion_allowed` is set on it.

The `spec.deletionPolicy: Delete` flip on an individual CR is the supported
teardown path only where sync enforcement is off (`sync.mode: off`) or for
CRs you applied by hand, outside t-op-v2.

**Upgrade notes.**

- Before this feature, CR deletion always destroyed the bao object. If you
  relied on that (throwaway clusters, CI), set `safety.deletionProtection:
  false` to restore it. Grant behaviour is unchanged by default.
- **Order matters:** the protection lives in the operator, not the CRD. With
  new CRDs but an old operator image, `kubectl get` shows
  `deletionPolicy: Retain` while the running code ignores it and destroys on
  delete. Upgrade the operator image before or together with the CRDs.

---

## Configuration

- Cluster-wide defaults: [`openbao-config-mto-bootstrap/values.yaml`](openbao-config-mto-bootstrap/values.yaml) (under `parent.*`, `platformPki.*`, and `sync.*` — see [Drift protection](#drift-protection)).
- Per-tenant engine settings: [`openbao-config-mto/values.yaml`](openbao-config-mto/values.yaml) (KV tiers, `transit.*`, `pki.*`, `sso.*`).
- Deletion-policy posture: `safety.*` in both charts — see [Deletion policy](#deletion-policy-safety-guardrails).

Both files have comments on every setting.

---

## Going to production

A few defaults are tuned for trying things out, not for production:

- **Operator credentials.** The operator deployment defaults to Kubernetes auth: the operator logs into OpenBao with its own ServiceAccount and stores no token anywhere. This needs a one-time bootstrap per OpenBao server (auth mount + policy + role) — see the [operator README](https://github.com/stakater-ab/openbao-config-operator#openbao-authentication). Never give the operator the root token; the legacy static-token mode (`BAO_AUTH_METHOD=token` + a `VAULT_TOKEN` env) exists only for local development and migration.
- **Use TLS.** Set `baoServer` to an `https://` address. If OpenBao uses a private CA, also set `baoCABundle`.
- **Token lifetimes.** Workload tokens default to 1h / 4h max (`token.*`); SSO tokens to 15m / 1h (`ssoToken.*`). Shorten high-privilege tiers if your IdP can't revoke tokens.
- **Secret refresh.** `externalSecretRefreshInterval` defaults to `1h`. Lower values mean more frequent OpenBao logins.
- **Key rotation.** Transit keys rotate every 90 days by default (`transit.defaultAutoRotatePeriod`).
- **Network policy.** Turn on `networkPolicy.enabled` to restrict workload traffic to OpenBao and the API server (needs a CNI that enforces NetworkPolicies).
- **Monitoring.** Turn on `monitoring.enabled` to ship alerts for failed resources (needs the Prometheus operator).
- **PKI root of trust.** For production, prefer the shared-trust setup with an offline root. See the bootstrap chart's `platformPki` settings.
