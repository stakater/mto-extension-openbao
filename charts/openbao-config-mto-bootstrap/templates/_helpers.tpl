{{/*
Drift-protection block (t-op-v2 Template spec.sync) rendered from
.Values.sync. sync.mode is validated against off|revert|strict at render
time (unquoted YAML booleans like `on` arrive here as bool true). Emits
nothing when mode is "off" so opted-out installs render byte-identical to
charts without this block. Include in every Template this chart installs:

  {{- with include "openbao-config-mto-bootstrap.templateSync" . }}
  {{- . | nindent 2 }}
  {{- end }}
*/}}
{{- define "openbao-config-mto-bootstrap.templateSync" -}}
{{- $sync := .Values.sync | default dict -}}
{{- $mode := $sync.mode | default "off" | toString -}}
{{- if not (has $mode (list "off" "revert" "strict")) -}}
{{- fail (printf "sync.mode must be one of off, revert, strict — got %q (unquoted on/yes/true parse as YAML booleans; quote the value)" $mode) -}}
{{- end -}}
{{- if ne $mode "off" -}}
sync:
  mode: {{ $mode }}
{{- with $sync.ignoreFields }}
  ignoreFields:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end -}}
{{- end -}}
