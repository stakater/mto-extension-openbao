# Third-party notices

This file records the third-party source code incorporated into this
repository and the terms under which that source is used.

Each row in the per-project tables names a file in this repo whose content
is adapted from an upstream file. The per-file header comment in the
source-code file itself repeats the attribution at the point of use.

See also the repo-level [LICENSE](./LICENSE) for this project's own terms.

---

## redhat-cop/vault-config-operator (VCO)

**Upstream:** <https://github.com/redhat-cop/vault-config-operator>
**License:** Apache License, Version 2.0.
**Why we reuse:** The operator cherry-picks type files defining OpenBao
primitives (Policy, KubernetesAuthEngineRole, PKI, cert/JWT auth, identity
groups) from VCO rather than authoring them from scratch. See
[docs/adr/0002-vco-fork-vs-cherrypick.md](./docs/adr/0002-vco-fork-vs-cherrypick.md)
for the decision rationale, and
[docs/plans/PLAN-vco-cherrypick-roadmap.md](./docs/plans/PLAN-vco-cherrypick-roadmap.md)
for the roll-in sequence.

**Apache-2.0 §4(d) propagation:** not applicable. VCO does not publish a
`NOTICE` file at its repository root, so no attribution text from upstream
needs propagating. Our compliance rests on (a) the per-file §4(b)
"modification" headers, (b) this table of attributions, and (c) preserving
VCO's copyright notices inside the copied files.

### Adapted files

| File in this repo | Upstream path | Source SHA | Modifications |
|---|---|---|---|
| [api/vco/v1alpha1/policy_types.go](./api/vco/v1alpha1/policy_types.go) | `api/v1alpha1/policy_types.go` | `96082119ec2e84595cc85b87808c3a6bd7aca53b` | `spec.authentication` removed; `spec.connection` removed; `spec.type` defaulted to `acl` and legacy `/sys/policy/<name>` path dropped; `PrepareInternalValues` accessor-templating deferred (rejects `${auth/}` placeholders until Story 6); `IsEquivalentToDesiredState` simplified to compare `{policy}`-shaped payloads only; fixed upstream copy-paste bug where `ConditionsAware` was asserted against `PKISecretEngineRole` instead of `Policy`; `GetKubeAuthConfiguration`/`GetVaultConnection` return `nil`. |

Further rows are appended as each story of the cherry-pick roadmap lands
its primitive(s).

### License text (Apache-2.0)

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

Full text: <https://www.apache.org/licenses/LICENSE-2.0.txt>.

A copy of the upstream license at the pinned SHA can be retrieved via:

    curl -sL https://raw.githubusercontent.com/redhat-cop/vault-config-operator/96082119ec2e84595cc85b87808c3a6bd7aca53b/LICENSE
