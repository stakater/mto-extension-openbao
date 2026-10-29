# E2E cluster assets

What `make e2e-up` puts on a kind cluster, and why each piece is there. The
bootstrap chart under test is deliberately NOT on this list: the suite installs
and uninstalls it itself during `make e2e-test`, so every run starts from the
customer's starting point.

| Component | How | Why |
|---|---|---|
| kind cluster | [kind-config.yaml](kind-config.yaml) | Kubernetes 1.33 — template-operator-v2's CRDs carry a CEL rule 1.31 cannot compile; the OpenBao chart needs ≥ 1.30 |
| cert-manager | upstream manifest, pinned | template-operator-v2 issues its webhook certificate through it; the `.certmanager` slice renders `Issuer`s and the suite issues a `Certificate` through one |
| trust-manager | its Helm chart, `app.trust.namespace` = the operator namespace | the `.trust` slice renders `Bundle`s whose sources are ConfigMaps in the operator namespace — trust-manager only reads sources from its trust namespace |
| External Secrets Operator | its Helm chart | the `.eso` slice renders `SecretStore`/`ExternalSecret`; ESO logging into bao as the workload's ServiceAccount is the first proof that the rendered kubernetes-auth role works |
| OpenBao | its Helm chart, **dev mode** | the thing every `OpenBao*` CR is reconciled into. Dev mode is in-memory with root token `root`; restarting the pod wipes it, which is fine for a run and fatal for anything else |
| MTO `Tenant` CRD | [crds/](crds/) | the parent Template's input. Only the CRD — see below |
| template-operator-v2 | its public Helm chart, release name `template-operator-v2` | the renderer. The release name is forced — see below — so the controller's ServiceAccount is `template-operator-v2`, not the bootstrap chart's default; the suite passes `templateOperator.*` explicitly |
| openbao-config-operator | its Helm chart at `OPERATOR_CHART_VERSION` (private; or `OPERATOR_SRC=` to build from a checkout) | the reconciler. Same version pin as `make crd-validate`, so the CRDs validated against and the operator run against are one release |
| operator bao identity | [bootstrap-operator-auth.sh](bootstrap-operator-auth.sh) + [operator-policy.hcl](operator-policy.hcl) | the operator holds no stored credential; this is its documented one-time bootstrap, done with the `bao` CLI inside the OpenBao pod |
| chart repository | [chart-repo.yaml](chart-repo.yaml) + [chart-repo-publish.sh](chart-repo-publish.sh) | template-operator-v2 pulls the tenant chart at render time; this serves **this checkout's** chart over plain HTTP so the suite tests the working tree, not the last release |

## multi-tenant-operator itself is deliberately NOT installed

Only its `Tenant` CRD is. Three reasons, in order of weight:

1. **The charts never need MTO to run.** The parent reads `Tenant` objects
   through template-operator-v2's `objectFieldRef`, and the children find a
   tenant's namespaces through the `stakater.com/tenant` label. Whether a
   controller reconciles the Tenant is irrelevant to every assertion in the
   suite; what matters is that the label is there, and the suite puts it there
   — which is exactly what MTO would do.
2. **MTO's webhooks would take capability away.** Its namespace webhook refuses
   any namespace without a tenant label, and the free tier caps a cluster at two
   Tenants. On this cluster the suite owns three tenants and can model the
   window MTO itself creates — a Tenant whose namespaces exist but are not
   labelled yet — by simply not labelling one.
3. **MTO is a private image behind a licence.** Requiring it would put a second
   credential in the way of `make e2e-kind`.

The cost is real and worth naming: nothing here proves the charts work
*alongside* MTO — that MTO labels namespaces the way the parent's
`namespaceSelector` expects, or that its webhooks admit what template-operator-v2
writes into tenant namespaces. That remains a live-cluster check.

## Why template-operator-v2's release name is not the one the bootstrap assumes

The bootstrap chart's `templateOperator.serviceAccountName` defaults to
`template-operator-template-operator-v2` — the ServiceAccount a
`helm install template-operator …` produces, which is what the live clusters
run. That release name does not work with the public chart (0.0.7, and the
chart in the template-operator-v2 checkout): its `Certificate` hardcodes
`issuerRef.name: template-operator-v2-selfsigned-issuer` while the `Issuer` it
ships is `<fullname>-selfsigned-issuer`, so under any release name other than
`template-operator-v2` the webhook certificate is never issued and the
controller pod waits on the `webhook-server-cert` Secret for ever. The bug is
in the generated chart (`charts/template-operator-v2/templates/serving-cert.yaml`
keeps kustomize's literal), not in the publishing step.

So the E2E cluster installs the release as `template-operator-v2` and the suite
sets `templateOperator.namespace` and `templateOperator.serviceAccountName`
from `E2E_TOV2_SA` — the same variable the RBAC probes use, so the identity the
chart grants to and the identity the probes ask about cannot disagree. Every
other bootstrap value stays at its default.

## Why the operator's own bao login does not use the chart's token reviewer

The bootstrap chart renders a `bao-token-reviewer` ServiceAccount and Secret,
and every per-tenant kubernetes-auth mount is configured with that JWT. The
operator's OWN login mount is configured without one: bao reviews the operator's
token with its own ServiceAccount, which the OpenBao chart binds to
`system:auth-delegator` by default. The suite uninstalls the bootstrap chart
between tests; had the operator's mount pointed at the chart's reviewer Secret,
that uninstall would break the operator's login an hour later — when its cached
token expires — and the failure would land in whichever test happened to be
running. The per-tenant mounts still go through the chart's reviewer, and
workload logins in the suite prove that path.

## What needs a credential

The operator and template-operator-v2. The operator's chart and image are
private GHCR packages, so the default lane needs `GHCR_TOKEN` with
`read:packages` — the same credential `make crd-validate` already needs, and
both workflows set it. `OPERATOR_SRC=../openbao-config-operator` replaces that
pull with a local build.

template-operator-v2 is pinned to a private dev build of its main branch
(`TOV2_CHART_VERSION` in the Makefile), because no public release yet carries
SA-9035: up to 0.0.8 it treats its copyable instance-uid label as proof of
ownership, and deletes the operator's `<tenant>-ca` ConfigMap, which carries
the CR's labels, on every tenant re-render. That pull needs the same token.
A public `TOV2_CHART` installs without one, and the suite then fails at the
trust-bundle step. Everything else is an anonymous pull.
