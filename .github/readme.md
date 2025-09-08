# Workflow 

This repository uses shared workflows [`operator_pull_request.yaml`](https://github.com/stakater/.github/blob/main/.github/workflows/operator_pull_request.yaml) and [`operator_push.yaml`](https://github.com/stakater/.github/blob/main/.github/workflows/operator_pull_request.yaml) available in [`stakater/.github`](https://github.com/stakater/.github). 
These workflows are shared between [IPShield](https://github.com/stakater/IPShield), [UptimeGuardian](https://github.com/stakater/UptimeGuardian), [MTO OpenBao Extension](#) and [MTO Grafana Extension](#)

## Steps

Following steps are performed by both `pull_request` and `push` workflows. Tag generation step has slightly different inputs depending on the workflow

1. Checkout code
1. Run `make lint`
1. Run `make test`
1. Generate Tags
1. Setup Docker (Login to image to repository)
1. Install Openshift tools
1. Run `make manifests build docker-build docker-push`
1. Run `make bundle bundle-build bundle-push`
1. Run `make catalog-render` to generate custom catalog index
1. Run `make catalog-build catalog-push`
1. Push git tag
1. Comment on PR
1. Notify Slack

### Go module setup for private repos

This project depends on private modules under `github.com/stakater-ab`.

Before running `make build` or `go mod tidy`, configure Go to treat them as private:

```bash
# Tell Go to skip proxy/caching for private modules
export GOPRIVATE=github.com/stakater-ab/*

# If you use SSH for GitHub (recommended):
git config --global url."ssh://git@github.com/".insteadOf "https://github.com/"

## E2E

### Prerequisites

0. authenticated with GitHub CLI
1. install openbao and jq cli.
2. ensure openbao is running in the cluster at port 8200.
3. `export VAULT_ADDR="http://localhost:8200"`
4. `export VAULT_TOKEN="<root-or-admin-token>"`

### Setup
`./test/e2e/obx_e2e_setup.sh`

### Run test
`make test-e2e`