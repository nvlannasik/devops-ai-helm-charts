{{/*
Shared helpers. Helm merges every chart's templates into one namespace, so these are
callable from the subcharts too — that is what keeps three near-identical Deployments
from carrying three copies of the same label and env plumbing.

Every helper takes the CALLING chart's context ($ or .) and reads .Chart / .Values from
it, so the same definition renders correctly whichever subchart invokes it.
*/}}

{{- define "devops-ai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fullname. Unlike the common Helm idiom, the release name is NOT prefixed by default:
these workloads are addressed by name across repos — MCP_HTTP_URL in the agent points at
the mcp-server Service, and a release-prefixed name would silently break that link on any
release not called "devops". Set fullnameOverride to opt out.
*/}}
{{- define "devops-ai.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "devops-ai.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "devops-ai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "devops-ai.labels" -}}
helm.sh/chart: {{ include "devops-ai.chart" . }}
{{ include "devops-ai.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: devops-ai-stack
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "devops-ai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devops-ai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "devops-ai.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "devops-ai.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. A digest wins over a tag when both are set — pinning by digest is the
only way an image reference is actually immutable, and silently preferring the tag would
defeat someone who went to the trouble.
*/}}
{{- define "devops-ai.image" -}}
{{- $img := .Values.image -}}
{{- $registry := $img.registry | default "docker.io" -}}
{{- if $img.digest -}}
{{- printf "%s/%s@%s" $registry $img.repository $img.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $img.repository ($img.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
Env rendering. Three sources, in ascending precedence:
  .Values.env        map  name -> value          (plain, stringified)
  .Values.secretEnv  map  name -> {secret,key,optional}
  .Values.extraEnv   list of raw core/v1 EnvVar  (escape hatch; passed through as-is)

Maps rather than lists because these values get patched by Kustomize overlays, and a
strategic merge on a list of {name,value} objects replaces the whole list — one overlay
adding a single variable would drop every other one.

Values are quoted on the way out: an unquoted `8080` or `true` reaches the container as
a YAML int/bool and the API server rejects the Pod.
*/}}
{{- define "devops-ai.env" -}}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- range $k, $v := .Values.secretEnv }}
- name: {{ $k }}
  valueFrom:
    secretKeyRef:
      name: {{ required (printf "secretEnv.%s.secret is required" $k) $v.secret }}
      key: {{ required (printf "secretEnv.%s.key is required" $k) $v.key }}
      {{- if $v.optional }}
      optional: true
      {{- end }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Pod-level boilerplate shared by all three workloads: image pull secrets, security
context, scheduling. Kept here rather than in each Deployment so a hardening change
lands everywhere at once.
*/}}
{{- define "devops-ai.podSpecCommon" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "devops-ai.serviceAccountName" . }}
automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken | default false }}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds | default 30 }}
{{- end -}}

{{/*
Container-level boilerplate: securityContext, resources, volume mounts.
*/}}
{{- define "devops-ai.containerCommon" -}}
imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
{{- with .Values.containerSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.extraVolumeMounts }}
volumeMounts:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
The in-cluster address of the MCP server, derived rather than configured. The agent and
the MCP server are two repos that must agree on this; deriving it from the same values
the Service is rendered from means they cannot drift.

Honours global.mcp.url for the case where the MCP server runs outside this release.
*/}}
{{- define "devops-ai.mcpUrl" -}}
{{- $g := .Values.global | default dict -}}
{{- $mcp := $g.mcp | default dict -}}
{{- if $mcp.url -}}
{{- $mcp.url -}}
{{- else -}}
{{- $name := $mcp.serviceName | default "devops-mcp-server" -}}
{{- $ns := $mcp.namespace | default .Release.Namespace -}}
{{- $port := $mcp.port | default 3000 -}}
{{- printf "http://%s.%s:%v/mcp" $name $ns $port -}}
{{- end -}}
{{- end -}}
