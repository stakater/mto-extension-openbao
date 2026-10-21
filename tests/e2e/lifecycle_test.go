package e2e

import (
	"encoding/base64"
	"fmt"
	"sort"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// TestLifecycle runs the scenarios in dependency order against ONE install of
// the bootstrap chart. Deliberately one test with ordered subtests rather than
// independent ones: each step's precondition is the previous step's outcome,
// and an install/uninstall per scenario — with template-operator-v2 pulling
// the chart and rendering three tenants each time — would take longer than the
// whole suite.
//
// The install carries the chart defaults plus the two optional integrations
// that are off by default (cert-manager Issuers, cross-tenant trust), so every
// slice the bootstrap can emit is rendered and every RBAC branch is exercised.
func TestLifecycle(t *testing.T) {
	// The RBAC "before" picture has to precede the install.
	before := rbacSnapshot(t)

	helmInstall(t,
		"--set", "parent.certManager.enabled=true",
		"--set", "crossTenantPki.enabled=true",
	)
	// Idempotent, so the explicit uninstall subtest at the end and this Cleanup
	// can both run; the Cleanup is what tears down after a mid-run failure.
	t.Cleanup(func() { helmUninstall(t) })

	// The workload the middle of the suite revolves around.
	const (
		webSA       = "web"
		webPolicy   = tenantAlpha + "-" + nsAlphaDev + "-" + webSA
		webKVPath   = env + "/" + nsAlphaDev + "/" + webSA + "/db-creds"
		webPassword = "hunter2"
		alphaNS     = tenantAlpha + "/"
		betaNS      = tenantBeta + "/"
		pkiMount    = "pki-int"
		pkiRole     = tenantAlpha + "-svc"
	)
	var tenantCASerial string

	t.Run("the chart grants template-operator-v2 exactly what it needs", func(t *testing.T) {
		rbacDelta(t, before)
	})

	t.Run("the parent renders and the shared scaffolding reconciles into bao", func(t *testing.T) {
		waitReady(t, gvrTemplateInstance, operatorNS, parentName)

		// The singletons behind every tenant. If the shared kubernetes auth
		// config is not Ready, no cross-tenant share in any tenant can log in.
		for _, o := range []struct {
			gvr  schemaGVR
			name string
		}{
			{gvrBaoNamespace, "shared"},
			{gvrSecretEngine, "shared-kv"},
			{gvrSecretEngine, "shared-transit"},
			{gvrAuthMethod, "shared-kubernetes"},
			{gvrK8sAuthConfig, "shared-kubernetes-config"},
			// Platform PKI, the bootstrap chart's own CRs (platformPki.enabled
			// defaults to true, mode=root).
			{gvrBaoNamespace, "platform"},
			{gvrSecretEngine, "platform-pki"},
			{gvrPKIConfig, "platform-pki"},
		} {
			waitReady(t, o.gvr, operatorNS, o.name)
		}
		if serial, _, _ := unstructured.NestedString(mustGet(t, gvrPKIConfig, operatorNS, "platform-pki").Object, "status", "caSerialNumber"); serial == "" {
			t.Error("platform-pki is Ready but reports no caSerialNumber")
		}

		// bao agrees. Ready=True on a CR is the operator's claim; these are bao's.
		nss := baoNamespaces(t)
		for _, want := range []string{sharedNS, "platform/"} {
			if !contains(nss, want) {
				t.Errorf("bao namespace %s missing; have %v", want, nss)
			}
		}
		mounts := baoMounts(t, sharedNS)
		for _, want := range []string{"kv/", "transit/"} {
			if !contains(mounts, want) {
				t.Errorf("shared/ mount %s missing; have %v", want, mounts)
			}
		}
		auths := baoJSON(t, baoIn(t, sharedNS, "auth", "list", "-format=json"))
		if _, ok := auths["kubernetes/"]; !ok {
			t.Errorf("shared/ has no kubernetes auth mount; have %v", keysOf(auths))
		}

		// The platform CA is what the bootstrap said: a CA, self-signed
		// (mode=root), constrained to the cluster's service domain — the bound
		// every tenant intermediate inherits.
		ca := parseCert(t, baoIn(t, "platform/", "read", "-field=certificate", "pki-platform/cert/ca"))
		if !ca.IsCA {
			t.Error("platform CA certificate is not a CA")
		}
		if ca.Subject.CommonName != "Platform CA" {
			t.Errorf("platform CA CN = %q", ca.Subject.CommonName)
		}
		if ca.Issuer.CommonName != ca.Subject.CommonName {
			t.Errorf("platform CA is not self-signed under mode=root: issuer %q", ca.Issuer.CommonName)
		}
		if got := ca.PermittedDNSDomains; !equalStrings(got, []string{"svc.cluster.local"}) {
			t.Errorf("platform CA permitted DNS domains = %v, want [svc.cluster.local]", got)
		}
	})

	t.Run("every labelled tenant gets one TemplateInstance per enabled slice", func(t *testing.T) {
		for _, tn := range []string{tenantAlpha, tenantBeta} {
			for _, suffix := range []string{"", ".eso", ".certmanager", ".trust"} {
				waitReady(t, gvrTemplateInstance, operatorNS, tiPrefix+tn+suffix)
			}
			// matchedNamespaces is the child's own account of what its
			// namespaceSelector resolved to — the thing MTO's labelling feeds.
			want := labelledNamespaces(tn)
			got, _, _ := unstructured.NestedStringSlice(mustGet(t, gvrTemplateInstance, operatorNS, tiPrefix+tn).Object, "status", "matchedNamespaces")
			sort.Strings(got)
			if !equalStrings(got, want) {
				t.Errorf("%s matchedNamespaces = %v, want %v", tn, got, want)
			}
			if contains(got, nsNoise) {
				t.Errorf("the unlabelled namespace %s reached tenant %s", nsNoise, tn)
			}
		}
	})

	t.Run("a tenant whose namespaces are not labelled yet fails only itself, and heals when the label lands", func(t *testing.T) {
		// This is the state MTO puts every new tenant in between creating the
		// Tenant and labelling its namespaces. The parent emits gamma's
		// TemplateInstance (the Tenant declares a namespace), the child's
		// namespaceSelector matches nothing, and template-operator-v2 refuses to
		// resolve its parameters. Pinned here: the failure is gamma's alone.
		ti := tiPrefix + tenantGamma
		waitState(t, "gamma's TemplateInstance to report Ready=False", func() string {
			obj := get(t, gvrTemplateInstance, operatorNS, ti)
			s, _, _, ok := condition(obj, "Ready")
			switch {
			case obj == nil:
				return "absent"
			case !ok:
				return "no Ready condition yet"
			case s == "True":
				return "Ready=True — expected the unlabelled window to fail this child"
			}
			return ""
		})
		_, reason, message, _ := condition(mustGet(t, gvrTemplateInstance, operatorNS, ti), "Ready")
		t.Logf("gamma before its namespace is labelled: reason=%s message=%q", reason, message)

		if !isReady(get(t, gvrTemplateInstance, operatorNS, parentName)) {
			t.Error("the parent went Ready=False over one tenant's unlabelled window")
		}
		if !isReady(get(t, gvrTemplateInstance, operatorNS, tiPrefix+tenantAlpha)) {
			t.Error("alpha went Ready=False over gamma's unlabelled window")
		}
		// The parent's roll-up names the broken tenant — the one place a
		// platform operator can see it without reading every child.
		outputs, _, _ := unstructured.NestedMap(mustGet(t, gvrTemplateInstance, operatorNS, parentName).Object, "status", "outputs")
		tiReady, _ := outputs["tiReady"].(map[string]any)
		if v, _ := tiReady[ti].(string); v == "" || strings.Contains(v, "True") {
			t.Errorf("parent outputs.tiReady[%s] = %q, want a False entry; outputs keys: %v", ti, v, keysOf(outputs))
		}

		// MTO labels the namespace. Nothing is re-applied by hand: the child's
		// Namespace informer sees the label and the render goes through.
		labelNamespace(t, nsGammaAPI, tenantGamma)
		waitReady(t, gvrTemplateInstance, operatorNS, ti)
		waitReady(t, gvrBaoNamespace, operatorNS, tenantGamma)
	})

	t.Run("tenant scaffolding reconciles into bao with a platform-signed, name-constrained CA", func(t *testing.T) {
		for _, o := range []struct {
			gvr  schemaGVR
			name string
		}{
			{gvrBaoNamespace, tenantAlpha},
			{gvrSecretEngine, tenantAlpha + "-kv"},
			{gvrSecretEngine, tenantAlpha + "-transit"},
			{gvrSecretEngine, tenantAlpha + "-pki"},
			{gvrAuthMethod, tenantAlpha + "-kubernetes"},
			{gvrK8sAuthConfig, tenantAlpha + "-kubernetes-config"},
			{gvrPKIConfig, tenantAlpha + "-pki-root"},
			{gvrPKIRole, "pki-" + pkiRole},
			{gvrTransitKey, "transit-" + tenantAlpha + "-shared-" + env},
		} {
			waitReady(t, o.gvr, operatorNS, o.name)
		}
		if !contains(baoNamespaces(t), alphaNS) {
			t.Errorf("bao namespace %s missing; have %v", alphaNS, baoNamespaces(t))
		}
		mounts := baoMounts(t, alphaNS)
		for _, want := range []string{"kv/", "transit/", pkiMount + "/"} {
			if !contains(mounts, want) {
				t.Errorf("%s mount %s missing; have %v", alphaNS, want, mounts)
			}
		}

		// The tenant CA: an intermediate signed by the platform CA (hierarchy
		// mode, the default under platformPki.enabled), name-constrained to
		// exactly the tenant's labelled namespaces. The render tests pin that
		// the constraint list is never empty; this pins what bao actually
		// issued, which is what every verifier will enforce.
		ca := parseCert(t, baoIn(t, alphaNS, "read", "-field=certificate", pkiMount+"/cert/ca"))
		tenantCASerial = ca.SerialNumber.String()
		if !ca.IsCA {
			t.Error("tenant CA certificate is not a CA")
		}
		if ca.Subject.CommonName != tenantAlpha+" Internal CA" {
			t.Errorf("tenant CA CN = %q", ca.Subject.CommonName)
		}
		if ca.Issuer.CommonName != "Platform CA" {
			t.Errorf("tenant CA issuer = %q, want the platform CA", ca.Issuer.CommonName)
		}
		want := []string{nsAlphaDev + ".svc.cluster.local", nsAlphaTools + ".svc.cluster.local"}
		got := append([]string(nil), ca.PermittedDNSDomains...)
		sort.Strings(got)
		if !equalStrings(got, want) {
			t.Errorf("tenant CA permitted DNS domains = %v, want %v", got, want)
		}

		// Published for trust distribution: the .trust slice's Bundle sources it.
		cm := waitConfigMap(t, operatorNS, tenantAlpha+"-ca")
		if published := parseCert(t, cm.Data["ca.crt"]); published.SerialNumber.String() != tenantCASerial {
			t.Errorf("%s-ca ConfigMap holds a different certificate than bao's CA", tenantAlpha)
		}
	})

	t.Run("nothing is granted before a workload opts in", func(t *testing.T) {
		if got := list(t, gvrPolicy, operatorNS, "templates.v2.stakater.com/instance="+tiPrefix+tenantAlpha); len(got) != 0 {
			t.Errorf("%d OpenBaoPolicies rendered for %s with no opted-in ServiceAccount: %v", len(got), tenantAlpha, names(got))
		}
		for _, ns := range []string{nsAlphaDev, nsAlphaTools, nsNoise} {
			cms, err := kube.CoreV1().ConfigMaps(ns).List(ctx, listAll)
			if err != nil {
				t.Fatal(err)
			}
			for _, cm := range cms.Items {
				if strings.HasPrefix(cm.Name, "bao-") {
					t.Errorf("%s/%s rendered with nothing opted in", ns, cm.Name)
				}
			}
		}
		if pols := baoPolicies(t, alphaNS); !equalStrings(pols, []string{"default"}) {
			t.Errorf("bao policies in %s before any opt-in: %v, want only default", alphaNS, pols)
		}
	})

	t.Run("an opted-in workload gets its grants and can use every engine", func(t *testing.T) {
		setServiceAccount(t, nsAlphaDev, webSA, map[string]string{"kv": "true", "tier": "editor", "transit": "true", "pki": "true"})
		setDeployment(t, nsAlphaDev, webSA, webSA, map[string]string{"kv-secret.db": "db-creds#password"})

		waitReady(t, gvrPolicy, operatorNS, webPolicy)
		waitReady(t, gvrK8sAuthRole, operatorNS, webPolicy)
		cm := waitConfigMap(t, nsAlphaDev, "bao-config-"+webSA)
		for k, want := range map[string]string{
			"VAULT_K8S_ROLE":       webPolicy,
			"VAULT_NAMESPACE":      alphaNS,
			"VAULT_KV_APP_PATH":    "kv/data/" + env + "/" + nsAlphaDev + "/" + webSA + "/",
			"VAULT_PKI_MOUNT":      pkiMount,
			"VAULT_PKI_ISSUE_PATH": pkiMount + "/issue/" + pkiRole,
		} {
			if cm.Data[k] != want {
				t.Errorf("bao-config-%s %s = %q, want %q", webSA, k, cm.Data[k], want)
			}
		}
		appKey := cm.Data["VAULT_TRANSIT_APP_KEY"]
		if !strings.HasPrefix(appKey, nsAlphaDev+"-"+webSA+"-"+env+"-") {
			t.Fatalf("VAULT_TRANSIT_APP_KEY = %q", appKey)
		}
		waitReady(t, gvrTransitKey, operatorNS, "transit-"+tenantAlpha+"-"+appKey)
		if apps := waitConfigMap(t, nsAlphaDev, "bao-apps"); !strings.Contains(apps.Data[webSA], "tier: \"editor\"") {
			t.Errorf("bao-apps has no editor entry for %s: %q", webSA, apps.Data[webSA])
		}
		// ESO validates a SecretStore by logging in with the workload's
		// ServiceAccount through the chart's token reviewer. Ready=True here is
		// the first independent proof that the rendered kubernetes-auth role
		// and the bootstrap's bao-token-reviewer both work.
		waitReady(t, gvrSecretStore, nsAlphaDev, webSA+"-bao")
		if get(t, gvrExternalSecret, nsAlphaDev, webSA+"-db") == nil {
			t.Fatalf("ExternalSecret %s/%s-db not rendered from the Deployment annotation", nsAlphaDev, webSA)
		}

		// Now as the workload itself: its own token, its own login, its own paths.
		tok, pols := baoLogin(t, alphaNS, webPolicy, saToken(t, nsAlphaDev, webSA))
		if !contains(pols, webPolicy) {
			t.Errorf("login as %s attached policies %v, want %s", webSA, pols, webPolicy)
		}
		if _, err := baoAs(t, tok, alphaNS, "kv", "put", "-mount=kv", webKVPath, "password="+webPassword); err != nil {
			t.Fatalf("%s cannot write its own secret: %v", webSA, err)
		}
		if got, err := baoKVGet(t, tok, alphaNS, "kv", webKVPath, "password"); err != nil || got != webPassword {
			t.Errorf("%s reads back %q (err %v), wrote %q", webSA, got, err, webPassword)
		}
		// Isolation, at the app grain and at the tenant grain. Both refusals
		// must come from bao's policy, not from a typo in the path.
		if _, err := baoAs(t, tok, alphaNS, "kv", "put", "-mount=kv", env+"/"+nsAlphaDev+"/other-app/x", "a=b"); err == nil || !strings.Contains(err.Error(), "permission denied") {
			t.Errorf("%s could write a sibling app's prefix (err %v)", webSA, err)
		}
		if _, err := baoAs(t, tok, betaNS, "kv", "put", "-mount=kv", env+"/"+nsBetaAPI+"/x", "a=b"); err == nil {
			t.Errorf("%s's %s token was accepted in %s", webSA, alphaNS, betaNS)
		}

		// Transit: the app's private key round-trips.
		plain := base64.StdEncoding.EncodeToString([]byte("hello"))
		out, err := baoAs(t, tok, alphaNS, "write", "-format=json", "transit/encrypt/"+appKey, "plaintext="+plain)
		if err != nil {
			t.Fatalf("encrypt with %s: %v", appKey, err)
		}
		cipher, _ := baoJSON(t, out)["data"].(map[string]any)["ciphertext"].(string)
		out, err = baoAs(t, tok, alphaNS, "write", "-format=json", "transit/decrypt/"+appKey, "ciphertext="+cipher)
		if err != nil {
			t.Fatalf("decrypt with %s: %v", appKey, err)
		}
		if got, _ := baoJSON(t, out)["data"].(map[string]any)["plaintext"].(string); got != plain {
			t.Errorf("transit round-trip returned %q, want %q", got, plain)
		}

		// PKI: a cert for the workload's own service name, refused for a
		// name in another tenant. The role's allowedDomains and the CA's name
		// constraints both stand behind the refusal.
		ownName := webSA + "." + nsAlphaDev + ".svc.cluster.local"
		out, err = baoAs(t, tok, alphaNS, "write", "-format=json", pkiMount+"/issue/"+pkiRole, "common_name="+ownName, "ttl=1h")
		if err != nil {
			t.Fatalf("issuing a certificate for %s: %v", ownName, err)
		}
		leaf := parseCert(t, baoJSON(t, out)["data"].(map[string]any)["certificate"].(string))
		if !contains(leaf.DNSNames, ownName) || leaf.Issuer.CommonName != tenantAlpha+" Internal CA" {
			t.Errorf("issued leaf: SANs %v issuer %q", leaf.DNSNames, leaf.Issuer.CommonName)
		}
		foreign := webSA + "." + nsBetaAPI + ".svc.cluster.local"
		if _, err := baoAs(t, tok, alphaNS, "write", "-format=json", pkiMount+"/issue/"+pkiRole, "common_name="+foreign, "ttl=1h"); err == nil {
			t.Errorf("%s could mint a certificate for %s, another tenant's namespace", webSA, foreign)
		}

		// ESO closes the loop: the secret the workload wrote lands as a
		// Kubernetes Secret named by the Deployment annotation.
		waitReady(t, gvrExternalSecret, nsAlphaDev, webSA+"-db")
		if s := secret(t, nsAlphaDev, webSA+"-db"); s == nil || string(s.Data["password"]) != webPassword {
			t.Errorf("Secret %s/%s-db does not carry the value written to bao", nsAlphaDev, webSA)
		}

		// cert-manager: the .certmanager slice's Issuer logs in as
		// bao-cert-manager (through the bootstrap's ClusterRole + the slice's
		// RoleBinding) and issues through the tenant CA.
		waitReady(t, gvrIssuer, nsAlphaDev, pkiRole)
		createCertificate(t, nsAlphaDev, "web-tls", pkiRole, ownName)
		t.Cleanup(func() { deleteObject(t, gvrCertificate, nsAlphaDev, "web-tls") })
		waitReady(t, gvrCertificate, nsAlphaDev, "web-tls")
		if s := secret(t, nsAlphaDev, "web-tls"); s == nil {
			t.Error("Certificate web-tls is Ready but its Secret is absent")
		} else if crt := parseCert(t, string(s.Data["tls.crt"])); crt.Issuer.CommonName != tenantAlpha+" Internal CA" {
			t.Errorf("web-tls issued by %q, want the tenant CA", crt.Issuer.CommonName)
		}

		// trust-manager: the .trust slice's Bundle carries the tenant's own CA
		// into its namespaces (no peer opted in yet, so only its own).
		waitCondition(t, gvrBundle, "", tenantAlpha+"-trust", "Synced")
		bundle := waitConfigMap(t, nsAlphaDev, tenantAlpha+"-trust")
		found := false
		for _, c := range parseCerts(t, bundle.Data["trust-bundle.pem"]) {
			if c.SerialNumber.String() == tenantCASerial {
				found = true
			}
		}
		if !found {
			t.Errorf("trust bundle in %s does not contain the tenant CA", nsAlphaDev)
		}
	})

	t.Run("a namespace the tenant gains is picked up without a parent re-render", func(t *testing.T) {
		// MTO adds a namespace to a tenant: a new labelled namespace appears.
		// The child's Namespace informer widens its matched set; nothing else
		// changes, and in particular the parent is not involved.
		const newNS = tenantAlpha + "-new"
		createNamespace(t, newNS, tenantAlpha)
		t.Cleanup(func() { deleteNamespace(t, newNS) })
		setServiceAccount(t, newNS, "batch", map[string]string{"kv": "true", "tier": "viewer"})

		waitReady(t, gvrPolicy, operatorNS, tenantAlpha+"-"+newNS+"-batch")
		waitConfigMap(t, newNS, "bao-config-batch")
		matched, _, _ := unstructured.NestedStringSlice(mustGet(t, gvrTemplateInstance, operatorNS, tiPrefix+tenantAlpha).Object, "status", "matchedNamespaces")
		if !contains(matched, newNS) {
			t.Errorf("alpha's matchedNamespaces %v does not include %s", matched, newNS)
		}

		// The PKI role follows the tenant's namespaces (allowedDomains is a
		// role field, updatable in place)...
		waitState(t, "the PKI role to allow the new namespace", func() string {
			out := baoIn(t, tenantAlpha+"/", "read", "-format=json", pkiMount+"/roles/"+pkiRole)
			domains := strList(baoJSON(t, out)["data"].(map[string]any)["allowed_domains"])
			if contains(domains, newNS+".svc.cluster.local") {
				return ""
			}
			return fmt.Sprintf("allowed_domains = %v", domains)
		})
		// ...but the CA's X.509 name constraints do not: they are frozen at
		// issuance, which the chart documents. A leaf for the new namespace
		// therefore verifies only if the CA is re-issued — a platform-operator
		// action. Pinned so a change on either side has to update the docs.
		ca := parseCert(t, baoIn(t, tenantAlpha+"/", "read", "-field=certificate", pkiMount+"/cert/ca"))
		if ca.SerialNumber.String() != tenantCASerial {
			t.Errorf("the tenant CA was re-issued when a namespace was added (serial %s -> %s)", tenantCASerial, ca.SerialNumber)
		}
		if contains(ca.PermittedDNSDomains, newNS+".svc.cluster.local") {
			t.Errorf("the CA's name constraints grew to include %s — the chart documents them as frozen at creation", newNS)
		}
	})

	t.Run("a misconfigured ServiceAccount is reported beside it and freezes nothing else", func(t *testing.T) {
		// An engine with no tier grants nothing. The chart says so in a
		// ConfigMap next to the workload — where the pod that fails to start
		// on its missing configMapRef will be looked at — and renders the rest
		// of the tenant as if the bad ServiceAccount were not there.
		setServiceAccount(t, nsAlphaTools, "broken", map[string]string{"kv": "true"})
		errCM := waitConfigMap(t, nsAlphaTools, "bao-config-broken.error")
		if !strings.Contains(errCM.Data["ERROR"], "tier is not set") {
			t.Errorf("error ConfigMap does not name the fault:\n%s", errCM.Data["ERROR"])
		}
		// Same render, so this is a fact, not a race: the error ConfigMap and a
		// policy for the same ServiceAccount cannot both come out of it.
		if get(t, gvrPolicy, operatorNS, tenantAlpha+"-"+nsAlphaTools+"-broken") != nil {
			t.Error("a policy was rendered for a ServiceAccount the chart reported as misconfigured")
		}
		if !isReady(get(t, gvrTemplateInstance, operatorNS, tiPrefix+tenantAlpha)) {
			t.Error("alpha's TemplateInstance went Ready=False over one bad ServiceAccount")
		}
		if configMap(t, nsAlphaDev, "bao-config-"+webSA) == nil {
			t.Errorf("%s's ConfigMap disappeared while a sibling namespace had a bad ServiceAccount", webSA)
		}

		// Fixing the annotation replaces the report with the real thing.
		setServiceAccount(t, nsAlphaTools, "broken", map[string]string{"kv": "true", "tier": "viewer"})
		waitConfigMap(t, nsAlphaTools, "bao-config-broken")
		waitFor(t, "the error ConfigMap to be reaped", func() bool { return configMap(t, nsAlphaTools, "bao-config-broken.error") == nil })
	})

	outRole := "share-" + tenantAlpha + "-" + nsAlphaTools + "-exporter-out-" + tenantBeta
	inRole := "share-" + tenantBeta + "-" + nsBetaAPI + "-importer-in-" + tenantAlpha

	t.Run("a cross-tenant share is granted to the named peer only", func(t *testing.T) {
		// `nobody` is not a Tenant. The parent stamps the tenant roster into
		// every child, and the chart renders no grant for a peer that is not
		// on it — no dangling policy, and the share appears by itself if the
		// peer is created later.
		setServiceAccount(t, nsAlphaTools, "exporter", map[string]string{"kv": "true", "tier": "editor", "kv-export-tenant": tenantBeta + ",nobody"})
		setServiceAccount(t, nsBetaAPI, "importer", map[string]string{"kv": "true", "tier": "viewer", "kv-import-tenant": tenantAlpha})
		setDeployment(t, nsBetaAPI, "importer", "importer", map[string]string{"kv-import.feed": tenantAlpha + "/feed"})

		for _, r := range []string{outRole, inRole} {
			waitReady(t, gvrPolicy, operatorNS, r)
			waitReady(t, gvrK8sAuthRole, operatorNS, r)
		}
		if get(t, gvrPolicy, operatorNS, "share-"+tenantAlpha+"-"+nsAlphaTools+"-exporter-out-nobody") != nil {
			t.Error("a share was rendered for a tenant that does not exist")
		}
		exp := waitConfigMap(t, nsAlphaTools, "bao-config-exporter")
		for k, want := range map[string]string{
			"VAULT_OUT_E2E_BETA_ROLE":      outRole,
			"VAULT_OUT_E2E_BETA_NAMESPACE": sharedNS,
			"VAULT_OUT_E2E_BETA_PATH":      "kv/data/" + env + "/from-" + tenantAlpha + "/to-" + tenantBeta + "/",
		} {
			if exp.Data[k] != want {
				t.Errorf("bao-config-exporter %s = %q, want %q", k, exp.Data[k], want)
			}
		}
		if imp := waitConfigMap(t, nsBetaAPI, "bao-config-importer"); imp.Data["VAULT_IN_E2E_ALPHA_ROLE"] != inRole {
			t.Errorf("bao-config-importer VAULT_IN_E2E_ALPHA_ROLE = %q, want %q", imp.Data["VAULT_IN_E2E_ALPHA_ROLE"], inRole)
		}
		waitReady(t, gvrSecretStore, nsBetaAPI, "importer.share-"+tenantAlpha+"-bao")

		// The data path, as the two workloads. The exporter writes into the
		// shared space under its own tenant's prefix, to the peer it named;
		// the importer reads it and can do nothing else there.
		feed := env + "/from-" + tenantAlpha + "/to-" + tenantBeta + "/feed"
		expTok, _ := baoLogin(t, sharedNS, outRole, saToken(t, nsAlphaTools, "exporter"))
		if _, err := baoAs(t, expTok, sharedNS, "kv", "put", "-mount=kv", feed, "token=abc"); err != nil {
			t.Fatalf("exporter cannot write its share: %v", err)
		}
		if _, err := baoAs(t, expTok, sharedNS, "kv", "put", "-mount=kv", env+"/from-"+tenantAlpha+"/to-"+tenantGamma+"/x", "a=b"); err == nil {
			t.Error("exporter could write to a peer it did not name")
		}
		impTok, _ := baoLogin(t, sharedNS, inRole, saToken(t, nsBetaAPI, "importer"))
		if got, err := baoKVGet(t, impTok, sharedNS, "kv", feed, "token"); err != nil || got != "abc" {
			t.Errorf("importer reads %q (err %v), want abc", got, err)
		}
		if _, err := baoAs(t, impTok, sharedNS, "kv", "put", "-mount=kv", feed, "token=tampered"); err == nil {
			t.Error("importer could write to the share it may only read")
		}

		// And ESO delivers it into the importing tenant.
		waitReady(t, gvrExternalSecret, nsBetaAPI, "importer-feed")
		if s := secret(t, nsBetaAPI, "importer-feed"); s == nil || string(s.Data["token"]) != "abc" {
			t.Error("Secret importer-feed does not carry the shared value")
		}
	})

	t.Run("drift protection reverts an out-of-band edit", func(t *testing.T) {
		// sync.mode=revert, the chart default: template-operator-v2 watches
		// what it rendered and puts it back.
		cm := configMap(t, nsAlphaDev, "bao-config-"+webSA)
		want := cm.Data["VAULT_K8S_ROLE"]
		cm.Data["VAULT_K8S_ROLE"] = "tampered"
		if _, err := kube.CoreV1().ConfigMaps(nsAlphaDev).Update(ctx, cm, updateOpts); err != nil {
			t.Fatalf("editing the rendered ConfigMap: %v", err)
		}
		waitState(t, "the edit to be reverted", func() string {
			got := configMap(t, nsAlphaDev, "bao-config-"+webSA).Data["VAULT_K8S_ROLE"]
			if got == want {
				return ""
			}
			return "VAULT_K8S_ROLE=" + got
		})
	})

	t.Run("removing an opt-in revokes access and keeps the data", func(t *testing.T) {
		// Grants render with deletionPolicy Delete, data-bearing kinds with
		// Retain — the safety posture the charts README describes. Opting out
		// must close the login door and leave the secrets where they are.
		setServiceAccount(t, nsAlphaDev, webSA, nil)
		waitGone(t, gvrPolicy, operatorNS, webPolicy)
		waitGone(t, gvrK8sAuthRole, operatorNS, webPolicy)
		waitFor(t, "the workload's ConfigMap to be reaped", func() bool { return configMap(t, nsAlphaDev, "bao-config-"+webSA) == nil })

		if _, err := baoRun(t, baoRootToken, alphaNS, "policy", "read", webPolicy); err == nil {
			t.Errorf("bao policy %s still exists after the CR was deleted", webPolicy)
		}
		if err := baoTryLogin(t, alphaNS, webPolicy, saToken(t, nsAlphaDev, webSA)); err == nil {
			t.Errorf("%s can still log in after opting out", webSA)
		}
		if got, err := baoKVGet(t, baoRootToken, alphaNS, "kv", webKVPath, "password"); err != nil || got != webPassword {
			t.Errorf("the workload's data did not survive its opt-out: %q (err %v)", got, err)
		}
	})

	t.Run("deleting a Tenant reaps its rendered config and retains its bao data", func(t *testing.T) {
		deleteObject(t, gvrTenant, "", tenantBeta)
		for _, suffix := range []string{"", ".eso", ".certmanager", ".trust"} {
			waitGone(t, gvrTemplateInstance, operatorNS, tiPrefix+tenantBeta+suffix)
		}
		waitGone(t, gvrBaoNamespace, operatorNS, tenantBeta)
		// The roster shrank, so alpha's share TO beta is withdrawn too — the
		// exporter's grant, in a different tenant's render.
		waitGone(t, gvrPolicy, operatorNS, outRole)

		if !contains(baoNamespaces(t), betaNS) {
			t.Errorf("deleting the Tenant destroyed bao namespace %s; deletionProtection should have retained it", betaNS)
		}
		if mounts := baoMounts(t, betaNS); !contains(mounts, "kv/") {
			t.Errorf("%s lost its kv mount: %v", betaNS, mounts)
		}
		shared := baoPolicies(t, sharedNS)
		for _, revoked := range []string{inRole, outRole} {
			if contains(shared, revoked) {
				t.Errorf("share policy %s still granted in %s after the Tenant went", revoked, sharedNS)
			}
		}
	})

	t.Run("uninstalling removes every rendered object and retains bao data", func(t *testing.T) {
		helmUninstall(t)
		if left := templateInstances(t); len(left) != 0 {
			t.Errorf("TemplateInstances left after uninstall: %v", left)
		}
		for _, gvr := range []schemaGVR{gvrPolicy, gvrK8sAuthRole, gvrBaoNamespace, gvrSecretEngine, gvrPKIConfig} {
			if got := list(t, gvr, operatorNS, ""); len(got) != 0 {
				t.Errorf("%s left after uninstall: %v", gvr.Resource, names(got))
			}
		}
		nss := baoNamespaces(t)
		for _, kept := range []string{alphaNS, betaNS, sharedNS, "platform/"} {
			if !contains(nss, kept) {
				t.Errorf("uninstall destroyed bao namespace %s", kept)
			}
		}
		// Grants are gone, data is not: the only policy left in the tenant's
		// namespace is bao's own default, and the KV mount still holds the
		// workload's secret.
		if pols := baoPolicies(t, alphaNS); !equalStrings(pols, []string{"default"}) {
			t.Errorf("policies left in %s after uninstall: %v", alphaNS, pols)
		}
		if got, _ := baoKVGet(t, baoRootToken, alphaNS, "kv", webKVPath, "password"); got != webPassword {
			t.Errorf("uninstall lost the tenant's data: %q", got)
		}
		// The operator's own login mount was never the chart's to remove.
		if auths := baoJSON(t, bao(t, "auth", "list", "-format=json")); auths["k8s-operator/"] == nil {
			t.Errorf("the operator's auth mount is gone after uninstall; have %v", keysOf(auths))
		}
	})
}

// ------------------------------------------------------------------- RBAC

// rbacProbes measures the permissions the chart ADDS, which is the only honest
// way to assert least privilege: template-operator-v2's ServiceAccount already
// holds broad grants from its own install (its own CRDs cluster-wide, reading
// Secrets), and an absolute assertion would fail on those and say nothing about
// this chart.
var rbacProbes = []struct {
	desc string
	args []string
	want bool // granted by the install, as the chart's RBAC documents
}{
	{"create OpenBao CRs in the operator namespace", []string{"create", "openbaopolicies.security.mto.stakater.com", "-n", operatorNSPlaceholder}, true},
	{"create OpenBao CRs in another namespace", []string{"create", "openbaopolicies.security.mto.stakater.com", "-n", "default"}, false},
	{"list OpenBao CRs cluster-wide", []string{"list", "openbaopolicies.security.mto.stakater.com", "--all-namespaces"}, true},
	{"create ConfigMaps in a tenant namespace", []string{"create", "configmaps", "-n", nsAlphaDev}, true},
	{"create Secrets in a tenant namespace", []string{"create", "secrets", "-n", nsAlphaDev}, false},
	{"delete Secrets in a tenant namespace", []string{"delete", "secrets", "-n", nsAlphaDev}, true},
	{"create Bundles (cluster-scoped)", []string{"create", "bundles.trust.cert-manager.io"}, true},
	{"create Issuers in a tenant namespace", []string{"create", "issuers.cert-manager.io", "-n", nsAlphaDev}, true},
	{"create SecretStores in a tenant namespace", []string{"create", "secretstores.external-secrets.io", "-n", nsAlphaDev}, true},
	{"list Tenants", []string{"list", "tenants.tenantoperator.stakater.com"}, true},
	{"delete Tenants", []string{"delete", "tenants.tenantoperator.stakater.com"}, false},
	{"mint a token for bao-cert-manager", []string{"create", "serviceaccounts/bao-cert-manager", "--subresource=token", "-n", nsAlphaDev}, true},
	{"mint a token for any other ServiceAccount", []string{"create", "serviceaccounts/default", "--subresource=token", "-n", nsAlphaDev}, false},
}

// operatorNSPlaceholder is substituted at probe time; the table is built before
// TestMain has read the environment.
const operatorNSPlaceholder = "<operatorNS>"

func rbacSnapshot(t *testing.T) map[string]string {
	t.Helper()
	if tov2SA == "" {
		return nil
	}
	snap := map[string]string{}
	for _, p := range rbacProbes {
		snap[p.desc] = canI(t, tov2SA, probeArgs(p.args))
	}
	return snap
}

func probeArgs(args []string) []string {
	out := make([]string, len(args))
	for i, a := range args {
		if a == operatorNSPlaceholder {
			a = operatorNS
		}
		out[i] = a
	}
	return out
}

func rbacDelta(t *testing.T, before map[string]string) {
	t.Helper()
	if before == nil {
		t.Skip("set E2E_TOV2_SA to system:serviceaccount:<ns>:<name> to measure the chart's RBAC delta")
	}
	for _, p := range rbacProbes {
		after := canI(t, tov2SA, probeArgs(p.args))
		newlyGranted := before[p.desc] == "no" && after == "yes"
		if newlyGranted && !p.want {
			t.Errorf("the chart granted %q, which it must not", p.desc)
		}
		if p.want && before[p.desc] == "no" && !newlyGranted {
			t.Errorf("the chart failed to grant %q", p.desc)
		}
		t.Logf("  %-48s before=%-3s after=%-3s", p.desc, before[p.desc], after)
	}
}

// ------------------------------------------------------------------ helpers

func labelledNamespaces(tenant string) []string {
	var out []string
	for ns, owner := range fixtureNamespaces {
		if owner == tenant {
			out = append(out, ns)
		}
	}
	sort.Strings(out)
	return out
}

func names(items []unstructured.Unstructured) []string {
	out := make([]string, 0, len(items))
	for _, i := range items {
		out = append(out, i.GetName())
	}
	sort.Strings(out)
	return out
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
