{{/*
Renders the agent's value objects into the env vars src/config/index.ts reads.

Why a helper and not literal env entries in the Deployment: the objects in values.yaml
are grouped by concern, the container wants a flat list of NAME=value, and the mapping
between the two is the thing that has to stay correct. Keeping it in one place means a
renamed variable is one edit, and it is checkable — the block below IS the inventory of
what this chart knows how to configure.

Precedence, once, for everything here: `.Values.env` WINS. Every derived variable is
skipped when a key of that name is already present in the raw map, so an overlay can
override one value without abandoning the objects. `hasKey`, not truthiness — setting a
variable to the empty string is a deliberate "unset this", and it is honoured.

Values that are nil or empty are not emitted at all: the app's own defaults are better
than an empty string, which for MEMORY_BACKEND or DB_HOST is not "unset" but "wrong".
Zero and false ARE emitted — REDIS_DB: 0 and DASHBOARD_COOKIE_SECURE: false are choices.
*/}}

{{- define "devops-ai-agent.derivedEnv" -}}
{{/* Both escape hatches suppress a derived variable of the same name. Not just `env`:
     a name listed twice in a container's env is not an error Kubernetes reports, it is
     a value silently resolved to one of the two. */}}
{{- $own := merge (dict) (.Values.env | default dict) (.Values.secretEnv | default dict) -}}
{{- $g := .Values.global | default dict -}}
{{- $svc := .Values.service | default dict -}}
{{- $mcp := .Values.mcp | default dict -}}
{{- $slack := .Values.slack | default dict -}}
{{- $llm := .Values.llm | default dict -}}
{{- $inv := .Values.investigation | default dict -}}
{{- $gitops := .Values.gitops | default dict -}}
{{- $db := .Values.database | default dict -}}
{{- $redis := .Values.redis | default dict -}}
{{- $dash := .Values.dashboard | default dict -}}

{{/* Plain name -> value.

MCP_AUTH_TOKEN is not here: both services emit it from the same shared helper, so the one
value they compare against each other cannot be spelled two ways.

MCP_TRANSPORT is here, and its counterpart on the server is called TRANSPORT — two repos
that named one contract differently. Each side therefore renders the name its own code
reads; the umbrella's _validate.tpl compares the two VALUES across that difference.

MCP_HTTP_URL is derived rather than configured — the agent and the MCP server are
separate repos that must agree on this address, so it comes from the same values the
Service is rendered from. */}}
{{- $plain := dict
      "PORT" $svc.port
      "MCP_TRANSPORT" $mcp.transport
      "MCP_HTTP_URL" (include "devops-ai.mcpUrl" .)
      "MCP_TOOL_TIMEOUT_SECONDS" $mcp.toolTimeoutSeconds
      "SLACK_ALERT_CHANNEL" $slack.alertChannel
      "SLACK_ONCALL_USERS" (join "," ($slack.oncallUsers | default list))
      "SLACK_APPROVER_USERS" (join "," ($slack.approverUsers | default list))
      "SLACK_LEARN_REACTION" $slack.learnReaction
      "LLM_PROVIDER" $llm.provider
      "MAX_TOKENS" $llm.maxTokens
      "SQS_LLM_TIMEOUT_SECONDS" ($llm.sqs | default dict).timeoutSeconds
      "SQS_POLL_WAIT_SECONDS" ($llm.sqs | default dict).pollWaitSeconds
      "LLM_ROUTE_HEAVY" (join "," (($llm.routes | default dict).heavy | default list))
      "LLM_ROUTE_LIGHT" (join "," (($llm.routes | default dict).light | default list))
      "INVESTIGATION_TIMEOUT_SECONDS" $inv.timeoutSeconds
      "MAX_CONCURRENT_INVESTIGATIONS" $inv.maxConcurrent
      "MENTION_TOOL_ROUNDS" $inv.mentionToolRounds
      "DASHBOARD_ENABLED" ($dash.enabled | default false)
-}}

{{/* Secret-backed name -> {secret, key, optional}. */}}
{{- $secrets := dict -}}
{{- if $slack.existingSecret -}}
  {{- if $slack.botTokenKey -}}
    {{- $_ := set $secrets "SLACK_BOT_TOKEN" (dict "secret" $slack.existingSecret "key" $slack.botTokenKey) -}}
  {{- end -}}
  {{- if $slack.signingSecretKey -}}
    {{- $_ := set $secrets "SLACK_SIGNING_SECRET" (dict "secret" $slack.existingSecret "key" $slack.signingSecretKey) -}}
  {{- end -}}
  {{/* Socket Mode is optional; a missing key must not block the Pod from starting. */}}
  {{- if $slack.appTokenKey -}}
    {{- $_ := set $secrets "SLACK_APP_TOKEN" (dict "secret" $slack.existingSecret "key" $slack.appTokenKey "optional" true) -}}
  {{- end -}}
{{- end -}}
{{- $webhook := .Values.alertWebhook | default dict -}}
{{- if and $webhook.existingSecret $webhook.tokenKey -}}
  {{- $_ := set $secrets "ALERT_WEBHOOK_TOKEN" (dict "secret" $webhook.existingSecret "key" $webhook.tokenKey) -}}
{{- end -}}

{{/* ---- LLM backends: the list becomes LLM_BACKEND_<N>_* ----

The registry stops reading at the first missing index, so the indices must be contiguous
from 1. That was a real way to break a router by deleting a middle entry from a flat env
map; a list has no gaps to introduce. Order here IS the index order. */}}
{{- range $i, $b := ($llm.backends | default list) -}}
  {{- $n := add1 $i -}}
  {{- $_ := set $plain (printf "LLM_BACKEND_%d_NAME" $n) $b.name -}}
  {{- $_ := set $plain (printf "LLM_BACKEND_%d_KIND" $n) $b.kind -}}
  {{- $_ := set $plain (printf "LLM_BACKEND_%d_MODEL" $n) $b.model -}}
  {{- $_ := set $plain (printf "LLM_BACKEND_%d_BASE_URL" $n) $b.baseUrl -}}
  {{- $_ := set $plain (printf "LLM_BACKEND_%d_CONTEXT_TOKENS" $n) $b.contextTokens -}}
  {{/* Its own variable so the key can come from a Secret while the rest of the backend
       comes from plain values. private-llm has no key — llm-worker holds that one. */}}
  {{- if $b.existingSecret -}}
    {{- $_ := set $secrets (printf "LLM_BACKEND_%d_KEY" $n) (dict "secret" $b.existingSecret "key" ($b.apiKeyKey | default (printf "LLM_BACKEND_%d_KEY" $n))) -}}
  {{- end -}}
{{- end -}}

{{/* ---- GitOps ---- */}}
{{- if $gitops.enabled -}}
  {{- $_ := merge $plain (dict
        "GITOPS_REMEDIATION_ENABLED" "true"
        "SQS_GITOPS_TIMEOUT_SECONDS" $gitops.timeoutSeconds
        "REMEDIATION_VERIFY_DELAY_SECONDS" $gitops.verifyDelaySeconds
        "REMEDIATION_VERIFY_POLL_SECONDS" $gitops.verifyPollSeconds) -}}
{{- end -}}

{{/* ---- Postgres ----

Only when a database is actually reachable: either one is named here, or the bundled
subchart deployed one, whose Service name is derived below. Emitting DB_PASSWORD alone
would mount a Secret key for a database that does not exist — and if that Secret is
missing, the Pod does not start. With nothing set the agent simply runs without incident
history, which is the honest degraded state.

The bundled host is derived rather than configured: a subchart cannot see its siblings'
values, so the flag lives in `global` and the name follows the Bitnami fullname
convention, honouring global.postgresql.fullnameOverride when the Service is renamed.
An explicit database.host wins — that is how you point at a Postgres this release did
not deploy. */}}
{{- $pg := $g.postgresql | default dict -}}
{{- $dbHost := $db.host | default (ternary ($pg.fullnameOverride | default (printf "%s-postgresql" .Release.Name)) "" (or $pg.enabled false)) -}}
{{- if $dbHost -}}
  {{- $_ := merge $plain (dict
        "DB_HOST" $dbHost
        "DB_PORT" $db.port
        "DB_NAME" $db.name
        "DB_USERNAME" $db.username
        "DB_SSL_MODE" $db.sslMode) -}}
  {{- if and $db.existingSecret $db.passwordKey -}}
    {{- $_ := set $secrets "DB_PASSWORD" (dict "secret" $db.existingSecret "key" $db.passwordKey) -}}
  {{- end -}}
{{- end -}}

{{/* ---- Redis ----

Same rule, same reason, same derivation — except the Bitnami redis chart's writable
endpoint is the -master Service, not the chart fullname.

MEMORY_BACKEND is only switched to "redis" when a Redis is genuinely in play; otherwise
the agent keeps conversation state in the pod, which costs context on a restart rather
than failing every lookup against localhost. `redis.enabled` with no host anywhere is
rejected at render time — see the umbrella's _validate.tpl. */}}
{{- $gRedis := $g.redis | default dict -}}
{{- $redisHost := $redis.host | default (ternary (printf "%s-master" ($gRedis.fullnameOverride | default (printf "%s-redis" .Release.Name))) "" (or $gRedis.enabled false)) -}}
{{- if and (or $redis.enabled $gRedis.enabled) $redisHost -}}
  {{- $_ := merge $plain (dict
        "MEMORY_BACKEND" "redis"
        "REDIS_HOST" $redisHost
        "REDIS_PORT" $redis.port
        "REDIS_DB" $redis.db
        "REDIS_TLS" $redis.tls
        "REDIS_USERNAME" $redis.username) -}}
  {{- if and $redis.existingSecret $redis.passwordKey -}}
    {{- $_ := set $secrets "REDIS_PASSWORD" (dict "secret" $redis.existingSecret "key" $redis.passwordKey) -}}
  {{- end -}}
{{- end -}}

{{/* ---- Dashboard ----

The password Secret key is mounted optional: with no password readable the dashboard
serves 503 rather than serving incidents anonymously, so a missing key degrades that one
endpoint instead of blocking the whole agent from starting. */}}
{{- if $dash.enabled -}}
  {{- $_ := merge $plain (dict
        "DASHBOARD_PORT" $dash.port
        "DASHBOARD_COOKIE_SECURE" $dash.cookieSecure) -}}
  {{- if and $dash.existingSecret $dash.passwordKey -}}
    {{- $_ := set $secrets "DASHBOARD_PASSWORD" (dict "secret" $dash.existingSecret "key" $dash.passwordKey "optional" true) -}}
  {{- end -}}
{{- end -}}

{{- range $k, $v := $plain }}
{{- if and (not (hasKey $own $k)) (not (kindIs "invalid" $v)) (ne ($v | toString) "") }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- range $k, $v := $secrets }}
{{- if not (hasKey $own $k) }}
- name: {{ $k }}
  valueFrom:
    secretKeyRef:
      name: {{ $v.secret }}
      key: {{ $v.key }}
      {{- if $v.optional }}
      optional: true
      {{- end }}
{{- end }}
{{- end }}
{{- end -}}
