package e2e

import (
	"encoding/json"
	"os/exec"
	"strings"
	"testing"
)

// The suite reaches OpenBao through the `bao` CLI that ships in the OpenBao pod,
// over `kubectl exec`. No port-forward, no extra image, and the same path an
// operator debugging the cluster would use. Dev mode's root token is "root".
//
// Two token rules. The ROOT token is only ever used to inspect state — which
// namespaces, mounts and policies exist, what a secret holds. Anything that
// asserts what a WORKLOAD can do runs with a token that workload obtained by
// logging in with its own ServiceAccount JWT (baoLogin), so a permission the
// chart failed to grant, or granted too widely, fails here rather than being
// papered over by root.

const baoRootToken = "root"

// baoRun runs `bao args...` inside the OpenBao pod. token "" sends no
// BAO_TOKEN (login is unauthenticated); ns "" is bao's root namespace. Returns
// stdout; stderr travels in the error so a refused request says why.
func baoRun(t *testing.T, token, ns string, args ...string) (string, error) {
	t.Helper()
	env := []string{"env"}
	if token != "" {
		env = append(env, "BAO_TOKEN="+token)
	}
	if ns != "" {
		env = append(env, "BAO_NAMESPACE="+ns)
	}
	full := append([]string{"--context", kubeContext, "-n", baoNS, "exec", "-i", baoPod, "--"}, env...)
	full = append(full, "bao")
	full = append(full, args...)
	cmd := exec.Command(kubectlBin(), full...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return string(out), &baoError{args: args, ns: ns, stderr: stderr.String(), err: err}
	}
	return string(out), nil
}

type baoError struct {
	args   []string
	ns     string
	stderr string
	err    error
}

func (e *baoError) Error() string {
	return "bao " + strings.Join(e.args, " ") + " (namespace " + e.ns + "): " + e.err.Error() + "\n" + strings.TrimSpace(e.stderr)
}

// bao runs as root in the root namespace and fails the test on any error.
func bao(t *testing.T, args ...string) string {
	t.Helper()
	return baoIn(t, "", args...)
}

// baoIn runs as root in the given bao namespace and fails the test on any error.
func baoIn(t *testing.T, ns string, args ...string) string {
	t.Helper()
	out, err := baoRun(t, baoRootToken, ns, args...)
	if err != nil {
		t.Fatalf("%v", err)
	}
	return out
}

// baoAs runs with a workload's token. Errors are returned, not fatal, because
// half the calls made with a workload token are supposed to be refused.
func baoAs(t *testing.T, token, ns string, args ...string) (string, error) {
	t.Helper()
	return baoRun(t, token, ns, args...)
}

func baoJSON(t *testing.T, out string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("bao output is not JSON: %v\n%s", err, out)
	}
	return m
}

func baoJSONList(t *testing.T, out string) []string {
	t.Helper()
	var l []string
	if err := json.Unmarshal([]byte(out), &l); err != nil {
		t.Fatalf("bao output is not a JSON list: %v\n%s", err, out)
	}
	return l
}

// baoLogin logs into the kubernetes auth mount of a bao namespace with a
// ServiceAccount JWT and returns the client token and the policies bao attached
// to it. This is exactly what a workload — or ESO on its behalf — does.
func baoLogin(t *testing.T, ns, role, jwt string) (token string, policies []string) {
	t.Helper()
	out, err := baoRun(t, "", ns, "write", "-format=json", "auth/kubernetes/login", "role="+role, "jwt="+jwt)
	if err != nil {
		t.Fatalf("login to %s as role %s: %v", ns, role, err)
	}
	auth, _ := baoJSON(t, out)["auth"].(map[string]any)
	token, _ = auth["client_token"].(string)
	if token == "" {
		t.Fatalf("login to %s as role %s returned no client_token:\n%s", ns, role, out)
	}
	return token, strList(auth["token_policies"])
}

// baoTryLogin is baoLogin for the cases that must FAIL.
func baoTryLogin(t *testing.T, ns, role, jwt string) error {
	t.Helper()
	_, err := baoRun(t, "", ns, "write", "-format=json", "auth/kubernetes/login", "role="+role, "jwt="+jwt)
	return err
}

func baoNamespaces(t *testing.T) []string {
	t.Helper()
	return baoJSONList(t, bao(t, "namespace", "list", "-format=json"))
}

func baoPolicies(t *testing.T, ns string) []string {
	t.Helper()
	return baoJSONList(t, baoIn(t, ns, "policy", "list", "-format=json"))
}

// baoMounts returns the secret-engine mount points of a namespace, e.g. "kv/".
func baoMounts(t *testing.T, ns string) []string {
	t.Helper()
	m := baoJSON(t, baoIn(t, ns, "secrets", "list", "-format=json"))
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// baoKVGet reads one field of a KV v2 secret as the given token.
func baoKVGet(t *testing.T, token, ns, mount, path, field string) (string, error) {
	t.Helper()
	out, err := baoAs(t, token, ns, "kv", "get", "-format=json", "-mount="+mount, path)
	if err != nil {
		return "", err
	}
	data, _ := baoJSON(t, out)["data"].(map[string]any)
	inner, _ := data["data"].(map[string]any)
	v, _ := inner[field].(string)
	return v, nil
}
