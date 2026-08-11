<!-- markdownlint-disable MD013 -->

# mto-extension-openbao

Helm charts that give every [Multi-Tenant Operator](https://github.com/stakater/multi-tenant-operator) (MTO) `Tenant` its own OpenBao setup — a private namespace, KV, Transit keys, a PKI CA, and human SSO login — with no per-tenant manual work.

The charts only *describe* configuration. They emit `OpenBao*` custom resources. The thing that talks to OpenBao and makes those resources real is a separate operator:

**[stakater-ab/openbao-config-operator](https://github.com/stakater-ab/openbao-config-operator)** — the controllers, the CRDs, and the operator's own install chart.

Install the operator first, then the bootstrap chart from here.

## The two charts

| Chart | Install it? | What it does |
|---|---|---|
| [`openbao-config-mto-bootstrap`](charts/openbao-config-mto-bootstrap/) | Yes | Cluster-wide setup, installed once. Watches `Tenant` CRs and fans out one render per tenant. |
| [`openbao-config-mto`](charts/openbao-config-mto/) | No | The per-tenant template. template-operator-v2 pulls it from OCI and renders it once per `Tenant`. Never installed by hand. |

Both publish to `oci://ghcr.io/stakater/charts`.

**[charts/README.md](charts/README.md) is the real documentation** — how the pieces fit together, the workload annotation contract, and a section per feature (KV, Transit, PKI, SSO, ESO delivery).

## Working on the charts

```bash
make                    # everything CI runs — this is the default goal
make helm-lint
make helm-version-check
make helm-render-test
make crd-validate
```

`make` with no target runs exactly what CI runs. There is no help-only default: a contributor who types `make`, sees green, and pushes has actually tested the change.

[hack/chart-render-tests.sh](hack/chart-render-tests.sh) is the real test suite — a golden object-set, slice disjointness, RBAC scope, name budgets, hostile-input handling, and an apiserver-acceptance check. Run it after any change under [charts/openbao-config-mto/](charts/openbao-config-mto/). An intentional change to the rendered output means regenerating [hack/render-fixtures/golden-all.yaml](hack/render-fixtures/golden-all.yaml); the command is in the script's header.

The apiserver check shells out to `go run ./hack/render-validate`, which decodes rendered YAML through the same path client-go uses and runs apimachinery's validators over names, labels and ConfigMap keys. `yq` can't stand in for it — go-yaml v3 keeps `no` a string where the apiserver reads a boolean. That helper and [hack/crd-validate/](hack/crd-validate/) are the only Go in this repo, and the only reason there is a `go.mod`.

If the Go toolchain is missing the script downgrades that one check to a skip rather than failing, so CI installs Go explicitly.

## Conventions

Neither chart is generated, and nothing here regenerates them — these are the rules that keep them honest.

- **Bump `Chart.yaml` `version` in the same commit as any chart change.** `helm push` has no existence check, no `--force`, and GHCR permits tag overwrite — pushing an already-published version succeeds and silently replaces what tenants pull. `make helm-release` therefore probes with `helm show chart` first and refuses a version that already exists. That probe is the only backstop; nothing about `helm push` itself protects you.
- **Keep `openbaoConfigMto.version` in the bootstrap's `values.yaml` matching [charts/openbao-config-mto/Chart.yaml](charts/openbao-config-mto/Chart.yaml).** template-operator-v2 pulls that exact version per `Tenant` at render time, so a mismatch means tenants silently render an old chart. `make helm-version-check` enforces this.
- **Register new values in `values.schema.json`.** Both charts have one. A stringly toggle with a typo otherwise disables a feature silently.
- **Neither chart ships a CRD.** They emit `OpenBao*` CRs against CRDs owned by the operator repo. [hack/crds/](hack/crds/) holds a *vendored copy* of those CRDs — not shipped, only used by `make crd-validate`, which prunes and validates every rendered CR exactly as the apiserver would. That is what catches a field renamed on either side. Verified against the live cluster: server-side apply — how t-op-v2 writes these — rejects an undeclared field, so the tenant's TemplateInstance fails and the resource is never created; a client sending `fieldValidation=Ignore` has it silently dropped instead. Neither is caught by anything else here, and a failed child TI raises no metric and no Event.
- **`crd-validate` coverage is per render path, and that matters.** The check is field-level, so a kind validated in one pass says nothing about a field only another pass emits. It covers the tenant chart at `component=all` and at each slice for all three fixtures, plus the bootstrap chart in both `platformPki.mode=root` and `mode=intermediate`. **A new opt-in whose fields no fixture turns on is not covered** — add it to [values-full.yaml](hack/render-fixtures/values-full.yaml) when you add the value.
- **The vendored CRDs go stale silently.** If the operator renames a field, no file in this repo changes, so no CI run is even triggered. `make crd-staleness` diffs [hack/crds/](hack/crds/) against the branch named in [hack/crds/SOURCE](hack/crds/SOURCE) and runs as an advisory PR job; `make crds-vendor` refreshes them. Both need a token that can read the private operator repo. `SOURCE` points at `split/import-operator` until that PR merges, because the operator's default branch does not carry the CRDs yet — move it to `main` once it does.
