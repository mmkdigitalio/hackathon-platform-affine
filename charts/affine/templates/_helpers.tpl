{{- define "affine.labels" -}}
app.kubernetes.io/name: affine
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "affine.selectorLabels" -}}
app.kubernetes.io/name: affine
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "affine.image" -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end }}

{{/* Blobs and the server's private key live on the volume; config.json comes from the ConfigMap. */}}
{{- define "affine.volumeMounts" -}}
- name: data
  mountPath: /root/.affine/storage
  subPath: storage
- name: data
  mountPath: /root/.affine/config
  subPath: config
- name: config
  mountPath: /root/.affine/config/config.json
  subPath: config.json
  readOnly: true
{{- end }}

{{/* Settings the platform decides; config.json can add to them via affine.config. */}}
{{- define "affine.config" -}}
{{- $defaults := dict
  "server" (dict "name" "MMK DIGITAL AFFiNE")
  "auth" (dict "allowSignup" false "allowSignupForOauth" false)
  "indexer" (dict "enabled" false)
-}}
{{- mustMergeOverwrite $defaults (deepCopy (.Values.affine.config | default dict)) | toPrettyJson }}
{{- end }}
