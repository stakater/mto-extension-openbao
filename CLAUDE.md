# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A Kubebuilder v4 / operator-sdk Kubernetes operator that extends Stakater's Multi-Tenant Operator (MTO) to provision per-tenant OpenBao (Vault-compatible) policies, Kubernetes-auth roles, and KV-v2 namespace paths. Go module: `github.com/stakater-ab/mto-extension-openbao` (Go 1.23).

## Private-module setup (required before any `go` / `make` command)

Depends on private modules under `github.com/stakater-ab/*`. Before `go mod tidy` / `make build`:

```bash
export GOPRIVATE=github.com/stakater-ab/*
git config --global url."ssh://git@github.com/".insteadOf "https://github.com/"
```

CI uses `ENABLE_STAKATER_AB_GIT_AUTH: true` plus the `STAKATER_AB_REPOS` secret via the shared `stakater/.github` workflows.

## Common commands

All tool binaries (`kustomize`, `controller-gen`, `envtest`, `golangci-lint`, `kind`, `helm`, `operator-sdk`, `opm`, `yq`) auto-install into `./bin/` on first use — don't install them globally.

- `make build` — regenerates manifests + deepcopy, then builds `bin/manager`.
- `make run` — runs the controller against the cluster in `~/.kube/config` (requires `VAULT_ADDR`/`VAULT_TOKEN` env for the Tenant reconciler).
- `make test` — unit tests via envtest (`$(ENVTEST_K8S_VERSION)` = 1.31.0). Excludes `./test/e2e`. Produces `cover.out`. **Use `make test`, not bare `go test ./...`.** envtest-backed suites (e.g. CRD-validation tests under [internal/controller/openbaopolicy/](internal/controller/openbaopolicy/) and [internal/controller/openbaokubernetesauthrole/](internal/controller/openbaokubernetesauthrole/)) self-skip when `KUBEBUILDER_ASSETS` is unset, so a bare `go test` silently passes without exercising the kubebuilder validation markers.
- Run a single unit test: `KUBEBUILDER_ASSETS="$(./bin/setup-envtest use 1.31.0 --bin-dir ./bin -p path)" go test ./internal/controller/tenant/ -run TestName -v`.
- `make lint` / `make lint-fix` — golangci-lint (config at [.golangci.yml](.golangci.yml); enabled: dupl, errcheck, goconst, gocyclo, gofmt, goimports, gosimple, govet, ineffassign, lll, misspell, nakedret, prealloc, staticcheck, typecheck, unconvert, unparam, unused).
- `make manifests generate` — regenerate CRDs/RBAC and DeepCopy. **Always run after editing `api/v1alpha1/*_types.go`.**
- `make deploy` / `make undeploy` — kind setup + tenant CRD + openbao helm install + credential provisioning + operator install, all chained.
- `make test-e2e` — port-forwards `svc/openbao` in `$(OPENBAO_NS)` to `127.0.0.1:18200`, reads `VAULT_TOKEN` from the `mto-openbao-token` secret in `$(OPERATOR_NS)`, runs ginkgo in `./test/e2e/`. See [README.md](README.md) for prerequisites (openbao + jq CLIs, `bao auth enable kubernetes`).
- `make bundle bundle-build bundle-push` / `make catalog-render catalog-build catalog-push` / `make publish` — OLM bundle & catalog pipeline. See [DEPLOY.md](DEPLOY.md).

## Architecture

### CRD: `OpenBaoExtension` (security.mto.stakater.com/v1alpha1, shortname `obx`)

Namespaced singleton-style CR. Schema is in [api/v1alpha1/openbaoextension_types.go](api/v1alpha1/openbaoextension_types.go) and is richer than what the controllers currently implement — treat unimplemented fields (SSO, Scaffolding, Projection, Engines, Layout templates, TenancyMode=namespace) as scaffolding for future work. Today only a small subset is used: `spec.server.{url,tokenSecretRef}`, `spec.rbac.token.{ttl,maxTTL,renewable}`, `spec.policyOverrides`, `spec.safety.allowDeletes`.

Status uses `metav1.Condition` with types in [api/v1alpha1/conditions.go](api/v1alpha1/conditions.go):
- `AuthConfigured` — owned by ClusterAuth controller.
- `TenantsReconciled` — owned by Tenant controller.
- `Ready` — **computed** (not owned directly) from the two above by [`utils.RecomputeReadyInPlace`](internal/utils/status.go). Both controllers call this after mutating their own condition.

### Controllers

Both live under [internal/controller/](internal/controller/) and are wired in [cmd/main.go](cmd/main.go). The `tenant-operator` `Tenant` CRD (`github.com/stakater-ab/tenant-operator/api/v1beta3`) is registered in the scheme.

**ClusterAuth** ([internal/controller/clusterauth/clusterauth_controller.go](internal/controller/clusterauth/clusterauth_controller.go)):
- Reconciles `OpenBaoExtension`. Also watches `Secret` and maps to any `OpenBaoExtension` referencing that secret as `spec.server.tokenSecretRef.Name`.
- Reads the Bao token from the referenced secret, constructs a [`baoclient.Client`](internal/client/bao_client.go), checks + enables the `kubernetes` auth mount at `constants.DefaultAuthMount`.
- Requeues every `authCheckInterval` (5m) for self-healing; errors back off at `authCheckErrorBackoff` (30s).
- Status writes go through `setAuthCond`, which uses `retry.RetryOnConflict` + `Status().Patch(MergeFrom)` — never write status without this pattern (tenant writes race with auth writes).

**Tenant** ([internal/controller/tenant/tenant_controller.go](internal/controller/tenant/tenant_controller.go)):
- Reconciles `Tenant` from MTO. Reads `VAULT_ADDR`/`VAULT_TOKEN` (or `BAO_ADDR`/`BAO_TOKEN`) **at construction time** via `NewTenantReconciler`; failure is fatal at startup.
- **Hard gate**: if no `OpenBaoExtension` has `AuthConfigured=True`, requeues in 30s without writing status. This eliminates races with ClusterAuth.
- Lists `OpenBaoExtension` cluster-wide and uses the **first** one for config (`spec.rbac.token.*`, `spec.policyOverrides`, `spec.safety.allowDeletes`). Multi-CR scenarios are not yet supported.
- For each namespace in `tenant.spec.namespaces.{withTenantPrefix,withoutTenantPrefix}`:
  - Computes a full ns name via [`utils.NamespaceFull`](internal/utils/namespace_util.go) (lowercased; `<tenant>-<short>` or `<short>`).
  - Derives policy name `<tenant>-<nsFull>-editor` and role name `<tenant>-<nsFull>`.
  - Upserts a KV-v2 ACL policy for `secret/{data,metadata}/tenants/<tenant>/<env>/<nsFull>/*`, then upserts a Kubernetes-auth role bound to ServiceAccount `default` in that namespace.
- Capability tiers are `admin/editor/viewer`; defaults live in `builtinCaps` in the controller. `spec.policyOverrides.<tier>.capabilities` **replaces** the default set. If `spec.safety.allowDeletes=false`, `delete` is stripped from the final cap set regardless of overrides.
- All status mutations happen in the deferred closure in `Reconcile` and go through `patchStatus` (also conflict-safe retry + merge patch).

### Bao HTTP client ([internal/client/bao_client.go](internal/client/bao_client.go))

Thin JSON client over Vault/OpenBao HTTP API — no Vault Go SDK dependency. Interface `Client` is what both controllers depend on; `httpClient` is the concrete impl. Handles both wrapped (`{"data":{…}}`) and flat response shapes, and treats `400 "path is already in use"` from `sys/auth/...` as idempotent success.

### Shared utilities

- [internal/utils/status.go](internal/utils/status.go) — `SetCond`, `RemoveCondGen`/`SetCondGen` (generation-stamped), `ComputeReady`, `RecomputeReadyInPlace`, `RecomputeReadyAndPatch`. Always use these; do not manipulate `status.conditions` directly.
- [internal/utils/namespace_util.go](internal/utils/namespace_util.go) — canonical naming for namespaces, role names, policy names. `canon` = lowercase.
- [internal/constants/constants.go](internal/constants/constants.go) — `DefaultKVMount="secret"`, `DefaultAuthMount="kubernetes"`, `DefaultEnv="prod"`.

## Primitive author checklist

Recurring review feedback from earlier primitive stories. Each new primitive (`OpenBaoPolicy`, `OpenBaoKubernetesAuthRole`, `OpenBaoSecretEngine`, `OpenBaoNamespace`, `OpenBaoPKISecretEngineConfig`, `OpenBaoPKISecretEngineRole`, future `OpenBaoIdentityGroup` / `OpenBaoIdentityTokenRole` / cert / JWT primitives, …) under [api/v1alpha1/](api/v1alpha1/) and a per-primitive controller package under [internal/controller/](internal/controller/) must satisfy these before merge.

- **Drift comparison normalizes.** `IsEquivalentToDesiredState` must trim whitespace and normalize ordering on any field where bao's read shape differs from the write shape. Naive `reflect.DeepEqual` on raw bao reads causes a write storm on every reconcile.
- **`IsValid()` rejects ambiguous shapes.** If `BaoGet` returns `("", ErrNotFound)` for missing, the spec must reject empty bodies — otherwise a present-but-empty object is indistinguishable from missing and the reconciler enters an infinite create loop. Apply the same logic to any field whose zero value collides with bao's "missing" signal.
- **Bao-name collision check.** When a spec field maps to a bao path (e.g. `spec.name` → `sys/policies/acl/<name>`), two CRs in different k8s namespaces can target the same bao object. The handler must list peers and reject when a different-UID CR already owns the target. For namespace-aware primitives the collision tuple includes `spec.openbaoNamespace` — same name in different OpenBao namespaces is not a collision because bao isolates them via `X-Vault-Namespace`. Tie-break: older `CreationTimestamp` wins; on tie, lex `<namespace>/<name>`. See [`checkPolicyNameCollision`](internal/controller/openbaopolicy/openbaopolicy_controller.go) and [`checkRoleNameCollision`](internal/controller/openbaokubernetesauthrole/openbaokubernetesauthrole_controller.go) for reference implementations.
- **Kubebuilder `Pattern:` markers are anchored.** OpenAPI v3's `pattern` does substring match — `[a-z0-9]…` accepts `Bad_Name1`. Always anchor with `^…$`.
- **Wrapper Get methods return [`baoclient.ErrNotFound`](internal/client/bao_client.go) for missing.** Not `("", nil)`, not `(nil, nil)`, not a synthetic `*StatusError{404}`. Callers classify with `errors.Is`.
- **HTTP status classification uses `*baoclient.StatusError`.** Never grep an error message for `"404"` or `"permission denied"`; structured status travels through `errors.As`. See [`ClassifyErr`](internal/vaultobject/resource/errors.go).
- **CRD validation markers are envtest-verified.** Add a case to a `*_validation_test.go` under envtest for every Pattern / MinLength / Required / Enum the controller relies on. See [openbaopolicy/crd_validation_test.go](internal/controller/openbaopolicy/crd_validation_test.go) and [openbaokubernetesauthrole/crd_validation_test.go](internal/controller/openbaokubernetesauthrole/crd_validation_test.go). These suites self-skip when `KUBEBUILDER_ASSETS` is unset, so always invoke via `make test` — bare `go test ./...` silently passes.
- **New wrapper methods need httptest contract tests.** Any new method on [`baoclient.Client`](internal/client/bao_client.go) needs a `bao_client_test.go` test asserting URL, method, and body shape — guards against the SDK silently renaming or dropping fields between releases.
- **Status writes go through the shared base.** `VaultResource.setReady` and the `utils.SetCondGen` / `utils.RecomputeReadyInPlace` helpers handle `retry.RetryOnConflict + Status().Patch(MergeFrom)`. Status writes from multiple controllers race; rolling your own loses condition updates.
- **No forward-looking comments in code.** No "in story N", "in this release", "once X exposes Y", roadmap-flavored TODOs, or "removed for milestone Z" notes. Forward-looking notes belong in PR descriptions and ADRs, not in code where they rot.
- **Comments in the shared base must hold for all callers.** Don't justify base-layer behavior with a specific caller's predicate, mount, or wiring choice — a future primitive that composes `VaultResource[T]` differently makes the comment a lie.

## Release / catalog

Per [DEPLOY.md](DEPLOY.md): CI auto-bumps version from the latest git tag. A catalog release fires only when files under `catalog/` change **and** a new entry is added to `catalog/channels.yaml`. Use `skips:` for non-breaking changes, `replaces:` only for breaking API changes. Strict semver.
