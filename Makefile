# MTO OpenBao extension — Helm charts.
#
# This repo holds the two hand-maintained charts that template-operator-v2
# renders once per MTO Tenant. The operator that reconciles the OpenBao* CRs
# they emit, its CRDs and its install chart live in
# github.com/stakater-ab/openbao-config-operator.

# Each chart publishes at its own Chart.yaml version.
MTO_BOOTSTRAP_VERSION := $(shell awk '/^version:/{print $$2; exit}' charts/openbao-config-mto-bootstrap/Chart.yaml)
MTO_VERSION           := $(shell awk '/^version:/{print $$2; exit}' charts/openbao-config-mto/Chart.yaml)

DOCKER_REPO_BASE ?= ghcr.io/stakater
ifeq ($(strip $(DOCKER_REPO_BASE)),)
DOCKER_REPO_BASE := ghcr.io/stakater
endif
HELM_REGISTRY ?= $(DOCKER_REPO_BASE)/charts

MTO_BOOTSTRAP_CHART_DIR ?= charts/openbao-config-mto-bootstrap
MTO_CHART_DIR           ?= charts/openbao-config-mto

# Registry credentials. GHCR_* is what push.yaml sets; GIT_* is the local
# override so a developer can push to their own registry without exporting
# GHCR-shaped names.
GIT_USER  ?= $(GHCR_USERNAME)
GIT_TOKEN ?= $(GHCR_TOKEN)

.DEFAULT_GOAL := all

.PHONY: all
all: helm-lint helm-version-check helm-render-test crd-validate ## Everything CI runs: lint, version pin, render tests, CRD schema check.

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Chart tests

.PHONY: helm-lint
helm-lint: helm ## Lint both hand-maintained charts.
	$(HELM) lint $(MTO_BOOTSTRAP_CHART_DIR) --strict
	$(HELM) lint $(MTO_CHART_DIR) --strict --set tenant=lint-only

.PHONY: helm-render-test
helm-render-test: helm yq ## Verify the tenant chart's component slices (golden, disjoint, union, purity).
	HELM=$(HELM) YQ=$(YQ_BIN) hack/chart-render-tests.sh

CRD_DIR         ?= hack/crds
CRD_SOURCE_REPO := $(shell awk -F= '/^repo=/{print $$2}' $(CRD_DIR)/SOURCE)
CRD_SOURCE_REF  := $(shell awk -F= '/^ref=/{print $$2}' $(CRD_DIR)/SOURCE)

# The check is field-level, so every render path that can emit an OpenBao* CR
# needs its own pass: a kind validated in one says nothing about a field only
# another emits. Hence each component slice, and the bootstrap chart's
# mode=intermediate branch, which emits a field mode=root never does.
#
# Slices may legitimately render nothing, so they pass -allow-empty. The full
# renders must not — zero objects there means the render broke.
#
# values-no-workloads covers a state no other fixture reaches: a tenant whose
# namespaces are not labeled yet, so every per-namespace list renders empty. An
# unguarded `key:` over an empty range is YAML null, which fails admission and
# so fails the tenant's whole TemplateInstance. Only a real admission pass finds
# those, because the render itself succeeds.
TENANT_COMPONENTS ?= all core eso certManager trust

.PHONY: crd-validate
crd-validate: helm ## Validate every rendered OpenBao* CR against the vendored operator CRDs.
	@set -e; \
	for fx in values-full values-guards values-no-optins values-no-workloads; do \
		for comp in $(TENANT_COMPONENTS); do \
			empty=-allow-empty; [ "$$comp" = all ] && empty=""; \
			printf -- '-- tenant %s/%s ' "$$fx" "$$comp"; \
			$(HELM) template crdcheck $(MTO_CHART_DIR) -n crdcheck \
				-f hack/render-fixtures/$$fx.yaml --set-string component=$$comp \
				| go run ./hack/crd-validate $$empty $(CRD_DIR) -; \
		done; \
	done; \
	printf -- '-- bootstrap mode=root '; \
	$(HELM) template crdcheck $(MTO_BOOTSTRAP_CHART_DIR) -n crdcheck \
		--set-string platformPki.mode=root \
		| go run ./hack/crd-validate $(CRD_DIR) -; \
	printf -- '-- bootstrap mode=intermediate '; \
	$(HELM) template crdcheck $(MTO_BOOTSTRAP_CHART_DIR) -n crdcheck \
		--set-string platformPki.mode=intermediate \
		--set-string platformPki.externalSignSecret=platform-pki-signed \
		| go run ./hack/crd-validate $(CRD_DIR) -

# The vendored CRDs go stale silently: a field renamed upstream changes no file
# here, so nothing triggers. This diffs them against CRD_SOURCE_BRANCH, which is
# a variable because the operator's default branch does not carry the CRDs until
# the split lands.
#
# Hard failure when run directly; the workflow is what marks it
# continue-on-error. Not part of `all`, which must pass offline.
CRD_SOURCE_BRANCH ?= $(shell awk -F= '/^branch=/{print $$2}' $(CRD_DIR)/SOURCE)
CRD_SOURCE_PATH   := config/crd/bases

.PHONY: crd-staleness
crd-staleness: ## Report drift between hack/crds and $(CRD_SOURCE_BRANCH) of the operator repo.
	@command -v gh >/dev/null 2>&1 || { echo "gh not installed — skipping"; exit 0; }
	@tmp=$$(mktemp -d); rc=0; \
	upstream=$$(gh api "repos/$(CRD_SOURCE_REPO)/contents/$(CRD_SOURCE_PATH)?ref=$(CRD_SOURCE_BRANCH)" -q '.[].name' 2>/dev/null) || upstream=""; \
	if [ -z "$$upstream" ]; then \
		rm -rf $$tmp; \
		echo "cannot list $(CRD_SOURCE_REPO)@$(CRD_SOURCE_BRANCH):$(CRD_SOURCE_PATH) — wrong branch, or no read access"; \
		exit 1; \
	fi; \
	for f in $(CRD_DIR)/*.yaml; do \
		b=$$(basename $$f); \
		: > $$tmp/$$b; \
		if ! gh api "repos/$(CRD_SOURCE_REPO)/contents/$(CRD_SOURCE_PATH)/$$b?ref=$(CRD_SOURCE_BRANCH)" -q .content 2>/dev/null > $$tmp/$$b.b64; then \
			echo "GONE:  $$b (not in $(CRD_SOURCE_REPO)@$(CRD_SOURCE_BRANCH))"; rc=1; continue; \
		fi; \
		base64 -d < $$tmp/$$b.b64 > $$tmp/$$b 2>/dev/null || { echo "GONE:  $$b (undecodable response)"; rc=1; continue; }; \
		diff -q $$f $$tmp/$$b >/dev/null || { echo "STALE: $$b"; rc=1; }; \
	done; \
	for b in $$upstream; do \
		[ -f $(CRD_DIR)/$$b ] || { echo "NEW:   $$b (upstream only — not vendored here)"; rc=1; }; \
	done; \
	rm -rf $$tmp; \
	if [ $$rc -eq 0 ]; then echo "vendored CRDs match $(CRD_SOURCE_REPO)@$(CRD_SOURCE_BRANCH) (pinned $(CRD_SOURCE_REF))"; \
	else echo "run 'make crds-vendor' and re-run the chart tests"; fi; \
	exit $$rc

# Fetches into a temp dir first and refuses to touch hack/crds unless the fetch
# produced files — replacing the vendored set with nothing, then recording a ref
# for a tree never fetched, is worse than doing nothing.
.PHONY: crds-vendor
crds-vendor: ## Refresh hack/crds from $(CRD_SOURCE_BRANCH) of the operator repo.
	@set -e; \
	command -v gh >/dev/null 2>&1 || { echo "gh is required"; exit 1; }; \
	tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; \
	names=$$(gh api "repos/$(CRD_SOURCE_REPO)/contents/$(CRD_SOURCE_PATH)?ref=$(CRD_SOURCE_BRANCH)" -q '.[].name'); \
	if [ -z "$$names" ]; then \
		echo "no CRDs at $(CRD_SOURCE_REPO)@$(CRD_SOURCE_BRANCH):$(CRD_SOURCE_PATH) — leaving hack/crds untouched"; exit 1; \
	fi; \
	for b in $$names; do \
		gh api "repos/$(CRD_SOURCE_REPO)/contents/$(CRD_SOURCE_PATH)/$$b?ref=$(CRD_SOURCE_BRANCH)" -q .content | base64 -d > $$tmp/$$b; \
		[ -s $$tmp/$$b ] || { echo "empty download for $$b — leaving hack/crds untouched"; exit 1; }; \
	done; \
	sha=$$(gh api "repos/$(CRD_SOURCE_REPO)/commits/$(CRD_SOURCE_BRANCH)" -q .sha); \
	[ -n "$$sha" ] || { echo "could not resolve $(CRD_SOURCE_BRANCH) — leaving hack/crds untouched"; exit 1; }; \
	rm -f $(CRD_DIR)/*.yaml; \
	cp $$tmp/*.yaml $(CRD_DIR)/; \
	today=$$(date +%Y-%m-%d); \
	sed -i.bak -e "s|^ref=.*|ref=$$sha|" -e "s|^date=.*|date=$$today|" $(CRD_DIR)/SOURCE; \
	rm -f $(CRD_DIR)/SOURCE.bak; \
	echo "vendored $$(ls $(CRD_DIR)/*.yaml | wc -l | tr -d ' ') CRDs from $(CRD_SOURCE_BRANCH) at $$sha ($$today)"

##@ Chart release

.PHONY: helm-login
helm-login: helm ## Log in to the OCI chart registry.
	@if [ -z "$(GIT_USER)" ] || [ -z "$(GIT_TOKEN)" ]; then \
		echo "GIT_USER/GIT_TOKEN (or GHCR_USERNAME/GHCR_TOKEN) must be set"; exit 1; \
	fi
	@echo "$(GIT_TOKEN)" | $(HELM) registry login $(firstword $(subst /, ,$(HELM_REGISTRY))) -u "$(GIT_USER)" --password-stdin

.PHONY: helm-release
helm-release: helm-release-mto-bootstrap helm-release-mto ## Release both charts to OCI.

# helm push has no existence check and no --force, and GHCR permits tag
# overwrite, so a republished version silently replaces what tenants pull.
#
# Fails closed: only an explicit not-found means the tag is free. helm show chart
# also exits 1 on DNS failure and an expired token, and treating those as free
# would publish over tenants on a network blip. Must run after helm-login —
# unauthenticated, GHCR answers 403 for absent and published tags alike.
define check-tag-free
@out=$$($(HELM) show chart oci://$(HELM_REGISTRY)/$(1) --version $(2) 2>&1); rc=$$?; \
if [ $$rc -eq 0 ]; then \
	echo "$(1) $(2) is already published — bump Chart.yaml before releasing"; exit 1; \
fi; \
if ! printf '%s' "$$out" | grep -qiE 'not found|manifest unknown|name unknown'; then \
	echo "cannot determine whether $(1) $(2) is published — refusing to push:"; \
	printf '%s\n' "$$out" | head -3; exit 1; \
fi
endef

.PHONY: helm-release-mto-bootstrap
helm-release-mto-bootstrap: helm helm-login ## Lint, package and push openbao-config-mto-bootstrap.
	$(HELM) lint $(MTO_BOOTSTRAP_CHART_DIR) --strict
	$(call check-tag-free,openbao-config-mto-bootstrap,$(MTO_BOOTSTRAP_VERSION))
	@mkdir -p dist
	$(HELM) package $(MTO_BOOTSTRAP_CHART_DIR) -d dist
	$(HELM) push dist/openbao-config-mto-bootstrap-$(MTO_BOOTSTRAP_VERSION).tgz oci://$(HELM_REGISTRY)

.PHONY: helm-release-mto
helm-release-mto: helm helm-login ## Lint, package and push openbao-config-mto (per-Tenant chart pulled by t-op-v2).
	$(HELM) lint $(MTO_CHART_DIR) --strict --set tenant=lint-only
	$(call check-tag-free,openbao-config-mto,$(MTO_VERSION))
	@mkdir -p dist
	$(HELM) package $(MTO_CHART_DIR) -d dist
	$(HELM) push dist/openbao-config-mto-$(MTO_VERSION).tgz oci://$(HELM_REGISTRY)

# t-op-v2 pulls the tenant chart at the exact version openbaoConfigMto.version
# names. Bumping Chart.yaml without the pin leaves tenants on the old chart;
# bumping the pin without publishing leaves them rendering nothing.
.PHONY: helm-version-check
helm-version-check: ## Fail if the bootstrap's openbaoConfigMto.version disagrees with the tenant Chart.yaml.
	@# The awk block leaves openbaoConfigMto at the next top-level key, so a
	@# missing version: under it cannot silently adopt a later one. Both values
	@# are asserted non-empty: comparing "" to "" is equality, which would make
	@# a parse failure on either side the pass path.
	@pinned=$$(awk '/^openbaoConfigMto:/{f=1; next} f && /^[^[:space:]]/{exit} f && /^  version:/{print $$2; exit}' \
		$(MTO_BOOTSTRAP_CHART_DIR)/values.yaml); \
	if [ -z "$$pinned" ]; then \
		echo "could not read openbaoConfigMto.version from $(MTO_BOOTSTRAP_CHART_DIR)/values.yaml"; exit 1; \
	fi; \
	if [ -z "$(MTO_VERSION)" ]; then \
		echo "could not read version from $(MTO_CHART_DIR)/Chart.yaml"; exit 1; \
	fi; \
	if [ "$$pinned" != "$(MTO_VERSION)" ]; then \
		echo "openbaoConfigMto.version ($$pinned) != $(MTO_CHART_DIR) Chart.yaml ($(MTO_VERSION))"; exit 1; \
	fi; \
	echo "chart version pin OK ($$pinned)"

##@ Tools

LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

# A system binary wins over the pinned download, so *_VERSION is what we fetch
# and *_MIN is the floor enforced against whatever is actually used.
#
# curl -f matters: without it curl writes the HTTP error body to the destination
# and exits 0, so an error page becomes the cached tool. The tar and --version
# probes are the real net — nothing lands in bin/ that has not run once.
HELM         ?= $(shell command -v helm || echo $(LOCALBIN)/helm)
HELM_VERSION ?= v3.19.0
HELM_MIN     ?= 3.14

YQ_BIN     ?= $(shell command -v yq || echo $(LOCALBIN)/yq)
YQ_VERSION ?= v4.44.3
# 4.40 is where the harness first runs clean end to end, measured across builds:
# 4.25.1 fails 6 checks and 4.35.2 still fails 1. splitDoc is not the binding
# constraint — it works as far back as 4.13.5; sort_keys is what the older
# builds get wrong, and a too-low floor lets them through to fail as a golden
# diff with no hint that the yq version is the cause.
YQ_MIN     ?= 4.40

# Both targets are phony and always run their floor check. Making the check a
# prerequisite of the downloaded file instead would skip it whenever the binary
# already exists — which is the normal case, and the only case where the floor
# matters.
OS_LOWER = $$(uname | tr '[:upper:]' '[:lower:]')
ARCH_GO  = $$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: helm
helm: ## Ensure a helm binary of at least $(HELM_MIN) is available.
	@if [ ! -x "$(HELM)" ]; then \
		set -e ;\
		echo "Downloading helm $(HELM_VERSION)" ;\
		mkdir -p $(LOCALBIN) ;\
		tmp=$$(mktemp -d) ;\
		curl -fsSL -o $$tmp/helm.tar.gz "https://get.helm.sh/helm-$(HELM_VERSION)-$(OS_LOWER)-$(ARCH_GO).tar.gz" ;\
		tar -zxf $$tmp/helm.tar.gz -C $$tmp ;\
		mv $$tmp/$(OS_LOWER)-$(ARCH_GO)/helm $(LOCALBIN)/helm ;\
		chmod +x $(LOCALBIN)/helm ;\
		rm -rf $$tmp ;\
	fi
	@have=$$($(HELM) version --template '{{.Version}}' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;\
	if [ -z "$$have" ]; then echo "$(HELM) is not a working helm binary — delete it and re-run"; exit 1; fi ;\
	if [ "$$(printf '%s\n%s\n' "$(HELM_MIN)" "$$have" | sort -V | head -1)" != "$(HELM_MIN)" ]; then \
		echo "helm $$have is older than the required $(HELM_MIN) ($(HELM))"; exit 1; \
	fi

.PHONY: yq
yq: ## Ensure a yq binary of at least $(YQ_MIN) is available.
	@if [ ! -x "$(YQ_BIN)" ]; then \
		set -e ;\
		echo "Downloading yq $(YQ_VERSION)" ;\
		mkdir -p $(LOCALBIN) ;\
		tmp=$$(mktemp) ;\
		curl -fsSL -o $$tmp "https://github.com/mikefarah/yq/releases/download/$(YQ_VERSION)/yq_$(OS_LOWER)_$(ARCH_GO)" ;\
		chmod +x $$tmp ;\
		$$tmp --version >/dev/null ;\
		mv $$tmp $(LOCALBIN)/yq ;\
	fi
	@have=$$($(YQ_BIN) --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;\
	if [ -z "$$have" ]; then echo "$(YQ_BIN) is not a working yq binary — delete it and re-run"; exit 1; fi ;\
	if [ "$$(printf '%s\n%s\n' "$(YQ_MIN)" "$$have" | sort -V | head -1)" != "$(YQ_MIN)" ]; then \
		echo "yq $$have is older than the required $(YQ_MIN) — splitDoc is unavailable ($(YQ_BIN))"; exit 1; \
	fi
