// Package e2e drives the two charts against a live cluster running
// template-operator-v2, the openbao-config-operator and OpenBao, with
// cert-manager, trust-manager and External Secrets alongside.
//
// It is the only layer where anything reconciles. hack/chart-render-tests.sh
// proves what the templates PRODUCE and `make crd-validate` proves the API
// server would ACCEPT it; neither can say what template-operator-v2 does with a
// Tenant, what the operator then writes into bao, or whether a workload's
// ServiceAccount can afterwards log in and read its own secret — and not its
// neighbour's. Every assertion here is one of those.
//
//	make e2e-kind
//
// builds the cluster (hack/e2e/README.md lists what goes on it and why) and runs
// this suite with every variable below set. To iterate against a cluster that
// is already up, `make e2e-up` once, then `make e2e-test` with the same
// variables e2e-kind passes — docs/e2e.md spells them out.
//
// Variables:
//
//	E2E=1                 the gate; without it the package exits 0 having run nothing
//	KUBE_CONTEXT          required — the suite refuses the ambient current-context,
//	                      because it installs, deletes and relabels real objects
//	E2E_CHART_REPO_URL    required — where template-operator-v2 pulls THIS checkout's
//	                      tenant chart from. Without it the bootstrap would point at
//	                      ghcr.io and the suite would silently test the last release
//	E2E_OPERATOR_NAMESPACE, E2E_BAO_NAMESPACE, E2E_BAO_POD  defaults match e2e-kind
//	E2E_TOV2_SA           template-operator-v2's ServiceAccount as
//	                      system:serviceaccount:<ns>:<name>. Sets the bootstrap's
//	                      templateOperator.* values and drives the RBAC delta;
//	                      unset leaves the chart defaults and skips that check
//	E2E_WAIT_TIMEOUT      per-wait budget (Go duration, default 4m) for a loaded runner
//
// The suite installs the bootstrap chart with the CHART DEFAULTS plus exactly
// the toggles it exercises (cert-manager Issuers and cross-tenant trust, both
// off by default), and points openbaoConfigMto.registry at the in-cluster repo.
// SSO is not covered: it needs an OIDC provider, and nothing here stands one up.
package e2e

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	authenticationv1 "k8s.io/api/authentication/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	// The release name the charts README documents.
	releaseName = "openbao-config-mto-bootstrap"
	parentName  = "openbao-config-mto-parent"
	// Every TemplateInstance the bootstrap chart's parent emits is
	// openbao-config-mto-<tenant>[.eso|.certmanager|.trust]; the parent itself is
	// openbao-config-mto-parent. One prefix covers them all.
	tiPrefix = "openbao-config-mto-"

	// The chart's tenantLabelKey default. The suite labels the namespaces it
	// creates with it and never overrides the value in the chart, so a change to
	// one without the other fails loudly here.
	tenantLabel = "stakater.com/tenant"
	annPrefix   = "bao.stakater.com/"
	// The bootstrap's parent.env default; it is a segment of every KV path.
	env = "dev"
	// Where the parent puts cross-tenant shares (parent.sharedTenantName default).
	sharedNS = "shared/"
)

var (
	kubeContext  string
	operatorNS   string
	baoNS        string
	baoPod       string
	chartRepoURL string
	tov2SA       string

	dyn  dynamic.Interface
	kube kubernetes.Interface
	ctx  = context.Background()
)

// GroupVersionResources, spelled out once. Unstructured needs them on every
// call, and spelling them at call sites is where typos hide.
var (
	gvrTemplateInstance = schema.GroupVersionResource{Group: "templates.v2.stakater.com", Version: "v2alpha1", Resource: "templateinstances"}
	gvrTemplate         = schema.GroupVersionResource{Group: "templates.v2.stakater.com", Version: "v2alpha1", Resource: "templates"}
	gvrTenant           = schema.GroupVersionResource{Group: "tenantoperator.stakater.com", Version: "v1beta3", Resource: "tenants"}

	gvrBaoNamespace  = baoGVR("openbaonamespaces")
	gvrSecretEngine  = baoGVR("openbaosecretengines")
	gvrAuthMethod    = baoGVR("openbaoauthmethods")
	gvrK8sAuthConfig = baoGVR("openbaokubernetesauthengineconfigs")
	gvrK8sAuthRole   = baoGVR("openbaokubernetesauthroles")
	gvrPolicy        = baoGVR("openbaopolicies")
	gvrTransitKey    = baoGVR("openbaotransitkeys")
	gvrPKIConfig     = baoGVR("openbaopkisecretengineconfigs")
	gvrPKIRole       = baoGVR("openbaopkisecretengineroles")

	gvrSecretStore    = schema.GroupVersionResource{Group: "external-secrets.io", Version: "v1", Resource: "secretstores"}
	gvrExternalSecret = schema.GroupVersionResource{Group: "external-secrets.io", Version: "v1", Resource: "externalsecrets"}
	gvrIssuer         = schema.GroupVersionResource{Group: "cert-manager.io", Version: "v1", Resource: "issuers"}
	gvrCertificate    = schema.GroupVersionResource{Group: "cert-manager.io", Version: "v1", Resource: "certificates"}
	gvrBundle         = schema.GroupVersionResource{Group: "trust.cert-manager.io", Version: "v1alpha1", Resource: "bundles"}
)

func baoGVR(resource string) schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: "security.mto.stakater.com", Version: "v1alpha1", Resource: resource}
}

func TestMain(m *testing.M) {
	if os.Getenv("E2E") == "" {
		println("e2e SKIPPED: set E2E=1 (see the package comment for the other variables)")
		os.Exit(0)
	}
	kubeContext = os.Getenv("KUBE_CONTEXT")
	if kubeContext == "" {
		println("e2e requires KUBE_CONTEXT — refusing to use the ambient current-context")
		os.Exit(1)
	}
	chartRepoURL = os.Getenv("E2E_CHART_REPO_URL")
	if chartRepoURL == "" {
		println("e2e requires E2E_CHART_REPO_URL — the in-cluster repo serving this checkout's tenant chart (make e2e-chart-repo)")
		os.Exit(1)
	}
	operatorNS = envOr("E2E_OPERATOR_NAMESPACE", "openbao-config-operator-system")
	baoNS = envOr("E2E_BAO_NAMESPACE", "openbao")
	baoPod = envOr("E2E_BAO_POD", "openbao-0")
	tov2SA = os.Getenv("E2E_TOV2_SA")

	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		clientcmd.NewDefaultClientConfigLoadingRules(),
		&clientcmd.ConfigOverrides{CurrentContext: kubeContext},
	).ClientConfig()
	if err != nil {
		println("kubeconfig:", err.Error())
		os.Exit(1)
	}
	if dyn, err = dynamic.NewForConfig(cfg); err != nil {
		println("dynamic client:", err.Error())
		os.Exit(1)
	}
	if kube, err = kubernetes.NewForConfig(cfg); err != nil {
		println("clientset:", err.Error())
		os.Exit(1)
	}

	// Fixtures are built once for the whole package: they stand in for what MTO
	// would have created, and every test treats them as pre-existing. Torn down
	// explicitly because os.Exit skips defers.
	if err := provisionFixtures(); err != nil {
		println("provisioning fixtures:", err.Error())
		teardownFixtures()
		os.Exit(1)
	}
	code := m.Run()
	teardownFixtures()
	os.Exit(code)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ------------------------------------------------------------------ binaries

// helmBin is $HELM, which every Makefile target that runs this suite pins to
// the same binary the render tests use. A bare "helm" is the fallback for a
// hand-run `go test`, and the reason to prefer `make e2e-test`.
func helmBin() string    { return envOr("HELM", "helm") }
func kubectlBin() string { return envOr("KUBECTL", "kubectl") }

// chartDir is the bootstrap chart under test, resolved from this package's
// directory (Go runs a test binary with the working directory set to its
// package). It stats the path so a suite moved to another depth fails with
// "chart not found" rather than helm's generic path error.
func chartDir(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs("../../charts/openbao-config-mto-bootstrap")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(abs); err != nil {
		t.Fatalf("chart not found at %s — is this suite two levels under the repo root?: %v", abs, err)
	}
	return abs
}

// ---------------------------------------------------------------------- helm

// helmArgs are the values every install carries. operatorNamespace and the
// chart repo are the two things the suite MUST set; everything else stays at
// the chart default unless a test passes it explicitly, so the run exercises
// what a customer gets.
//
// The exception is templateOperator.{namespace,serviceAccountName}, which
// follow E2E_TOV2_SA when it is set. The chart default names the ServiceAccount
// of a `template-operator` release, and the public template-operator-v2 chart
// cannot be installed under that name (see TOV2_RELEASE in the Makefile). Taking
// both from the same variable the RBAC probes use means the grants the chart
// writes and the identity the probes ask about cannot disagree.
func helmArgs(extra ...string) []string {
	args := []string{
		"--kube-context", kubeContext,
		"-n", operatorNS,
		"--set", "operatorNamespace=" + operatorNS,
		"--set", "openbaoConfigMto.registry=" + chartRepoURL,
	}
	if ns, name, ok := splitServiceAccount(tov2SA); ok {
		args = append(args,
			"--set", "templateOperator.namespace="+ns,
			"--set", "templateOperator.serviceAccountName="+name,
		)
	}
	return append(args, extra...)
}

// splitServiceAccount parses system:serviceaccount:<namespace>:<name>.
func splitServiceAccount(subject string) (ns, name string, ok bool) {
	parts := strings.Split(subject, ":")
	if len(parts) != 4 || parts[0] != "system" || parts[1] != "serviceaccount" || parts[2] == "" || parts[3] == "" {
		return "", "", false
	}
	return parts[2], parts[3], true
}

func helmInstall(t *testing.T, extra ...string) {
	t.Helper()
	helmRun(t, append([]string{"install", releaseName, chartDir(t)}, helmArgs(extra...)...))
}

func helmRun(t *testing.T, args []string) {
	t.Helper()
	out, err := exec.Command(helmBin(), args...).CombinedOutput()
	if err != nil {
		t.Fatalf("helm %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

// helmUninstall tears the release down in the ORDER the charts README gives
// operators, and waits for each step. Both waits are load-bearing.
//
// The parent TemplateInstance goes first. `helm uninstall` would delete the RBAC
// and the TemplateInstances together; the RBAC goes immediately while every
// child then waits on a finalizer that needs that RBAC to reap its OpenBao CRs,
// so nothing completes. Deleting the parent first lets the children — and their
// CRs — drain while template-operator-v2 can still act.
//
// Then the Templates. `helm uninstall` returns as soon as the API server accepts
// the deletes, but template-operator-v2 holds a finalizer on its Templates, so
// they outlive the command by a few seconds and the next install fails with
// "exists and cannot be imported into the current release".
//
// Tolerates an already-gone release, so it can serve both as a test's last
// step and as its Cleanup.
func helmUninstall(t *testing.T) {
	t.Helper()
	if parent := get(t, gvrTemplateInstance, operatorNS, parentName); parent != nil {
		if err := dyn.Resource(gvrTemplateInstance).Namespace(operatorNS).Delete(ctx, parentName, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
			t.Logf("deleting the parent TemplateInstance: %v", err)
		}
	}
	waitFor(t, "the tenants' TemplateInstances to drain", func() bool { return len(templateInstances(t)) == 0 })

	if out, err := exec.Command(helmBin(), "uninstall", releaseName, "--kube-context", kubeContext, "-n", operatorNS).CombinedOutput(); err != nil &&
		!strings.Contains(string(out), "release: not found") {
		t.Logf("helm uninstall %s: %v\n%s", releaseName, err, out)
	}
	waitFor(t, "the Templates to be released", func() bool {
		list, err := dyn.Resource(gvrTemplate).Namespace(operatorNS).List(ctx, metav1.ListOptions{})
		if err != nil {
			t.Fatalf("listing Templates: %v", err)
		}
		for _, item := range list.Items {
			if strings.HasPrefix(item.GetName(), "openbao-config-mto") {
				return false
			}
		}
		return true
	})
}

// -------------------------------------------------------------- k8s objects

// get returns nil only for a genuinely ABSENT object; any other error fails the
// test. A nil return is this suite's universal "gone / reaped / never rendered"
// predicate, so swallowing a transient API error here would let every one of
// those assertions pass vacuously.
func get(t *testing.T, gvr schema.GroupVersionResource, ns, name string) *unstructured.Unstructured {
	t.Helper()
	obj, err := dyn.Resource(gvr).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		t.Fatalf("getting %s %s/%s: %v", gvr.Resource, ns, name, err)
	}
	return obj
}

// mustGet is get for callers that dereference the result: absence becomes a
// failure naming the object, not a nil-pointer panic burying the real cause.
func mustGet(t *testing.T, gvr schema.GroupVersionResource, ns, name string) *unstructured.Unstructured {
	t.Helper()
	obj := get(t, gvr, ns, name)
	if obj == nil {
		t.Fatalf("%s %s/%s not found", gvr.Resource, ns, name)
	}
	return obj
}

func list(t *testing.T, gvr schema.GroupVersionResource, ns, selector string) []unstructured.Unstructured {
	t.Helper()
	l, err := dyn.Resource(gvr).Namespace(ns).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		t.Fatalf("listing %s in %q: %v", gvr.Resource, ns, err)
	}
	return l.Items
}

// templateInstances is every TemplateInstance the bootstrap chart's parent
// emitted — everything under the prefix except the parent itself.
func templateInstances(t *testing.T) []string {
	t.Helper()
	var names []string
	for _, item := range list(t, gvrTemplateInstance, operatorNS, "") {
		if n := item.GetName(); strings.HasPrefix(n, tiPrefix) && n != parentName {
			names = append(names, n)
		}
	}
	return names
}

// condition reads one status condition. ok is false when the object has no
// condition of that type at all — which is a different fact from "False".
func condition(obj *unstructured.Unstructured, typ string) (status, reason, message string, ok bool) {
	if obj == nil {
		return "", "", "", false
	}
	conds, _, _ := unstructured.NestedSlice(obj.Object, "status", "conditions")
	for _, c := range conds {
		cm, _ := c.(map[string]any)
		if cm["type"] != typ {
			continue
		}
		status, _ = cm["status"].(string)
		reason, _ = cm["reason"].(string)
		message, _ = cm["message"].(string)
		return status, reason, message, true
	}
	return "", "", "", false
}

func isReady(obj *unstructured.Unstructured) bool {
	s, _, _, _ := condition(obj, "Ready")
	return s == "True"
}

// describeCondition is what a timed-out wait prints: the condition the object
// actually carries, so the failure names the cause instead of just the wait.
func describeCondition(gvr schema.GroupVersionResource, ns, name string, obj *unstructured.Unstructured, typ string) string {
	if obj == nil {
		return fmt.Sprintf("%s %s/%s is absent", gvr.Resource, ns, name)
	}
	s, r, m, ok := condition(obj, typ)
	if !ok {
		return fmt.Sprintf("%s %s/%s has no %s condition yet", gvr.Resource, ns, name, typ)
	}
	return fmt.Sprintf("%s %s/%s: %s=%s reason=%s message=%q", gvr.Resource, ns, name, typ, s, r, m)
}

func waitReady(t *testing.T, gvr schema.GroupVersionResource, ns, name string) {
	t.Helper()
	waitCondition(t, gvr, ns, name, "Ready")
}

func waitCondition(t *testing.T, gvr schema.GroupVersionResource, ns, name, typ string) {
	t.Helper()
	waitState(t, fmt.Sprintf("%s %s/%s to be %s", gvr.Resource, ns, name, typ), func() string {
		obj := get(t, gvr, ns, name)
		if s, _, _, _ := condition(obj, typ); s == "True" {
			return ""
		}
		return describeCondition(gvr, ns, name, obj, typ)
	})
}

func waitGone(t *testing.T, gvr schema.GroupVersionResource, ns, name string) {
	t.Helper()
	waitState(t, fmt.Sprintf("%s %s/%s to be gone", gvr.Resource, ns, name), func() string {
		obj := get(t, gvr, ns, name)
		if obj == nil {
			return ""
		}
		if obj.GetDeletionTimestamp() != nil {
			return fmt.Sprintf("still terminating, finalizers %v", obj.GetFinalizers())
		}
		return "still present"
	})
}

// waitTimeout bounds every wait. Generous because these waits are for
// template-operator-v2 to pull a chart and render, then for the operator to
// talk to bao, and both balloon under CPU contention. E2E_WAIT_TIMEOUT
// overrides it for a loaded runner.
var waitTimeout = func() time.Duration {
	if v := os.Getenv("E2E_WAIT_TIMEOUT"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return 4 * time.Minute
}()

// waitState polls until state() returns "". On timeout the LAST state is in the
// failure: "timed out waiting for X" says nothing, "X: Ready=False reason=
// Forbidden message=..." says who to blame.
func waitState(t *testing.T, what string, state func() string) {
	t.Helper()
	deadline := time.Now().Add(waitTimeout)
	last := ""
	for time.Now().Before(deadline) {
		if last = state(); last == "" {
			return
		}
		time.Sleep(3 * time.Second)
	}
	t.Fatalf("timed out after %s waiting for %s; last state: %s (raise E2E_WAIT_TIMEOUT if the cluster is under load)", waitTimeout, what, last)
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	waitState(t, what, func() string {
		if cond() {
			return ""
		}
		return "not yet"
	})
}

func patchMerge(t *testing.T, gvr schema.GroupVersionResource, ns, name, patch string) {
	t.Helper()
	if _, err := dyn.Resource(gvr).Namespace(ns).Patch(ctx, name, types.MergePatchType, []byte(patch), metav1.PatchOptions{}); err != nil {
		t.Fatalf("patching %s %s/%s: %v", gvr.Resource, ns, name, err)
	}
}

func deleteObject(t *testing.T, gvr schema.GroupVersionResource, ns, name string) {
	t.Helper()
	if err := dyn.Resource(gvr).Namespace(ns).Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Fatalf("deleting %s %s/%s: %v", gvr.Resource, ns, name, err)
	}
}

// ------------------------------------------------------------ typed objects

func configMap(t *testing.T, ns, name string) *corev1.ConfigMap {
	t.Helper()
	cm, err := kube.CoreV1().ConfigMaps(ns).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		t.Fatalf("getting ConfigMap %s/%s: %v", ns, name, err)
	}
	return cm
}

func waitConfigMap(t *testing.T, ns, name string) *corev1.ConfigMap {
	t.Helper()
	var cm *corev1.ConfigMap
	waitFor(t, "ConfigMap "+ns+"/"+name+" to be rendered", func() bool { cm = configMap(t, ns, name); return cm != nil })
	return cm
}

func secret(t *testing.T, ns, name string) *corev1.Secret {
	t.Helper()
	s, err := kube.CoreV1().Secrets(ns).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		t.Fatalf("getting Secret %s/%s: %v", ns, name, err)
	}
	return s
}

// setServiceAccount creates the ServiceAccount or replaces its bao annotations
// wholesale — nil removes every bao.stakater.com/ key, which is how a workload
// opts back out. Keys are given without the prefix.
func setServiceAccount(t *testing.T, ns, name string, ann map[string]string) {
	t.Helper()
	full := map[string]string{}
	for k, v := range ann {
		full[annPrefix+k] = v
	}
	sa, err := kube.CoreV1().ServiceAccounts(ns).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		if _, err := kube.CoreV1().ServiceAccounts(ns).Create(ctx, &corev1.ServiceAccount{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Annotations: full},
		}, metav1.CreateOptions{}); err != nil {
			t.Fatalf("creating ServiceAccount %s/%s: %v", ns, name, err)
		}
		return
	}
	if err != nil {
		t.Fatalf("getting ServiceAccount %s/%s: %v", ns, name, err)
	}
	for k := range sa.Annotations {
		if strings.HasPrefix(k, annPrefix) {
			delete(sa.Annotations, k)
		}
	}
	if sa.Annotations == nil {
		sa.Annotations = map[string]string{}
	}
	for k, v := range full {
		sa.Annotations[k] = v
	}
	if _, err := kube.CoreV1().ServiceAccounts(ns).Update(ctx, sa, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("updating ServiceAccount %s/%s: %v", ns, name, err)
	}
}

// setDeployment creates a Deployment carrying the given bao annotations. Zero
// replicas: the chart reads the Deployment OBJECT (annotations and
// serviceAccountName), so no pod needs to run, and none does.
func setDeployment(t *testing.T, ns, name, sa string, ann map[string]string) {
	t.Helper()
	full := map[string]string{}
	for k, v := range ann {
		full[annPrefix+k] = v
	}
	var zero int32
	labels := map[string]string{"app": name}
	dep := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Annotations: full},
		Spec: appsv1.DeploymentSpec{
			Replicas: &zero,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					ServiceAccountName: sa,
					Containers:         []corev1.Container{{Name: "app", Image: "registry.k8s.io/pause:3.10"}},
				},
			},
		},
	}
	_, err := kube.AppsV1().Deployments(ns).Create(ctx, dep, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		existing, err := kube.AppsV1().Deployments(ns).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			t.Fatalf("getting Deployment %s/%s: %v", ns, name, err)
		}
		existing.Annotations = full
		existing.Spec.Template.Spec.ServiceAccountName = sa
		_, err = kube.AppsV1().Deployments(ns).Update(ctx, existing, metav1.UpdateOptions{})
	}
	if err != nil {
		t.Fatalf("applying Deployment %s/%s: %v", ns, name, err)
	}
}

// saToken mints a short-lived ServiceAccount token the way a pod would receive
// one — the API server's default audience, which is what the rendered
// kubernetes-auth roles accept.
func saToken(t *testing.T, ns, name string) string {
	t.Helper()
	ttl := int64(600)
	tr, err := kube.CoreV1().ServiceAccounts(ns).CreateToken(ctx, name, &authenticationv1.TokenRequest{
		Spec: authenticationv1.TokenRequestSpec{ExpirationSeconds: &ttl},
	}, metav1.CreateOptions{})
	if err != nil {
		t.Fatalf("minting a token for %s/%s: %v", ns, name, err)
	}
	return tr.Status.Token
}

func labelNamespace(t *testing.T, name, tenant string) {
	t.Helper()
	ns, err := kube.CoreV1().Namespaces().Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("getting namespace %s: %v", name, err)
	}
	if ns.Labels == nil {
		ns.Labels = map[string]string{}
	}
	ns.Labels[tenantLabel] = tenant
	if _, err := kube.CoreV1().Namespaces().Update(ctx, ns, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("labelling namespace %s: %v", name, err)
	}
}

func createNamespace(t *testing.T, name, tenant string) {
	t.Helper()
	if err := applyNamespace(ctx, name, tenant); err != nil {
		t.Fatalf("creating namespace %s: %v", name, err)
	}
}

func deleteNamespace(t *testing.T, name string) {
	t.Helper()
	if err := kube.CoreV1().Namespaces().Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Logf("deleting namespace %s: %v", name, err)
	}
}

// createCertificate asks cert-manager for a certificate through a rendered
// Issuer, the way an app team would. Short duration: bao caps it at the role's
// TTL anyway, and cert-manager's 90-day default would exceed maxTtl.
func createCertificate(t *testing.T, ns, name, issuer, dnsName string) {
	t.Helper()
	obj := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "cert-manager.io/v1",
		"kind":       "Certificate",
		"metadata":   map[string]any{"name": name, "namespace": ns},
		"spec": map[string]any{
			"secretName":  name,
			"commonName":  dnsName,
			"dnsNames":    []any{dnsName},
			"duration":    "24h",
			"renewBefore": "1h",
			"issuerRef":   map[string]any{"name": issuer, "kind": "Issuer"},
		},
	}}
	if _, err := dyn.Resource(gvrCertificate).Namespace(ns).Create(ctx, obj, metav1.CreateOptions{}); err != nil && !apierrors.IsAlreadyExists(err) {
		t.Fatalf("creating Certificate %s/%s: %v", ns, name, err)
	}
}

// ------------------------------------------------------------------- kubectl

// canI returns "yes" or "no" and fails the test on anything else. `kubectl auth
// can-i` exits non-zero when the answer is "no", so a non-zero exit is only an
// error if the output is not one of the two words — and the verdict is the LAST
// line, because kubectl prefixes warnings (probing a cluster-scoped resource
// without -n emits one) to the same stream.
func canI(t *testing.T, sa string, args []string) string {
	t.Helper()
	full := append([]string{"--context", kubeContext, "auth", "can-i"}, args...)
	full = append(full, "--as="+sa)
	out, err := exec.Command(kubectlBin(), full...).CombinedOutput()
	answer := ""
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if l := strings.TrimSpace(line); l != "" {
			answer = l
		}
	}
	switch answer {
	case "yes", "no":
		return answer
	}
	t.Fatalf("kubectl auth can-i %v: unusable answer %q (err: %v)", args, answer, err)
	return ""
}

// ----------------------------------------------------------------- x509 / misc

func parseCert(t *testing.T, pemText string) *x509.Certificate {
	t.Helper()
	block, _ := pem.Decode([]byte(strings.TrimSpace(pemText)))
	if block == nil {
		t.Fatalf("not a PEM certificate:\n%s", pemText)
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatalf("parsing certificate: %v", err)
	}
	return cert
}

// parseCerts parses a PEM bundle, the shape trust-manager writes.
func parseCerts(t *testing.T, pemText string) []*x509.Certificate {
	t.Helper()
	var certs []*x509.Certificate
	rest := []byte(pemText)
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			return certs
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			t.Fatalf("parsing a certificate in the bundle: %v", err)
		}
		certs = append(certs, cert)
	}
}

func strList(v any) []string {
	l, _ := v.([]any)
	out := make([]string, 0, len(l))
	for _, i := range l {
		s, _ := i.(string)
		out = append(out, s)
	}
	return out
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}

// schemaGVR is a short alias for tables of (resource, name) pairs.
type schemaGVR = schema.GroupVersionResource

var (
	listAll    = metav1.ListOptions{}
	updateOpts = metav1.UpdateOptions{}
)
