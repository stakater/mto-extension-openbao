package e2e

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Fixtures: the Tenants and namespaces the suite owns.
//
// multi-tenant-operator is not on this cluster (hack/e2e/README.md), so the
// suite plays MTO's part: it creates the Tenant CRs and the namespaces they
// declare, and puts the stakater.com/tenant label on them — which is the one
// thing the charts actually depend on MTO for. Owning that step is also what
// lets the suite model the window MTO itself creates, a Tenant whose namespaces
// exist but are not labelled yet, by simply not labelling one.
//
// Everything here is created before the tests run and removed afterwards; a
// leftover from a killed run is adopted rather than duplicated, so re-running
// against a still-up cluster works.

const (
	// The primary tenant: two namespaces, every opt-in the suite exercises.
	tenantAlpha = "e2e-alpha"
	// The peer: the target of alpha's cross-tenant shares, and the tenant the
	// suite deletes to prove what a Tenant deletion does and does not destroy.
	tenantBeta = "e2e-beta"
	// Declared with a namespace that is NOT labelled when the suite starts —
	// the state every new tenant is in until MTO labels its namespaces.
	tenantGamma = "e2e-gamma"

	nsAlphaDev   = "e2e-alpha-dev"
	nsAlphaTools = "e2e-alpha-tools"
	nsBetaAPI    = "e2e-beta-api"
	nsGammaAPI   = "e2e-gamma-api"
	// Carries no tenant label and an annotated ServiceAccount: the chart must
	// render nothing for it, anywhere.
	nsNoise = "e2e-unlabelled-noise"
)

// tenantNamespaces is what each Tenant declares under spec.namespaces.withTenantPrefix
// — the suffixes, as MTO takes them. The k8s namespace is <tenant>-<suffix>.
var tenantNamespaces = map[string][]string{
	tenantAlpha: {"dev", "tools"},
	tenantBeta:  {"api"},
	tenantGamma: {"api"},
}

// fixtureNamespaces is every namespace the suite creates and the tenant label
// it starts with ("" = unlabelled).
var fixtureNamespaces = map[string]string{
	nsAlphaDev:   tenantAlpha,
	nsAlphaTools: tenantAlpha,
	nsBetaAPI:    tenantBeta,
	nsGammaAPI:   "", // labelled by TestLifecycle, on purpose, later
	nsNoise:      "",
}

func allTenants() []string { return []string{tenantAlpha, tenantBeta, tenantGamma} }

func provisionFixtures() error {
	ctx := context.Background()
	if err := resetCluster(ctx); err != nil {
		return err
	}
	for _, name := range allTenants() {
		if err := applyTenant(ctx, name); err != nil {
			return fmt.Errorf("tenant %s: %w", name, err)
		}
	}
	for ns, owner := range fixtureNamespaces {
		if err := applyNamespace(ctx, ns, owner); err != nil {
			return fmt.Errorf("namespace %s: %w", ns, err)
		}
	}
	return nil
}

// teardownFixtures is best-effort: the suite has already reported by the time it
// runs, and a namespace that is slow to finalize must not turn a green run red.
// Best-effort still prints — this also runs from TestMain's provisioning-failure
// path, and whoever is looking at a broken cluster deserves to know what was left.
func teardownFixtures() {
	ctx := context.Background()
	for _, name := range allTenants() {
		if err := dyn.Resource(gvrTenant).Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
			fmt.Printf("teardown: deleting Tenant %s: %v\n", name, err)
		}
	}
	for ns := range fixtureNamespaces {
		if err := kube.CoreV1().Namespaces().Delete(ctx, ns, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
			fmt.Printf("teardown: deleting namespace %s: %v\n", ns, err)
		}
	}
}

// resetCluster puts the cluster back to "bootstrap chart not installed" before
// the first test runs. A run that is killed leaves a release, its parent
// TemplateInstance, the children and their OpenBao CRs; the next run would then
// fail in its first assertion on state it did not create. Order matters and is
// the order the README gives operators: parent TI first so the children drain
// while template-operator-v2 still has the RBAC to reap them, then the release.
func resetCluster(ctx context.Context) error {
	if _, err := dyn.Resource(gvrTemplateInstance).Namespace(operatorNS).Get(ctx, parentName, metav1.GetOptions{}); err == nil {
		fmt.Println("clearing an install left behind by an earlier run")
	} else if !apierrors.IsNotFound(err) {
		return fmt.Errorf("looking for a leftover parent TemplateInstance: %w", err)
	}
	if err := deleteTemplateInstances(ctx); err != nil {
		return err
	}
	// The match is helm's exact ErrReleaseNotFound text; a looser "not found"
	// would also swallow unrelated errors that merely contain those words.
	if out, err := exec.Command(helmBin(), "uninstall", releaseName, "--kube-context", kubeContext, "-n", operatorNS).CombinedOutput(); err != nil &&
		!strings.Contains(string(out), "release: not found") {
		fmt.Printf("uninstalling a leftover release: %v\n%s", err, out)
	}
	// Tenants last, by deletion rather than by patching what is there: a Tenant
	// left over from an earlier run can carry a different spec, and that changes
	// what the assertions see without changing what the chart did.
	return deleteFixtureTenants(ctx)
}

func deleteFixtureTenants(ctx context.Context) error {
	deadline := time.Now().Add(60 * time.Second)
	for _, name := range allTenants() {
		for {
			_, err := dyn.Resource(gvrTenant).Get(ctx, name, metav1.GetOptions{})
			if apierrors.IsNotFound(err) {
				break
			}
			if err != nil {
				return fmt.Errorf("reading Tenant %s: %w", name, err)
			}
			delErr := dyn.Resource(gvrTenant).Delete(ctx, name, metav1.DeleteOptions{})
			if time.Now().After(deadline) {
				return fmt.Errorf("Tenant %s could not be removed: %v", name, delErr)
			}
			time.Sleep(2 * time.Second)
		}
	}
	return nil
}

// deleteTemplateInstances removes every TemplateInstance under the chart's name
// prefix — the children AND the parent — and waits for them to go. The prefix
// is a naming convention, not ownership: any other install of this chart in the
// namespace would be swept too, which is fine on a dedicated e2e cluster and
// wrong anywhere else. A TemplateInstance whose operator can no longer reach
// its objects holds its finalizer for ever, so after the deadline the finalizer
// is cleared — loudly.
func deleteTemplateInstances(ctx context.Context) error {
	deadline := time.Now().Add(3 * time.Minute)
	var lastErr error
	for {
		list, err := dyn.Resource(gvrTemplateInstance).Namespace(operatorNS).List(ctx, metav1.ListOptions{})
		if err != nil {
			return fmt.Errorf("listing leftover TemplateInstances: %w", err)
		}
		remaining := 0
		for i := range list.Items {
			item := list.Items[i]
			if !strings.HasPrefix(item.GetName(), tiPrefix) {
				continue
			}
			remaining++
			if item.GetDeletionTimestamp() == nil {
				if err := dyn.Resource(gvrTemplateInstance).Namespace(operatorNS).Delete(ctx, item.GetName(), metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
					lastErr = fmt.Errorf("deleting TemplateInstance %s: %w", item.GetName(), err)
				}
				continue
			}
			if time.Now().After(deadline) && len(item.GetFinalizers()) > 0 {
				fmt.Printf("unwedging TemplateInstance %s: stuck on finalizers %v from an earlier run\n", item.GetName(), item.GetFinalizers())
				item.SetFinalizers(nil)
				if _, err := dyn.Resource(gvrTemplateInstance).Namespace(operatorNS).Update(ctx, &item, metav1.UpdateOptions{}); err != nil {
					lastErr = fmt.Errorf("clearing finalizers on TemplateInstance %s: %w", item.GetName(), err)
				}
			}
		}
		if remaining == 0 {
			return nil
		}
		if time.Now().After(deadline.Add(30 * time.Second)) {
			if lastErr != nil {
				return fmt.Errorf("%d leftover TemplateInstances could not be removed; last error: %w", remaining, lastErr)
			}
			return fmt.Errorf("%d leftover TemplateInstances could not be removed", remaining)
		}
		time.Sleep(3 * time.Second)
	}
}

// applyTenant creates the Tenant at v1beta3 — the version the parent's
// objectFieldRef reads. spec.quota is the only required field; nothing here
// dereferences it (no MTO means no Quota controller), but the API server
// rejects a Tenant without it. spec.namespaces is what the parent gotemplate
// gates on: a Tenant declaring none gets no child TemplateInstance at all.
func applyTenant(ctx context.Context, name string) error {
	suffixes := make([]any, 0, len(tenantNamespaces[name]))
	for _, s := range tenantNamespaces[name] {
		suffixes = append(suffixes, s)
	}
	obj := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": gvrTenant.Group + "/" + gvrTenant.Version,
		"kind":       "Tenant",
		"metadata":   map[string]any{"name": name},
		"spec": map[string]any{
			"quota": "e2e-quota",
			"namespaces": map[string]any{
				"withTenantPrefix": suffixes,
			},
		},
	}}
	_, err := dyn.Resource(gvrTenant).Create(ctx, obj, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		existing, err := dyn.Resource(gvrTenant).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return err
		}
		existing.Object["spec"] = obj.Object["spec"]
		_, err = dyn.Resource(gvrTenant).Update(ctx, existing, metav1.UpdateOptions{})
		return err
	}
	return err
}

// applyNamespace creates the namespace with the given tenant label ("" for
// none). An existing namespace is adopted and its label corrected — unless it
// is still Terminating from a previous teardown, in which case it is waited out
// first, because a namespace that is going away cannot be relabelled and a
// Create against it fails with AlreadyExists.
func applyNamespace(ctx context.Context, name, tenant string) error {
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name}}
	if tenant != "" {
		ns.Labels = map[string]string{tenantLabel: tenant}
	}
	for {
		_, err := kube.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{})
		if !apierrors.IsAlreadyExists(err) {
			return err
		}
		existing, err := kube.CoreV1().Namespaces().Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			continue
		}
		if err != nil {
			return err
		}
		if existing.DeletionTimestamp != nil {
			fmt.Printf("namespace %s is still terminating from an earlier run; waiting\n", name)
			if err := waitForNamespaceGone(name); err != nil {
				return err
			}
			continue
		}
		if existing.Labels[tenantLabel] == tenant {
			return nil
		}
		if existing.Labels == nil {
			existing.Labels = map[string]string{}
		}
		if tenant == "" {
			delete(existing.Labels, tenantLabel)
		} else {
			existing.Labels[tenantLabel] = tenant
		}
		_, err = kube.CoreV1().Namespaces().Update(ctx, existing, metav1.UpdateOptions{})
		return err
	}
}

func waitForNamespaceGone(name string) error {
	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		_, err := kube.CoreV1().Namespaces().Get(context.Background(), name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("namespace %s still present after 3m", name)
}
