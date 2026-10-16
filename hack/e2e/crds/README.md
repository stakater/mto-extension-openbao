# Vendored CRDs

## multi-tenant-operator

`tenantoperator.stakater.com_tenants.yaml`, from
`tenant-operator/helm-charts/tenant-operator/crds/` at
**v1.9.0-cf4a826e-4-g0ff789fa**, with two edits, both required:

- **`spec.conversion` removed.** It points at MTO's own webhook service, which
  does not exist on a cluster running the CRD without the operator, so every
  read of a `Tenant` would fail. Dropping it leaves `strategy: None`; the parent
  TemplateInstance reads Tenants at the storage version, `v1beta3`, so no
  conversion is needed.
- **the `cert-manager.io/inject-ca-from` annotation removed**, for the same
  reason — it names MTO's certificate.

It is here so `make e2e-up` can stand up the bootstrap chart's input — the
`Tenant` — without installing multi-tenant-operator, which is a licensed private
image whose webhooks would take away what the E2E cluster exists to provide
(creating Tenants and labelled namespaces freely).
[hack/e2e/README.md](../README.md) explains that trade in full.

The same file, with the same edits, is vendored in mto-extension-argocd's
`tests/crds/`. **Refresh it when MTO changes the CRD**, re-applying both edits,
and record the new version here.
