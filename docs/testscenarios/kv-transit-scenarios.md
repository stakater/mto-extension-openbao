<!-- markdownlint-disable MD013 MD001 -->
# KV and transit — scenario walkthrough

What a workload can and cannot reach after secrets and encryption keys moved from
per-namespace to per-app grain, and what it sees when the annotations are wrong.

Organised by **boundary** rather than by engine, because the question a reader
arrives with is "can X reach Y, and what do I see when it's misconfigured".

## Provenance

Every ALLOW/DENY and every status code below is captured output, not expected
output. Where a scenario was not exercised it says so.

| | |
|---|---|
| Chart | `openbao-config-mto` 0.12.0 |
| OpenBao | 2.5.5 (dev mode, in-memory) |
| Kubernetes | v1.33.5 (OpenShift), operator in `mto-extension-openbao-system` |
| Captured | 2026-08-04 |
| Fixtures | `hack/render-fixtures/values-full.yaml`, `values-guards.yaml`; cluster fixtures in "Reproduce" |

Logins are real: a ServiceAccount token from `kubectl create token`, exchanged at
`auth/kubernetes/login` for a bao token carrying only that ServiceAccount's
policy. Nothing below was probed with a root token except where it says "as root".

## Layout

```text
KV                                                        who
kv/data/<env>/<ns>/<app>/<leaf>                            one app
kv/data/<env>/_shared/from-<ns>/<leaf>                     every tiered app in <ns>, plus subscribers
kv/data/<env>/from-<writer>/to-<reader>/<leaf>             one tenant pair (in the shared/ bao namespace)

Transit                                                    who
<ns>-<app>-<env>-<hash>                                    one app
<ns>-<env>                                                 every transit app in <ns>
<tenant>-shared-<env>                                      every transit app in the tenant
from-<writer>-to-<reader>-<env>                            one tenant pair (in shared/)
```

`<app>` is `bao.stakater.com/app`, defaulting to the ServiceAccount name. The
`<hash>` is `sha256(<ns>/<app>/<env>)` truncated to 6, computed before the parts
are joined — key names are flat strings and every part may contain hyphens, so
`(ns team-a-dev, app app-a)` and `(ns team-a, app dev-app-a)` would otherwise
collide on one key.

Access is opt-in per engine, and a tier says how much:

```yaml
bao.stakater.com/kv:      "true"
bao.stakater.com/transit: "true"
bao.stakater.com/pki:     "true"
bao.stakater.com/tier:    editor        # required alongside any engine
bao.stakater.com/app:     payments      # optional, defaults to the SA name
```

## Cast

Tenant `att`, two workload namespaces. Tenant `att2`, one. All ServiceAccounts
carry `kv: "true"` unless noted.

| ServiceAccount | namespace | tenant | tier | engines | app |
|---|---|---|---|---|---|
| `t-viewer` | demo-provider | att | viewer | kv | `t-viewer` |
| `t-editor` | demo-provider | att | editor | kv, pki | `t-editor` |
| `t-admin` | demo-provider | att | admin | kv, transit | `t-admin` |
| `t-audit` | demo-provider | att | audit-read | kv | `t-audit` |
| `pub` | demo-provider | att | editor | kv, transit | `pub` |
| `sub` | demo-consumer | att | editor | kv | `sub` |
| `peer` | curity-db-demo | att2 | editor | kv, transit | `peer` |
| `app-alpha` | demo-provider | apptest | editor | kv, transit | **`payments`** |
| `app-beta` | demo-provider | apptest | editor | kv, transit | `app-beta` |

`pub` exports to `att2`; `sub` subscribes to `demo-provider`; `peer` imports from
`att`. `app-alpha` is the one case where the app name differs from the
ServiceAccount name.

---

# Using it — the app's view

Before the boundary matrix, what a workload actually does. Everything here is one
app (`ed`, app `payments`, tier `editor`, kv + transit) talking to bao with its own
ServiceAccount token.

### U0 — what the app is handed

The chart renders `bao-config-<sa>` into the app's namespace; the pod consumes it
with `envFrom.configMapRef`. Real contents:

```text
VAULT_ADDR=http://openbao.openbao.svc.cluster.local:8200
VAULT_NAMESPACE=use/
VAULT_K8S_ROLE=use-demo-provider-ed
VAULT_KV_APP=payments
VAULT_KV_APP_PATH=kv/data/dev/demo-provider/payments/
VAULT_KV_APP_META_PATH=kv/metadata/dev/demo-provider/payments/
VAULT_KV_SHARED_OUT_PATH=kv/data/dev/_shared/from-demo-provider/
VAULT_TRANSIT_MOUNT=transit
VAULT_TRANSIT_APP_KEY=demo-provider-payments-dev-507de0
VAULT_TRANSIT_APP_ENCRYPT=transit/encrypt/demo-provider-payments-dev-507de0
VAULT_TRANSIT_APP_DECRYPT=transit/decrypt/demo-provider-payments-dev-507de0
VAULT_TRANSIT_NS_KEY=demo-provider-dev
VAULT_TRANSIT_SHARED_KEY=use-shared-dev
```

The app never hard-codes a path. It appends its leaf to `VAULT_KV_APP_PATH` and
posts to the endpoints named above. Note `VAULT_KV_APP` is the *app* name and the
role is named after the *ServiceAccount* — those differ whenever
`bao.stakater.com/app` is set.

It authenticates by exchanging the ServiceAccount token Kubernetes already mounts
into the pod:

```bash
bao write auth/kubernetes/login \
  role="$VAULT_K8S_ROLE" \
  jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
```

That path is the **automounted** token — present in every pod unless
`automountServiceAccountToken: false`. Since Kubernetes 1.21 it is a projected
token: bound to the pod, rotated automatically, and issued for the API server's
own audience. Nothing has to be added to the pod spec.

The chart deliberately leaves `audience` unset on the rendered
`OpenBaoKubernetesAuthRole`, so bao performs no audience check and the automounted
token is accepted. The tighter alternative — a dedicated projected volume with an
explicit audience and a short expiry — is what the **operator** uses for itself:

```yaml
# the operator's own pod, for contrast; not what a workload needs
volumes:
  - name: bao-sa-token
    projected:
      sources:
        - serviceAccountToken: { audience: openbao, expirationSeconds: 3600, path: token }
# mounted at /var/run/secrets/openbao, and its bao role sets audience=openbao to match
```

**A workload can copy that pattern today.** Measured: a token minted with
`--audience=openbao` logs in successfully against a role that sets no audience —
bao performs no audience check, so both the automounted token and a custom-audience
one are accepted. Using a dedicated audience is therefore a free tightening on the
workload side: an exfiltrated token is useless against any other audience.

What is *not* available is the enforcing direction — making bao **require** that
audience and reject a default token. That needs `audience` on the role, which the
CRD supports (`spec.audience`) but no chart value plumbs through. See Known
limitations.

### U1 — storing a value

```text
Probe      kv put <VAULT_KV_APP_PATH>db user=app pw=v1
Observed   version 1, created_time 2026-08-04T11:28:08Z
```

### U2 — storing again on the same leaf

This is the "save new data to the same leaf" case, and KV v2 does not overwrite:

```text
Probe      kv put <same leaf> user=app pw=v2
Observed   version 2
           latest read            → v2
           read -version=1        → v1        ← the old value is still there
           metadata               → current_version 3, max_versions 0
Why        each write creates a new version. max_versions 0 means "use the mount
           default" (10), so roughly the last ten writes remain retrievable by the
           app itself, and a write is not a destructive act.
```

Consequence worth knowing: **a leaked secret is not gone after you overwrite it.**
Removing old versions needs `destroy`, which only the `admin` tier has.

### U3 — partial update, atomically

`editor` and `admin` hold `patch`, so the merge-patch endpoint works and only the
named keys change:

```text
editor caps    create, list, patch, read, update

Probe      kv patch -method=patch <leaf> pw=v2      (the atomic HTTP PATCH endpoint)
Observed   version 4
           pw   = v2      (patched)
           user = app     (untouched key preserved)
```

`patch` is granted only to tiers that already hold `update`, so it widens nothing.
Verified at the three boundaries it must not cross:

```text
viewer patches its own prefix                       → Code: 403  (caps: list, read)
editor patches ANOTHER app's prefix                 → Code: 403
viewer patches the producer's _shared prefix        → Code: 403  (read-only invariant intact)
```

Without `patch` — the state before chart 0.12.0 — the endpoint returned 403 and
clients silently fell back to read-modify-write, which is not atomic and loses one
of two concurrent updates. If you see that 403, the tier's `tierCaps` entry is
missing `patch`.

### U4 — safe concurrent updates: check-and-set

`patch` makes a single partial update atomic, but not a read-then-decide-then-write
sequence. For that an app has `update` on its own metadata path and can require
check-and-set itself:

```text
kv metadata put -cas-required=true <leaf>   → Success        (app can set this itself)
kv put <leaf> v=1                           → Code: 400      blind write now refused
kv put -cas=0 <leaf> v=1                    → version 1      expected-version write
kv put -cas=0 <leaf> v=2                    → Code: 400      stale writer rejected
```

That is optimistic concurrency: a writer states the version it believes is current,
and loses the race rather than clobbering. Recommended for any leaf two replicas
may write.

### U5 — nested leaves

```text
Probe      kv put <VAULT_KV_APP_PATH>sub/deep/leaf k=v ; read it back
Observed   version 1 ; reads back "v"
Why        the grant ends in /*, and * spans "/" — an app owns its whole subtree
```

### U6 — missing versus forbidden

```text
Probe      read a leaf that does not exist inside its OWN prefix
Observed   "No value found" (404)

Probe      read a leaf in ANOTHER app's prefix
Observed   Code: 403 permission denied
```

The two are distinguishable, which is what you want when debugging — and also
means the error code reveals whether a prefix is yours, not whether data exists in
someone else's.

### U7 — encrypt, store, decrypt

Transit never stores anything; the app keeps the ciphertext itself, usually in its
own database.

```text
encrypt  POST <VAULT_TRANSIT_APP_ENCRYPT>  plaintext=<base64>   → vault:v1:H7be0NIly...
store    the app writes that string wherever it likes
decrypt  POST <VAULT_TRANSIT_APP_DECRYPT>  ciphertext=vault:v1:… → <base64 plaintext>
```

### U8 — the same plaintext encrypts differently every time

```text
Probe      encrypt "hi" twice under the same key
Observed   two different ciphertexts
Why        a fresh nonce per call. Ciphertext is therefore useless as a lookup key
           or an equality check — you cannot search by encrypted value.
```

### U9 — rotation, and what happens to data already encrypted

```text
rotate     admin only, and only on the app's OWN key:
             admin app → another app's key   → Code: 403
             admin app → its own key         → latest_version 1 → 2
             editor app → its own key        → Code: 403
after      new encrypts are stamped vault:v2
           ciphertext written before the rotation STILL decrypts
```

Rotation is not a migration. It changes what *new* writes use; existing ciphertext
keeps its old version stamp and keeps working. The full lifecycle, measured
end to end on a scratch mount (key operations are platform-side, so this part used
the root token; the permission checks above used real app tokens):

```text
1  key created                          latest_version = 1
2  app encrypts "hello-world"           vault:v1:NKVvqac9IFmq...
3  platform rotates                     latest_version = 2
4  a NEW encrypt uses v2                vault:v2:Bs0zx/esYBhc...
   the old record is untouched          vault:v1:NKVvqac9IFmq...   ← still v1
5  old v1 record still decrypts         "hello-world"
6  REWRAP the old record
     before  vault:v1:NKVvqac9IFmq...
     after   vault:v2:FHG/Hzc0QHPS...   ← same data, now stamped v2
     decrypts to                        "hello-world"
```

Rewrap takes ciphertext in and gives ciphertext back. The caller never handles the
plaintext, so a rewrap campaign needs no access to the data itself.

**Why it matters** — rewrap is what makes retiring an old key version survivable.
Continuing the same key to v3, with two old records, one rewrapped and one
forgotten:

```text
7  key at v3        forgotten record = v2     rewrapped record = v3
8  platform retires everything below v3:  min_decryption_version = 3
9  forgotten record → Code: 400  "ciphertext version is disallowed"
   rewrapped record → "hello-world"
```

The forgotten record is **permanently unreadable**. There is no undo: the key
material for v2 is gone. So the order is fixed — **rewrap everything first, then
advance `min_decryption_version`.** Doing it the other way round destroys data.

The chart sets `autoRotatePeriod` (90 days) but never sets
`minDecryptionVersion`, and nothing rewraps automatically, so today rotation
accumulates versions and retires nothing — see Known limitations.

### U10 — which key to use

```text
VAULT_TRANSIT_APP_KEY      default. Nothing else can decrypt it.
VAULT_TRANSIT_NS_KEY       when another app in the same namespace must decrypt.
VAULT_TRANSIT_SHARED_KEY   when any app in the tenant must decrypt.
```

Encrypting under a wider key than needed is the transit equivalent of writing a
secret into `_shared/`: it works, and it hands the plaintext to everyone holding
that key.

---

# Positive — what is reachable

### S1 — an app reads and writes its own prefix

```text
Boundary   app
Probe      alpha writes, then reads, kv/data/dev/demo-provider/payments/db
Expect     allowed
Observed   OK — version 1
Why        its policy grants kv/{data,metadata}/dev/demo-provider/payments/* at its tier
```

Note the prefix is `payments/`, not `app-alpha/`: the path follows
`bao.stakater.com/app`, while the policy, role, ConfigMap and SecretStore are all
named after the ServiceAccount.

### S2 — an app lists its own prefix

```text
Probe      alpha lists kv/dev/demo-provider/payments
Observed   OK — returns "db"
Why        OpenBao normalises LIST with a trailing slash, so metadata/.../<app>/* covers it
```

### S3 — namespace-mates share deliberately via `_shared/`

```text
Boundary   namespace
Probe      pub writes kv/dev/_shared/from-demo-provider/cfg; beta reads it
Observed   write OK, read OK
Why        every tiered app in <ns> gets read on _shared/from-<ns>/*, editor and admin get write
```

This is the sanctioned way for two apps in one namespace to share. It is *not*
namespace-private: any sibling namespace that subscribes can read it too (S5).

### S4 — transit, an app's own key round-trips

```text
Boundary   app
Probe      alpha encrypts under demo-provider-payments-dev-507de0, then decrypts
Observed   vault:v1:yJnVol1o... → dG9wLXNlY3JldA==  ("top-secret")
```

### S5 — a sibling namespace reads a subscribed prefix

```text
Boundary   namespace → namespace, same tenant
Setup      sub in demo-consumer has kv-subscribe-ns: demo-provider
Probe      sub reads and lists kv/dev/_shared/from-demo-provider/cfg
Observed   read OK, list OK
```

### S6 — namespace-shared transit key is usable by both sides

```text
Probe      alpha encrypts under demo-provider-dev; beta decrypts
Observed   OK — round-trips
Why        every transit app in <ns> is granted the namespace key
```

### S7 — cross-tenant KV lane, writer writes and reader reads

```text
Boundary   tenant → tenant (shared/ bao namespace)
Setup      pub has kv-export-tenant: att2; peer has kv-import-tenant: att
Probe      pub (role share-att-demo-provider-pub-out-att2)  writes kv/dev/from-att/to-att2/handoff
           peer (role share-att2-curity-db-demo-peer-in-att) reads it
Observed   write OK, read OK
```

### S8 — cross-tenant transit lane

```text
Probe      pub  (role share-transit-att-demo-provider-pub-out-att2) encrypts under from-att-to-att2-dev
           peer (role share-transit-att2-curity-db-demo-peer-in-att) decrypts
Observed   encrypt OK → decrypt Y3Jvc3MtdGVuYW50LXBheWxvYWQ=  ("cross-tenant-payload")
```

The KV share and the transit share are **separate roles**. A token from one is
denied the other's operations — see S22.

### S9 — PKI, an app issues for its own namespace domain

```text
Boundary   DNS name
Probe      t-editor issues pki/issue/att-svc common_name=api.demo-provider.svc.cluster.local
Observed   OK — serial 6b:42:c1:c0:6e:e1:57:86:1a:78:3d:cc:ea:31:24:ca:a9:51:a1:5c
```

### S10 — PKI, a pki-enabled app reads the CA

```text
Probe      t-editor reads pki/cert/ca
Observed   OK — -----BEGIN CERTIFICATE-----
Why        every pki-enabled SA gets ca/pem, ca_chain and cert/ca so it can validate chains
```

---

# Negative — what is denied

Every case below is a real 403 from OpenBao unless a different code is shown.

### S11 — sibling app in the same namespace cannot read

```text
Boundary   app
Probe      beta reads kv/data/dev/demo-provider/payments/db
Observed   Code: 403 permission denied
Why        beta's policy names .../app-beta/* only; the path segment IS the boundary
```

### S12 — sibling app cannot overwrite either

```text
Probe      beta writes kv/dev/demo-provider/payments/db
Observed   Code: 403 permission denied
```

### S13 — the denial is symmetric

```text
Probe      alpha reads kv/dev/demo-provider/app-beta/db
Observed   Code: 403 permission denied
```

### S14 — an app cannot enumerate its siblings

```text
Probe      beta lists kv/dev/demo-provider           (the namespace root)
Observed   Code: 403 permission denied
Why        no grant on the namespace prefix itself — an app cannot discover what else lives there
```

Verified pairwise across eight apps in one namespace: every app read its own
prefix and was denied all seven others.

### S15 — cross-tier reads are denied in every direction

```text
Probe      viewer→admin, editor→viewer, admin→editor, audit→editor
Observed   Code: 403 in all four
Why        the tier controls how much on your OWN prefix; it never widens which prefix
```

An `admin` app is not privileged over its namespace — only over its own data.

### S16 — a subscriber cannot write the producer's prefix

```text
Boundary   namespace → namespace
Probe      sub writes kv/dev/_shared/from-demo-provider/cfg
Observed   Code: 403 permission denied
```

### S17 — a subscriber cannot touch the producer's metadata

```text
Probe      sub deletes metadata for .../from-demo-provider/cfg
           sub sets max_versions=1 on the same path
Observed   Code: 403 on both
Why        in KV v2 metadata is not a read-only view — update sets max_versions and
           delete_version_after, delete removes every version. A subscriber carrying
           its own tier caps here could destroy data it should only read.
```

### S18 — a subscriber cannot reach the producer's private app prefixes

```text
Probe      sub reads kv/dev/demo-provider/pub/... and .../t-admin/...
Observed   Code: 403 on both
Why        subscribing grants _shared/from-<ns>/ only, never the app prefixes
```

### S19 — subscription is one-way

```text
Probe      pub reads kv/dev/_shared/from-demo-consumer/mine
Observed   Code: 403 permission denied
Why        sub subscribed to demo-provider; nothing granted the reverse
```

### S20 — the cross-tenant reader cannot write the lane

```text
Probe      peer writes kv/dev/from-att/to-att2/handoff
           peer deletes its metadata
Observed   Code: 403 on both
```

### S21 — other tenant pairs and the reverse lane are unreachable

```text
Probe      peer reads kv/dev/from-pe/to-att2/...      (a lane it is not party to)
           pub  writes kv/dev/from-att/to-pe/...      (a peer it did not export to)
           pub  reads  kv/dev/from-att2/to-att/...    (the reverse lane)
Observed   Code: 403 on all three
```

### S22 — the KV and transit share roles are not interchangeable

```text
Probe      KV-share token       → transit/encrypt/from-att-to-att2-dev
           transit-share token  → kv/dev/from-att/to-att2/x
Observed   Code: 403 on both
Why        each share flavour renders its own policy and role; one identity does not
           carry the other's grants. Worth knowing before writing a test.
```

### S23 — transit, an app cannot use another app's key

```text
Probe      beta decrypts alpha's ciphertext under demo-provider-payments-dev-507de0
           beta encrypts under the same key
Observed   Code: 403 on both
```

### S24 — the cross-tenant reader cannot encrypt, only decrypt

```text
Probe      peer encrypts under from-att-to-att2-dev
Observed   Code: 403 permission denied
Why        the reader side is granted decrypt and rewrap; encrypt belongs to the writer
```

### S25 — editor cannot manage key material

```text
Probe      editor rotates demo-provider-payments-dev-507de0; editor reads the key
Observed   Code: 403 on both
Why        rotate, datakey, sign, verify and key reads are admin-only
```

### S26 — `viewer` and `audit-read` get no transit at all

```text
Setup      transit: "true" with tier viewer
Observed   render rejected — see M4; transit.tierCaps.viewer is '[]'
Why        transit is a write operation, so a read-only tier grants nothing.
           This is reported rather than rendered as a no-op.
```

### S27 — audit-read cannot read secret data

```text
Probe      t-audit lists kv/dev/demo-provider/t-audit    → OK
           t-audit reads a secret at that prefix         → Code: 403
           t-audit writes                                → Code: 403
Why        audit-read is metadata enumeration for compliance probes, not data access.
           On a workload it can only enumerate its own prefix, which is close to useless
           — see "Known limitations".
```

### S28 — PKI, the role refuses a domain outside the tenant

```text
Probe      t-editor issues common_name=evil.curity-db-demo.svc.cluster.local   (another tenant)
           t-editor issues common_name=evil.example.com
Observed   Code: 400 — "common name ... not allowed by this role"
Why        a role-level constraint, not a policy one: allowedDomains is checked at issuance
```

### S29 — PKI, an app without the opt-in cannot issue

```text
Probe      t-viewer (no pki annotation) issues pki/issue/att-svc
Observed   Code: 403 permission denied
```

### S30 — PKI, editor cannot manage the role

```text
Probe      t-editor reads pki/roles/att-svc
Observed   Code: 403 permission denied
Why        role reads are admin-only
```

### S31 — an SSO tier reaches every app's secrets

```text
Boundary   human vs workload
Setup      alpha wrote kv/dev/demo-provider/alpha/private (its own prefix only)
Probe      a token carrying policy sso-fin-admin reads that path, then overwrites it
Observed   read "alpha-only" ; write version 2
           policy grants path "kv/data/dev/*" and "kv/metadata/dev/*" tenant-wide
Probe      peer app beta reads the same path
Observed   Code: 403 permission denied
Why        "private to one app" means private from other WORKLOADS. A tenant admin
           holding an SSO tier reads and writes every app's prefix by design.
           (The human token was root-issued carrying that policy, since an OIDC
           login needs a live IdP; the policy content and its effect are what is
           verified here, not the login path.)
```

### S32 — a ServiceAccount cannot borrow another's role

```text
Boundary   identity
Probe      alpha's token + role fin-demo-provider-alpha   (control)
Observed   s.zNbNPM…  — logs in
Probe      beta's token  + role fin-demo-provider-alpha   (the attack)
Observed   Code: 403
Probe      beta's token  + role fin-demo-provider-beta    (control)
Observed   s.Wm82Qn…  — logs in
Why        the role name is not a credential. It sits in a ConfigMap any pod in the
           namespace can read; what authorises is targetServiceAccounts /
           targetNamespaces checked against the token bao just reviewed.
```

---

# Tier matrix

Captured per tier against its own prefix.

| | KV read | KV write | KV patch | KV list | metadata delete | destroy version | transit |
|---|---|---|---|---|---|---|---|
| `audit-read` | **denied** | denied | denied | OK | — | — | none |
| `viewer` | OK | denied | **denied** | OK | denied | — | none |
| `editor` | OK | OK | OK | OK | **denied** | — | encrypt / decrypt / rewrap |
| `admin` | OK | OK | OK | OK | OK | OK | + rotate, datakey, sign, verify, key read |

Underlying values: `tierCaps` and `transit.tierCaps` in
`charts/openbao-config-mto/values.yaml`. `viewer` and `audit-read` have `'[]'`
transit caps, which is why S26 is a rejection rather than a silent no-op.

---

# Misconfiguration — what the user sees

A mistake attributable to one object renders `bao-config-<sa>.error` (or
`bao-config-<name>.deploy-error`) into **that object's namespace** and nothing
else for it. The render does not fail: one TemplateInstance renders every
namespace a tenant owns, so `fail` would produce zero objects for the whole
tenant and freeze every unrelated namespace. `fail` is kept only for problems
that cannot be blamed on one object — unknown `component`, tenant name over the
label budget, invalid chart values, `defaultCapability` still set.

Because no `bao-config-<sa>` is rendered, the pod also fails to start on the
missing `configMapRef`, and the error ConfigMap beside it says why.

| | Input | Message |
|---|---|---|
| M1 | `tier` set, no engine | `tier is set to "editor" but no engine is enabled, so nothing is granted. Add …/kv, …/transit or …/pki set to "true"` |
| M2 | engine set, no `tier` | `an engine is enabled but …/tier is not set, so no capabilities can be granted. Set a tier: admin, audit-read, editor, viewer` |
| M3 | `tier: editorr` | `tier "editorr" is not a known tier. Valid tiers: admin, audit-read, editor, viewer` |
| M4 | `transit` + `viewer` | `transit is enabled but tier "viewer" grants no transit capabilities (transit needs write access; use editor or admin)` |
| M5 | `app: 'x/*" { capabilities = ["sudo"] } …'` | `app "…" is not a valid app name — it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ …` |
| M6 | `app: "+"` | same — `+` is OpenBao's single-segment wildcard and would match every app in the namespace |
| M7 | `app: _shared` | same — underscore-prefixed names are reserved for chart-owned prefixes |
| M8 | two SAs resolving to one app | `app "t-editor" in namespace … is claimed by more than one ServiceAccount (t-audit, t-editor) …` — **reported on both**, see Known limitations |
| M9 | `kv-export-tenant` with `kv` off | `…/kv-export-tenant is set but …/kv is not "true", so it grants nothing` |
| M10 | annotations on the `default` SA | `the default ServiceAccount cannot be granted OpenBao access: every pod that omits serviceAccountName runs as default …` |
| M11 | `kv-subscribe-ns: nowhere-ns` | `references namespace "nowhere-ns", which is not a namespace of tenant "att" (tenant owns: …)` |
| M12 | `subscribe-to-ns` (the pre-rename key) | `unknown annotation "…/subscribe-to-ns" — this chart reads none of that name, so it has no effect. Valid keys: …` |
| M13 | `transit: "ture"` | `…/transit must be "true" or "false", got "ture"` |
| M14 | `app` on a **Deployment** | `…/app is read on the ServiceAccount, not on a Deployment — move it to ServiceAccount "api-sa". On a Deployment it has no effect` |
| M15 | annotated Deployment, no `serviceAccountName` | `requires spec.template.spec.serviceAccountName to be set: OpenBao authenticates the workload's ServiceAccount …` |
| M16 | `kv-secret.<x>` whose SA does not exist | `names ServiceAccount "nope-sa", which does not exist in namespace … — no SecretStore is rendered for it` |
| M17 | `kv-secret.<x>` whose SA has `kv` off | `needs KV access, but ServiceAccount "notkv-sa" does not set …/kv: "true"` |
| M18 | two Deployments, same Secret name, different values | `Deployments api, api2 all render ExternalSecret "api-sa-db-creds" … but ask for different secrets … Rename the annotation suffix on all but one` |
| M19 | `secrets.db` (typo in the key) | `unknown annotation "…/secrets.db" — a Deployment accepts only …/kv-secret.<name>, …/kv-subscribe.<name> and …/kv-import.<name>` |
| M21 | `app` set with no engine enabled | `…/app is set but no engine is enabled, so no app identity is registered — it only names the prefix a …/kv or …/transit grant would use` |
| M22 | `kv-subscribe.<x>: <other-ns>/…` whose SA lacks `kv-subscribe-ns: <other-ns>` | `reads namespace "team-a-dev", but ServiceAccount "sub-missing" does not list it in …/kv-subscribe-ns — the policy read grant it needs is never rendered, so this ExternalSecret would fail to sync indefinitely` |
| M23 | `kv-import.<x>` naming a tenant outside `knownTenants` | `imports from tenant "team-bb", which is not in the tenant roster — nothing is rendered for it. If that tenant does not exist yet this resolves itself once it does; if it should exist already, check the spelling` |
| M24 | a Deployment asking for a secret while `eso: disabled` | `requested but External Secrets Operator is disabled for this whole install (eso=disabled) … Either ask the platform to enable ESO, or read the secret from OpenBao directly` |

Two things M12 and M13 exist to catch that the others cannot: an unrecognised
**key** is silently ignored by a chart that only looks up the keys it expects, and
a misspelled **boolean** leaves its engine off while the mutual-requirement checks
stay quiet because another engine is legitimately on.

### M20 — identical asks are deduped, not rejected

```text
Setup      two Deployments, one ServiceAccount, same secret.<name> and same value
Observed   ONE ExternalSecret rendered, no error
Why        a service and its migration job asking for the same secret is normal.
           Only differing asks under one name are rejected (M18).
```

### Blast radius

```text
Setup      broken SA in team-a-dev, correct SA in team-a-prod, one tenant
Observed   team-a-dev: bao-config-<sa>.error only, and zero bao objects for it
           team-a-prod: full object set, working throughout
```

---

# Lifecycle

### L1 — changing a tier is an in-place patch

```text
Change     tier: editor → admin
Observed   rendered object names IDENTICAL; only the two OpenBaoPolicy bodies "configured";
           nothing created, nothing deleted, no orphan policy left behind.
           A token minted BEFORE the change went create,list,read,update →
           create,delete,list,read,update and could delete — no re-login, no pod restart.
Why        the tier is deliberately not part of the role name. With it there, a tier edit
           is a rename, and a rename is delete-then-create: deleting a bao policy strips
           live tokens instantly, and the pod's cached VAULT_K8S_ROLE then names a role
           that no longer exists, so it cannot log in again until it restarts.
```

### L2 — adding an engine is additive

```text
Change     t-editor gains transit (had kv + pki)
Observed   one new key CR; policy and ConfigMap updated in place; pre-existing KV data
           still readable; PKI still usable
```

### L3 — removing an engine

```text
Change     t-admin loses transit (keeps kv)
Observed   its key CR pruned; KV keeps working; transit encrypt now 403;
           the key itself stays in bao (orphan by design)
```

### L4 — changing `app`, and recovering

```text
Change     app: payments → billing
Observed   old KV data still in bao but the app gets 403 on it
           old transit key survives its CR being deleted — the CR deletes cleanly, no wedge
           the app can no longer decrypt ciphertext written under the old key

Revert     app: billing → payments
Observed   old KV data readable again; old ciphertext decrypts again
Why        OpenBaoTransitKey is orphan-by-design (IsDeletable false), so removing the CR
           leaves the bao key alone, and re-adding the identity makes BaoWrite ADOPT the
           existing key rather than create new material. A genuinely new key returns
           400 invalid-ciphertext, which is how adoption was distinguished from recreation.
```

Treat `<ns>` and `<app>` as permanent. The annotation exists so that the
ServiceAccount *name* is not one of those permanent values — replacing a
ServiceAccount while keeping the annotation moves nothing.

### L5 — full revocation

```text
Change     every bao annotation removed from t-viewer
Observed   policy and auth role deleted; the SA can no longer LOG IN at all
           (Code: 400, invalid role). Peers unaffected.
Why        revocation is real: the identity is gone, not merely unprivileged
```

### L6 — renders are idempotent

```text
Observed   re-applying the same render: 35/35 objects unchanged
```

### L7 — rollback

```text
KV         safe. A namespace-grain policy path "kv/data/<env>/<ns>/*" reads app-grain
           data, because * spans "/". Verified against bao.
Transit    lossy, measured against a token carrying the OLD chart's policy shape
           (namespace + tenant keys only):
             decrypt app-key ciphertext post-rollback   → Code: 403
             the rescue — re-encrypt or rewrap onto the namespace key BEFORE
             rolling back, while both keys are still granted:
             same data read post-rollback               → "pre-rollback-data"
           The platform cannot do the rescue for you; it never holds the ciphertext.
```

### L8 — apply and teardown ordering

```text
Observed   applying a whole render at once gives transient "Code: 404 namespace not found"
           on the auth method, auth config and roles — the bao namespace does not exist
           yet. Everything converges ~30s later on retry. Teardown produces the mirror
           image. Read status twice before diagnosing.
```

---

# Scale

```text
Setup      8 apps in one namespace, all kv + transit + editor
Observed   39 objects, all Ready; 8 policies, 8 roles, 10 transit keys
           (8 per-app + 1 namespace + 1 tenant shared); pairwise isolation verified

Render-only, 50 namespaces x 5 apps, every app opting into transit:
           1559 objects, 1.8 MB, 0.35s
           301 OpenBaoTransitKey, 250 each of Policy / KubernetesAuthRole /
           SecretStore / ExternalSecret / ConfigMap
```

Two limits that follow from those numbers, neither hit in this test: 809 `OpenBao*`
CRs on the 5-minute reconcile interval is roughly 2.7 bao API calls per second for
a single tenant; and 1.8 MB lands in one TemplateInstance, whose
`status.renderedResources` lists every object, against an etcd object ceiling near
1.5 MB.

# Edge inputs

```text
serviceAccounts: null, deployments: null    scaffolding only, no crash
a bare `tenant:` and nothing else            scaffolding only
eso slice with zero Deployments              zero objects
app name of 63 characters                    accepted
app name of 64 characters                    rejected (M5 family)
```

---

# Known limitations

**The uniqueness guard reports on both sides (M8).** When one ServiceAccount
claims another's app name, both lose their policy — so an app can be revoked
because a colleague edited a different ServiceAccount. A render-time guard cannot
avoid this: the chart is declarative and template-operator-v2 prunes whatever is
not rendered, so on a collision its only options are render for neither (today),
render for both (duplicate path, isolation gone), or pick a winner by a rule that
can be gamed. The only fix that protects the innocent side is admission-time
rejection of the annotation write. Tracked separately.

**PKI grain is per tenant, not per namespace, and this change does not alter
that.** `allowed_domains` on the single `{tenant}-svc` role is the union across
the tenant's namespaces, so a `demo-provider` app **did** successfully issue for
`api.demo-consumer.svc.cluster.local`. Confirmed still open (F16). Per-app is the
wrong axis for a fix — a certificate's identity is a DNS name, which belongs to a
Service, not an app.

**The chart never sets `audience` on a workload's auth role**, so bao cannot
*require* a particular audience. The field exists on the CRD
(`OpenBaoKubernetesAuthRole.spec.audience`) and the operator uses it for its own
role, but no chart value plumbs it through. Consequence: a workload may present an
audience-bound token if it wants to (measured — it is accepted), but bao will
equally accept the default API-server-audience token, so the binding cannot be
enforced platform-side. A values knob would close it.

**An off-roster peer is now reported on the consuming Deployment (M23) but is
still silent on the ServiceAccount side.** `kv-export-tenant: team-bb` renders no
share Policy or Role and says nothing, because those templates skip the peer
before any error channel exists for them. The Deployment-side `kv-import.<name>`
path does report it. Closing the ServiceAccount side means giving
`04-sa-share-*.yaml` and `04-sa-transit-share-*.yaml` the same error-ConfigMap
treatment.

**ExternalSecrets keep serving stale data when a path stops resolving.** The chart
sets no `deletionPolicy`, so it defaults to `Retain`: the ExternalSecret goes
`SecretSyncedError` / `Ready=False` with a `Warning UpdateFailed` event, and the
Kubernetes Secret is kept with its last-synced values. Pods carry on with the old
secret. Alert on `ExternalSecret Ready=False` — nothing in the workload will say
so. (Measured with a fake provider; ESO cannot reach bao on this cluster.)

**Rotation retires nothing.** `autoRotatePeriod` is 90 days, but
`minDecryptionVersion` is exposed on the CRD and never set by the chart, and
nothing calls rewrap. So rotation changes only what new writes use; every old
version stays decryptable indefinitely (U9). Rotation is not currently a security
control.

**`audit-read` on a workload is close to useless.** It can list its own prefix and
read nothing (S27). It remains meaningful for the SSO tiers, which hold
`kv/metadata/<env>/*` tenant-wide.

**A render failure emits no Event.** Measured by forcing one: a TemplateInstance
whose tenant name exceeds the label budget renders nothing and reports

```text
Rendered  False  TemplateExecutionFailed
   helm template render failed ... execution error at
   (openbao-config-mto/templates/11-pki-cross-tenant-trust.yaml:29:64):
   tenant name "xxx…" (50 chars) makes TemplateInstance name ...
Ready     False  TemplateExecutionFailed
```

Zero Events were produced — checked both by field-selector on the object and
across all Events cluster-wide. So the condition message is the only signal, and
it is a good one *if someone is looking at the TemplateInstance*. Whether
template-operator-v2 also exports a metric is **undetermined**: its metrics
endpoint returned an empty body to my scrape and the ServiceAccount is not
authorised for `/metrics` (`kubectl auth can-i get /metrics` → no), so the empty
result is an RBAC artefact rather than evidence of absence. The error-ConfigMap
mechanism exists partly to keep mistakes out of that path.

# Not covered here

- **The OIDC login path.** The SSO *policies* and their reach are measured (S31),
  but no login was performed through a real IdP: the rendered
  `OpenBaoJWTOIDCAuthEngineConfig` needs a client-secret Secret the platform
  provisions, and without it that one object stays `Ready=False`
  (`InternalError: Secret "bao-oidc-client-secret" not found`). Everything else in
  the SSO slice reconciled.
- **The ESO sync path end to end.** ESO on this cluster cannot reach bao
  (`InvalidProviderConfig`, a NetworkPolicy gap), so ExternalSecret objects were
  verified as rendered and deduped, but never observed syncing a value.
- **cert-manager Issuer injection.** Rendered and slice-tested, not exercised
  against a real `Certificate`.

# Reproduce

Render for a throwaway tenant with `operatorNamespace` pointing at the live
operator, and put the workload ServiceAccounts in an existing tenant-labelled
namespace:

```bash
helm template att charts/openbao-config-mto \
  -n mto-extension-openbao-system \
  -f <fixture>.yaml --set component=core > render.yaml
kubectl apply -f render.yaml
```

Create the cluster ServiceAccounts **without** bao annotations. The annotations
only drive the render, and leaving them off keeps a live TemplateInstance in that
namespace from picking the accounts up.

Log in as a workload:

```bash
JWT=$(kubectl -n demo-provider create token app-alpha --duration=3600s)
# inside the bao pod, with BAO_NAMESPACE=<tenant> (or shared for cross-tenant roles)
bao write -field=token auth/kubernetes/login role=att-demo-provider-app-alpha jwt="$JWT"
```

Assert that the login actually returned a token before using it:

```bash
t=$(BAO_TOKEN=invalid bao write -field=token auth/kubernetes/login role=... jwt=...)
case "$t" in s.*) ;; *) echo "login failed"; exit 1 ;; esac
```

Dev-mode bao leaves the root token in `~/.vault-token` inside the pod, so an unset
or empty `BAO_TOKEN` silently falls back to **root**. A probe whose login 404'd
then reports `capabilities: root` and every assertion passes for the wrong reason.
This cost a full round of invalid results while writing U3.

Two further environment quirks: piping a script into `kubectl exec -i ... -- sh`
silently produces nothing when the script contains heredocs — base64-encode it and
decode inside the pod instead. And bao here runs in dev mode with in-memory
storage, so restarting `openbao-0` wipes every tenant's config *and* the operator's
own auth mount.

Wait for the auth mount and roles to report `Ready=True` before logging in; the
`OpenBaoAuthMethod` lands after the namespace, so an early login 404s with
`no handler for route "auth/kubernetes/login"`.

Cleanup is leaf CRs first, then the `OpenBaoNamespace` CR: deleting that cascades
the entire bao namespace, including every mount, secret and key.

The render-level equivalents of the M-series live in
`hack/render-fixtures/values-guards.yaml` and are asserted by
`hack/chart-render-tests.sh` (`guards`, `esdedupe`, `appgrain`, `rolename`,
`transitmatch`), so they run without a cluster.
