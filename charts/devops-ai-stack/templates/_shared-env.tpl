{{/*
Renders the env vars that come from `global:` — the values two services must agree on.

This is what makes `global:` load-bearing rather than documentation. Each subchart calls
the helper for its side of the contract, so one setting in the umbrella reaches both
Deployments and there is no second copy to keep in sync.

Precedence: a service's own `env` wins. These helpers emit a global-derived variable only
when the service has not set it explicitly, so an overlay can still override one value
without abandoning the shared defaults.
*/}}

{{/* MCP bearer token — agent side and server side get the identical value. */}}
{{- define "devops-ai.mcpAuthEnv" -}}
{{- $mcp := (.Values.global | default dict).mcp | default dict -}}
{{- $ownEnv := .Values.env | default dict -}}
{{- if not $ownEnv.MCP_AUTH_TOKEN -}}
{{- $secret := $mcp.authTokenSecret | default dict -}}
{{- if $secret.name }}
- name: MCP_AUTH_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $secret.name }}
      key: {{ $secret.key | default "MCP_AUTH_TOKEN" }}
{{- else if $mcp.authToken }}
- name: MCP_AUTH_TOKEN
  value: {{ $mcp.authToken | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
SQS queue names and region. Both the agent and the worker read the same four values;
`which` names them so adding a queue means editing one list.
*/}}
{{- define "devops-ai.sqsEnv" -}}
{{- $sqs := (.Values.global | default dict).sqs | default dict -}}
{{- $ownEnv := .Values.env | default dict -}}
{{- if and $sqs.requestQueue (not $ownEnv.SQS_REQUEST_QUEUE_NAME) }}
- name: SQS_REQUEST_QUEUE_NAME
  value: {{ $sqs.requestQueue | quote }}
{{- end }}
{{- if and $sqs.responseQueue (not $ownEnv.SQS_RESPONSE_QUEUE_NAME) }}
- name: SQS_RESPONSE_QUEUE_NAME
  value: {{ $sqs.responseQueue | quote }}
{{- end }}
{{- if and $sqs.requestDlq (not $ownEnv.SQS_REQUEST_DLQ_NAME) }}
- name: SQS_REQUEST_DLQ_NAME
  value: {{ $sqs.requestDlq | quote }}
{{- end }}
{{- if and $sqs.gitopsRequestQueue (not $ownEnv.SQS_GITOPS_REQUEST_QUEUE_NAME) }}
- name: SQS_GITOPS_REQUEST_QUEUE_NAME
  value: {{ $sqs.gitopsRequestQueue | quote }}
{{- end }}
{{- if and $sqs.region (not $ownEnv.AWS_REGION) }}
- name: AWS_REGION
  value: {{ $sqs.region | quote }}
{{- end }}
{{- end -}}

{{/*
Addresses of the bundled backing services.

Only emitted when the subchart is actually deployed. Otherwise the agent would be pointed
at a Service this release never created, which is worse than leaving it unset: instead of
failing its own boot validation the agent starts and then DNS-fails on every query. With
the subcharts off (the default) the cluster's own Postgres and Redis are in play, so set
DB_HOST and REDIS_HOST in the agent's own env.

The flags are read from global because a subchart's templates cannot see sibling values —
see the note in Chart.yaml. Names follow the Bitnami charts' fullname convention,
<release>-postgresql and <release>-redis-master, and honour fullnameOverride when set.
*/}}
{{- define "devops-ai.backingServicesEnv" -}}
{{- $g := .Values.global | default dict -}}
{{- $ownEnv := .Values.env | default dict -}}
{{- $pg := $g.postgresql | default dict -}}
{{- if and $pg.enabled (not $ownEnv.DB_HOST) }}
- name: DB_HOST
  value: {{ $pg.fullnameOverride | default (printf "%s-postgresql" .Release.Name) | quote }}
{{- end }}
{{- $redis := $g.redis | default dict -}}
{{- if and $redis.enabled (not $ownEnv.REDIS_HOST) }}
- name: REDIS_HOST
  value: {{ printf "%s-master" ($redis.fullnameOverride | default (printf "%s-redis" .Release.Name)) | quote }}
{{- end }}
{{- end -}}
