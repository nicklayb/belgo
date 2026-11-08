{{/* Name of the chart, overridable. */}}
{{- define "belgo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified name of the release's resources. */}}
{{- define "belgo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Chart name and version, for the helm.sh/chart label. */}}
{{- define "belgo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels of every resource. */}}
{{- define "belgo.labels" -}}
helm.sh/chart: {{ include "belgo.chart" . }}
{{ include "belgo.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Labels selecting the pod. */}}
{{- define "belgo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "belgo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Image reference, tagged with the appVersion by default. */}}
{{- define "belgo.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* APP_HOST: explicit, else the first ingress / HTTPRoute host over https. */}}
{{- define "belgo.appHost" -}}
{{- if .Values.appHost }}
{{- .Values.appHost }}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts }}
{{- printf "https://%s" (first .Values.ingress.hosts).host }}
{{- else if and .Values.httpRoute.enabled .Values.httpRoute.hostnames }}
{{- printf "https://%s" (first .Values.httpRoute.hostnames) }}
{{- end }}
{{- end }}

{{/* Name of the claim holding /data. */}}
{{- define "belgo.claimName" -}}
{{- default (printf "%s-data" (include "belgo.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{/* Remote the init container clones. */}}
{{- define "belgo.cloneRemote" -}}
{{- default .Values.git.remote .Values.git.clone.remote }}
{{- end }}
