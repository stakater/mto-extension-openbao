# The `bao.stakater.com/app` annotation

Explains one annotation in the per-app layout: the layout gives every app its own
private secret prefix, named after the app's ServiceAccount, and this annotation
lets a team name the prefix themselves instead. For the full behaviour of both
engines — what is reachable, what is denied, and what every misconfiguration
looks like — see [kv-transit-scenarios.md](kv-transit-scenarios.md).

Everything marked *verified* below was rendered with `helm template` and, where
it involves OpenBao behaviour, run against OpenBao 2.5.5 on the dev cluster.

<!-- markdownlint-disable MD013 -->

---

## Background in 30 seconds

OpenBao (a Vault fork) stores secrets at paths, like files in folders:

```text
kv/data/dev/team-a-dev/payments/db-creds
```

An app gets access by being handed a **policy** — a plain list of paths it may
touch:

```hcl
path "kv/data/dev/team-a-dev/payments/*" { capabilities = ["read"] }
```

This operator writes those policies for you. It reads annotations off each
ServiceAccount in a tenant's namespaces and renders one policy per app. So an
annotation value can end up *inside* a policy — which is why the rest of this
doc cares so much about what that value contains.

---

## The problem

The folder name is the ServiceAccount name. In Kubernetes you cannot rename a
ServiceAccount — `metadata.name` is immutable, so a "rename" is really delete +
create. When that happens:

```text
before   kv/data/dev/team-a-dev/app-a/db-creds     ← the app's secrets
after    kv/data/dev/team-a-dev/payments/          ← empty, and the app looks here now
```

The old secrets are still in OpenBao, but nothing grants access to them any
more. The app's transit key name changes too, so old ciphertext stops being
decryptable — though the key itself survives: `OpenBaoTransitKey` is
orphan-by-design, so removing its CR leaves the bao key in place and re-adding
the identity adopts it back.

## The change

One optional annotation on the ServiceAccount:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-sa
  namespace: team-a-dev
  annotations:
    bao.stakater.com/tier: editor
    bao.stakater.com/app: payments      # ← new, optional
```

Set it, and the folder is `payments/` no matter what the ServiceAccount is
called. Omit it, and the folder is `api-sa/` — exactly today's behaviour.

Now the ServiceAccount can be replaced without moving anything:

```text
SA api-sa  → deleted
SA web-api → created, same bao.stakater.com/app: payments
             folder stays kv/data/dev/team-a-dev/payments/
             transit key stays team-a-dev-payments-dev-<hash>
```

### What it does not fix

The full path is `<env>/<ns>/<app>`. The annotation stabilizes **one of three**
segments:

| Segment | Stable? |
|---|---|
| `<env>` | set per install |
| `<ns>` | no — a namespace rename is also delete + create, and breaks the same way |
| `<app>` | yes, once declared |

Editing the annotation later breaks things exactly like renaming the
ServiceAccount did. The annotation is a promise to keep a string stable, not a
mechanism that keeps it stable.

---

## Which engines this touches

| Feature | Affected |
|---|---|
| KV — the app's own folder | **yes**, this is the change |
| Transit — the app's own encryption key | **yes** |
| KV `_shared/from-<ns>/`, cross-tenant shares | no — those are namespace- and tenant-scoped by design |
| Transit namespace / tenant-shared / cross-tenant keys | no |
| PKI certificates | no, and should stay that way — a certificate's identity is a DNS name, which belongs to a Service, not to an app |
| cert-manager Issuers | no — cert-manager authenticates as its own per-namespace ServiceAccount |
| Human (SSO) access | no — a tenant admin can read `kv/data/<env>/*`, so "private to one app" means private from other *workloads*, never from tenant admins |

Rule of thumb: the app name belongs in the **KV path** and the **transit key
name** only. Not in policy names, CR names, or Kubernetes object names — those
carry no data and are safe to recreate under a new name.

---

## Rules the value must follow

The annotation value is written by whoever can edit a ServiceAccount in the
namespace, and it lands unescaped inside a policy. Without validation it is not
a name — it is a policy the tenant writes themselves. All three of these
rendered successfully and were accepted by OpenBao (*verified*):

**1. Breaking out of the path.**

```yaml
bao.stakater.com/tier: viewer
bao.stakater.com/app: 'x/*" { capabilities = ["read"] } path "kv/data/dev/team-a-prod'
```

```hcl
# rendered policy — the template's own trailing /*" closes the injected block
path "kv/data/dev/team-a-dev/x/*" { capabilities = ["read"] } path "kv/data/dev/team-a-prod/*" { capabilities = ["read", "list"] }
```

A `viewer` in `team-a-dev` read a secret in `team-a-prod`. The same trick
injects `capabilities = ["sudo"]`, and reaches any path in the tenant's bao
namespace.

**2. A wildcard instead of a name.**

```yaml
bao.stakater.com/app: "+"     # + matches any single path segment in OpenBao
```

Grants `kv/data/dev/team-a-dev/+/*` — every app in the namespace.

**3. A name that is already taken.**

```yaml
- name: payments      # no annotation, so its folder is payments/
- name: attacker-a
  annotations: { bao.stakater.com/app: payments }   # same folder
```

So the chart must:

- **Validate the value** against `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` with a length
  cap. This closes all three cases above, plus any underscore-prefixed value
  (reserved for chart-owned prefixes such as `_shared`) and values like
  `Payments_v2`, which render a Kubernetes-invalid CR name and fail the tenant's
  dry-run with an opaque error.
- **Check uniqueness on resolved names, per namespace.** Case 3 above passes a
  guard that only compares *declared* annotations — `payments` never declared
  anything. Compare the values every ServiceAccount actually resolves to,
  annotation or not, and name both offenders when they clash.
- **Reject it on the `default` ServiceAccount**, same as the tier annotation
  already does.

---

## Three templates derive app identity, not one

Each one starts from a different object, so missing one is silent rather than
loud (*verified*, by patching only the first):

| Template | Derives from | If it is missed |
|---|---|---|
| `04-sa-own-tenant.yaml` | the ServiceAccount | — |
| `05-deployment-externalsecrets.yaml` | the **Deployment's** `serviceAccountName` | ExternalSecret read `dev/team-a-dev/api-sa/postgres` while the policy granted `dev/team-a-dev/payments/*` → 403, the Secret never syncs |
| `02-transit-scaffolding.yaml` | the ServiceAccount's `metadata.name` | policy and ConfigMap pointed at key `team-a-dev-Payments_v2-dev-1444dc`; the only key created was `team-a-dev-api-sa-dev-dfb03d` |

The second one needs a lookup the chart does not do today: Deployment →
`serviceAccountName` → that ServiceAccount's annotation. It must fail the render
when the ServiceAccount cannot be found, rather than quietly falling back to the
name and producing a path the policy does not grant.

One thing that fails safely: a policy naming a transit key that does not exist
returns permission denied. The chart grants only `update` on
`transit/encrypt/<key>`, and OpenBao auto-creates a missing key only when
`create` is also granted, which no tier is (*verified*).

---

## Two ServiceAccounts, one app

A Deployment and a CronJob are often one app and want one folder:

```yaml
Deployment api          → SA api-sa
CronJob    nightly-bill → SA report-sa      # same app, same DB creds
```

With the uniqueness guard, both declaring `app: payments` fails the render, so
this pattern is not available. Their alternatives are the namespace's
`_shared/from-<ns>/` prefix (visible to every app in the namespace, and to any
sibling namespace that subscribes) or a duplicate copy of the secret.

Without the guard it works — and so does an unrelated `billing-sa` declaring
`app: payments` and reading those secrets, with no error and no signal.

The decision rests on who can do the second thing. Editing an annotation needs
Kubernetes edit rights in the namespace, and anyone holding those can already
read the app's Secret or exec into its pod. A compromised workload — the threat
per-app folders exist to contain — cannot edit annotations at all. So the guard
mainly catches typos, not attackers.

**Decision: keep the guard.** Collisions stay loud, and grouping two
ServiceAccounts under one app is worth its own explicit declaration later rather
than being available to anyone who happens to reuse a string.

---

## Build checklist

1. Resolve `bao.stakater.com/app`, defaulting to the ServiceAccount name.
2. Validate: anchored regex, length cap, not `default`.
3. Uniqueness guard over resolved names per namespace, naming both offenders.
4. Thread it through all three templates in the table above.
5. Keep it out of policy names, role names, CR names and Kubernetes object
   names.
6. Run `include "openbao.assertName"` on the per-app transit key CR name.
7. Verify the rename case: render with `app-a`, replace the ServiceAccount
   keeping the annotation, confirm the KV path and transit key name do not move.
8. Extend `hack/chart-render-tests.sh` and regenerate the golden fixture.
