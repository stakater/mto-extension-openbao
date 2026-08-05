// Apiserver-acceptance validator for rendered chart output, used by
// hack/chart-render-tests.sh (check `apiserver`).
//
// Decodes each document through sigs.k8s.io/yaml — the path client-go and the
// apiserver use (YAML 1.1 via go-yaml v2) — then runs apimachinery's own
// validators over names, labels and ConfigMap keys. A value like `no` fails
// here exactly as on a real cluster; yq (go-yaml v3) cannot reproduce that.
package main

import (
	"fmt"
	"os"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/util/validation"
	"sigs.k8s.io/yaml"
)

func main() {
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Println("READ-ERROR", err)
		os.Exit(2)
	}
	var problems []string
	seen := map[string]int{}
	docs := strings.Split(string(raw), "\n---")
	objects := 0
	for i, d := range docs {
		if strings.TrimSpace(stripComments(d)) == "" {
			continue
		}
		// 1. Typed decode of ConfigMaps: labels/annotations/data are
		// map[string]string, so any YAML-coerced scalar fails here.
		var probe struct {
			Kind string `json:"kind"`
		}
		if err := yaml.Unmarshal([]byte(d), &probe); err != nil {
			problems = append(problems, fmt.Sprintf("doc %d: kind probe failed: %v", i, err))
			continue
		}
		if probe.Kind == "" {
			continue
		}
		objects++
		if probe.Kind == "ConfigMap" {
			var cm corev1.ConfigMap
			if err := yaml.Unmarshal([]byte(d), &cm); err != nil {
				problems = append(problems, fmt.Sprintf("doc %d (ConfigMap): TYPED DECODE FAILED (apiserver would reject): %v", i, err))
				continue
			}
			for k := range cm.Data {
				if msgs := validation.IsConfigMapKey(k); len(msgs) > 0 {
					problems = append(problems, fmt.Sprintf("%s/%s: invalid data key %q: %s", cm.Namespace, cm.Name, k, strings.Join(msgs, "; ")))
				}
			}
		}
		// 2. Untyped decode for every kind, then apimachinery validation.
		var u unstructured.Unstructured
		if err := yaml.Unmarshal([]byte(d), &u.Object); err != nil {
			problems = append(problems, fmt.Sprintf("doc %d (%s): decode failed: %v", i, probe.Kind, err))
			continue
		}
		name, ns := u.GetName(), u.GetNamespace()
		if msgs := validation.IsDNS1123Subdomain(name); len(msgs) > 0 {
			problems = append(problems, fmt.Sprintf("%s %s/%s: invalid metadata.name: %s", probe.Kind, ns, name, strings.Join(msgs, "; ")))
		}
		if ns != "" {
			if msgs := validation.IsDNS1123Label(ns); len(msgs) > 0 {
				problems = append(problems, fmt.Sprintf("%s %s/%s: invalid namespace: %s", probe.Kind, ns, name, strings.Join(msgs, "; ")))
			}
		}
		// metadata.labels typed as map[string]interface{} in unstructured:
		// a coerced bool/number shows up as a non-string value here.
		if md, ok := u.Object["metadata"].(map[string]interface{}); ok {
			for field := range map[string]bool{"labels": true, "annotations": true} {
				if raw, ok := md[field]; ok {
					m, ok := raw.(map[string]interface{})
					if !ok {
						problems = append(problems, fmt.Sprintf("%s %s/%s: metadata.%s is not a map", probe.Kind, ns, name, field))
						continue
					}
					for k, v := range m {
						sv, ok := v.(string)
						if !ok {
							problems = append(problems, fmt.Sprintf("%s %s/%s: metadata.%s[%q] decoded as %T (%v), not string — YAML coercion; apiserver rejects", probe.Kind, ns, name, field, k, v, v))
							continue
						}
						if msgs := validation.IsQualifiedName(k); len(msgs) > 0 {
							problems = append(problems, fmt.Sprintf("%s %s/%s: invalid %s key %q: %s", probe.Kind, ns, name, field, k, strings.Join(msgs, "; ")))
						}
						if field == "labels" {
							if msgs := validation.IsValidLabelValue(sv); len(msgs) > 0 {
								problems = append(problems, fmt.Sprintf("%s %s/%s: invalid label value %q for %q: %s", probe.Kind, ns, name, sv, k, strings.Join(msgs, "; ")))
							}
						}
					}
				}
			}
		}
		id := fmt.Sprintf("%s|%s|%s|%s", u.GetAPIVersion(), probe.Kind, ns, name)
		seen[id]++
	}
	for id, n := range seen {
		if n > 1 {
			problems = append(problems, fmt.Sprintf("DUPLICATE object identity rendered %d times: %s", n, id))
		}
	}
	fmt.Printf("objects=%d problems=%d\n", objects, len(problems))
	for _, p := range problems {
		fmt.Println("  PROBLEM:", p)
	}
	if len(problems) > 0 {
		os.Exit(1)
	}
}

func stripComments(s string) string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "#") {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}
