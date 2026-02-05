# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Kubernetes Operator for OpenBao (open-source Vault fork) that extends the Multi-Tenant Operator (MTO). It bridges Kubernetes RBAC with OpenBao secrets management, automatically provisioning policies and auth roles for MTO tenants.

## Build & Development Commands

```bash
# Build
make build                    # Build manager binary to bin/manager
make manifests                # Generate CRDs, RBAC, and webhook configs
make generate                 # Generate DeepCopy methods

# Test
make test                     # Run unit tests with envtest
make test-e2e                 # Run e2e tests (requires cluster with OpenBao)
go test ./internal/controller/tenant/... -v  # Run specific package tests

# Lint
make lint                     # Run golangci-lint
make lint-fix                 # Run golangci-lint with auto-fix

# Run locally
make run                      # Run controller from host (needs VAULT_ADDR/VAULT_TOKEN)

# Docker
make docker-build             # Build container image
make docker-push              # Push container image

# Cluster setup (Kind)
make setup-cluster            # Create Kind cluster with all dependencies
make deploy                   # Deploy operator to cluster
make install                  # Install CRDs only
```

## Architecture

### Controllers

**ClusterAuthReconciler** (`internal/controller/clusterauth/`):
- Watches `OpenBaoExtension` CR and referenced Secrets
- Ensures Kubernetes auth mount exists in OpenBao
- Sets `AuthConfigured` condition on OpenBaoExtension status

**TenantReconciler** (`internal/controller/tenant/`):
- Watches MTO `Tenant` resources
- Waits for `AuthConfigured=True` before proceeding
- Creates OpenBao policies and Kubernetes auth roles per tenant namespace
- Sets `TenantsReconciled` condition

### Key Types

**OpenBaoExtension** (`api/v1alpha1/openbaoextension_types.go`):
- Main CRD (shortName: `obx`)
- Configures server connection, auth, SSO, tenancy mode, RBAC, engines, and scaffolding

**bao_client** (`internal/client/bao_client.go`):
- HTTP client for OpenBao/Vault API
- Methods: `CheckKVv2Mount`, `CheckAuthMount`, `EnableAuthMount`, `UpsertPolicy`, `UpsertK8sRole`

### Reconciliation Flow

1. ClusterAuthReconciler reads token from Secret, verifies/enables Kubernetes auth mount
2. TenantReconciler watches Tenants, waits for `AuthConfigured=True`
3. For each tenant namespace: creates editor policy + Kubernetes auth role bound to default ServiceAccount

## Environment Variables

```bash
export GOPRIVATE=github.com/stakater-ab/*    # Required for private module dependencies
export VAULT_ADDR="http://localhost:8200"    # OpenBao server URL
export VAULT_TOKEN="<token>"                 # OpenBao token (or BAO_ADDR/BAO_TOKEN)
```

## E2E Testing Prerequisites

1. Authenticate with GitHub CLI
2. Install `openbao` and `jq` CLI tools
3. OpenBao running in cluster at port 8200
4. Run setup: `./test/e2e/obx_e2e_setup.sh`
