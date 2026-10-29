# Running E2E

```bash
make e2e-kind
```

That builds a kind cluster, installs everything the charts need, serves this
checkout's tenant chart from inside the cluster, and runs the suite — which
installs and uninstalls the bootstrap chart itself — dumping diagnostics into
`./e2e-logs` if anything fails. It is idempotent: run it again and it reuses the
cluster and whatever is already installed.

## What you need

| | |
|---|---|
| docker | kind runs the cluster inside it; budget ~2 GB of memory for this cluster |
| kubectl, go, jq | on `PATH` |
| helm | the system one if present (≥ 3.14), else downloaded into `bin/` |
| `GHCR_TOKEN` | **read:packages** on `ghcr.io/stakater` — the operator's chart and image are private. The same credential `make crd-validate` needs |

Everything else is an anonymous pull: cert-manager, trust-manager, External
Secrets, OpenBao, and template-operator-v2's public release at
`oci://ghcr.io/stakater/public/charts/template-operator-v2`.

Without a token, build the operator from a sibling checkout instead — also the
only way to test an **unreleased** operator against these charts:

```bash
make e2e-kind OPERATOR_SRC=../openbao-config-operator
```

That builds the image with the checkout's Dockerfile, loads it into kind, and
installs the checkout's `charts/openbao-config-operator`. Regenerate that chart
(`make helmify` in the operator repo) if you changed the operator's manifests.

## What it stands up

[hack/e2e/README.md](../hack/e2e/README.md) has the component list and the
reasoning behind each one, including why **multi-tenant-operator itself is not
installed** — only its `Tenant` CRD — and why the operator's own bao login does
not go through the chart's token reviewer.

Two of those decisions shape what the suite can and cannot say:

- **The suite plays MTO's part.** It creates the Tenants and their namespaces
  and puts the `stakater.com/tenant` label on them. That is what lets it model
  the window MTO creates for every new tenant — declared namespaces, not yet
  labelled — by simply not labelling one.
- **The tenant chart comes from the working tree, not from ghcr.io.**
  `make e2e-chart-repo` packages `charts/mto-extension-openbao` and serves it from
  an nginx pod; the bootstrap is installed with `openbaoConfigMto.registry`
  pointing there. Edit the tenant chart, re-run `make e2e-chart-repo`, re-run
  the suite. The version served is the one `Chart.yaml` names, so
  `helm-version-check` applies here as everywhere else.

## Iterating

`make e2e-kind` re-runs the whole dependency chain each time, which is fast once
the images are cached but not instant. While working on the suite or a chart:

```bash
make e2e-up OPERATOR_SRC=../openbao-config-operator   # once
make e2e-chart-repo                                    # after every tenant-chart edit
make e2e-test \
  KUBE_CONTEXT=kind-openbao-mto-e2e \
  E2E_CHART_REPO_URL=http://chart-repo.chart-repo.svc.cluster.local \
  E2E_TOV2_SA=system:serviceaccount:stakater-template-operator:template-operator-v2
```

`make e2e-test` is a thin wrapper over `go test ./tests/e2e/...`; call `go test`
directly with the same environment plus `HELM=` and `-run` to pick a subtest.
The other `E2E_*` variables default to what `e2e-kind` sets. Tear down with
`make cluster-delete`.

**OpenBao runs in dev mode.** It is in-memory: restarting `openbao-0` wipes every
namespace, mount and policy, including the operator's own login mount. `make
e2e-deps` re-creates all of it, but the operator keeps its cached token for up
to an hour and fails every reconcile until then — restart its Deployment too.

## CI

[.github/workflows/e2e.yaml](../.github/workflows/e2e.yaml) runs the same
`make e2e-kind` on a GitHub runner, with kind created **on the runner itself**.
It is not part of every pull request: an approval from a repo owner, org member
or collaborator, the `ok-to-test/kubernetes` label, or a manual dispatch
triggers it — an approval from anyone else deliberately does not, because the
run executes PR-authored code with a package-read secret in the environment.
`e2e-logs/` is uploaded as an artifact when it fails.

The fast checks — lint, version pin, render tests, CRD validation — run on every
pull request through `make all`. They catch most regressions in a minute; this
suite exists for the ones that only appear when template-operator-v2 renders,
the operator writes to bao, and a workload logs in.

## What the suite covers

One test function, ordered subtests, one install of the bootstrap chart with
the chart defaults plus the two optional integrations (`parent.certManager.enabled`,
`crossTenantPki.enabled`) and `templateOperator.*` set from `E2E_TOV2_SA` (why:
[hack/e2e/README.md](../hack/e2e/README.md)). Grouped by what each step is for:

| Area | What it pins |
|---|---|
| RBAC | the chart grants template-operator-v2 exactly the documented permissions and no others, measured as a before/after delta with `kubectl auth can-i` |
| Shared scaffolding | the parent renders; the `shared/` bao namespace, its KV and transit mounts and its kubernetes auth mount exist **in bao**, not just as Ready CRs; the platform CA is a self-signed CA constrained to `svc.cluster.local` |
| Fan-out | every labelled tenant gets a TemplateInstance per enabled slice (core, `.eso`, `.certmanager`, `.trust`); `matchedNamespaces` is exactly the tenant's labelled namespaces; an unlabelled namespace reaches nobody |
| The unlabelled window | a Tenant whose namespace is not labelled yet fails only its own TemplateInstance — parent and siblings stay Ready, the parent's `tiReady` roll-up names it — and heals with no re-apply when the label lands |
| Tenant scaffolding | the tenant's namespace, mounts and auth exist in bao; its CA is an intermediate signed by the platform CA, name-constrained to exactly its namespaces, and published to the `<tenant>-ca` ConfigMap |
| Opt-in is the boundary | before any annotation: no policy, no ConfigMap, only bao's `default` policy |
| A workload, end to end | annotate a ServiceAccount and a Deployment; then **as that ServiceAccount**: log in, write and read its own KV path, be refused a sibling app's path and another tenant's namespace, encrypt/decrypt with its transit key, issue a certificate for its own service name and be refused one in another tenant. ESO delivers the secret it wrote as a Kubernetes Secret; cert-manager issues a `Certificate` through the rendered `Issuer`; trust-manager's `Bundle` carries the tenant CA into its namespaces |
| Namespace growth | a new labelled namespace is picked up by the child alone; the PKI role's `allowedDomains` follows it, the CA's name constraints stay frozen (as documented) |
| Blast radius | a ServiceAccount with an engine and no tier gets a `bao-config-<sa>.error` ConfigMap naming the fault, no policy, and freezes nothing else; fixing the annotation replaces the report |
| Cross-tenant sharing | export to a real peer and to a non-existent one: the real peer gets a grant, the phantom none; the exporter writes, the importer reads and cannot write, the exporter cannot reach a peer it did not name; ESO delivers the share into the importing tenant |
| Drift protection | an out-of-band edit to a rendered ConfigMap is reverted (`sync.mode: revert`, the default) |
| Deletion policy | opting a workload out deletes its policy and role in bao and refuses its login, while its KV data survives; deleting a Tenant reaps every rendered object — including a peer's share **to** it — and retains its bao namespace and data |
| Uninstall | the documented order (parent TemplateInstance first, then the release) leaves no rendered object behind, retains every bao namespace and its data, and leaves the operator's own login mount untouched |

**What is deliberately NOT here.** Values validation — typos in toggles, a bad
`sync.mode`, an unconstrained CA, name budgets, YAML nulls in the empty-tenant
window — lives in `hack/chart-render-tests.sh` and `make crd-validate`, which
run in seconds. Repeating it here would cost minutes and prove less.

## What this cluster cannot tell you

Worth knowing before treating a green run as "shipped":

- **Nothing here runs multi-tenant-operator.** That it labels namespaces the
  way the parent's `namespaceSelector` expects, and that its webhooks admit what
  template-operator-v2 writes into tenant namespaces, are live-cluster facts.
- **No SSO.** `parent.sso.enabled` stays off — it needs an OIDC provider. The
  render tests cover the SSO objects; nobody logs in as a human here.
- **`platformPki.mode=intermediate` is not exercised.** The run uses `root`.
  The operator repo's e2e covers the CSR/set-signed mechanics;
  `hack/sign-platform-ca.sh` is the manual ceremony for a test cluster.
- **NetworkPolicies and monitoring stay off.** kind's default CNI does not
  enforce NetworkPolicies, and there is no prometheus-operator.
- **One node, no OpenShift.**
