{{/*
Cross-repo contract checks.

This is the reason this chart exists rather than a generic one. The three services agree
on values that live in three different repos: a shared MCP token, a pair of SQS queue
names, a database name. Nothing validates those agreements today — a typo deploys fine
and fails at runtime, in Slack, during an incident.

Every check below fails `helm template`, so it fails in CI and in Flux's dry-run before
anything reaches a cluster.

Rules for adding a check here:
  - Only assert what CANNOT be checked inside one service. A missing SLACK_BOT_TOKEN is
    the agent's own business and its own boot validation already covers it.
  - Only assert what is knowable at template time. Whether the SQS queue actually exists
    in AWS is not.
  - Say what to do, not just what is wrong.
*/}}
{{- define "devops-ai.validate" -}}
{{- $g := .Values.global | default dict -}}
{{- $agent := index .Values "devops-ai-agent" | default dict -}}
{{- $mcp := index .Values "devops-mcp-server" | default dict -}}
{{- $worker := index .Values "devops-llm-worker" | default dict -}}

{{- $agentOn := ne $agent.enabled false -}}
{{- $mcpOn := ne $mcp.enabled false -}}
{{- $workerOn := ne $worker.enabled false -}}

{{/* ---- agent <-> mcp-server: the shared bearer token ---- */}}
{{- if and $agentOn $mcpOn -}}
  {{- $gmcp := ($g.mcp) | default dict -}}
  {{- $sharedToken := or $gmcp.authToken (($gmcp.authTokenSecret | default dict).name) -}}
  {{- $agentToken := ($agent.env | default dict).MCP_AUTH_TOKEN -}}
  {{- $mcpToken := ($mcp.env | default dict).MCP_AUTH_TOKEN -}}
  {{- if not (or $sharedToken (and $agentToken $mcpToken)) -}}
    {{- fail "\n\nMCP auth token is not set.\n\nThe agent and the MCP server authenticate over HTTP with a shared bearer token; both sides must carry the same value.\n\nSet it in ONE place:\n  global.mcp.authToken: <value>          # preferred — rendered into both\n\nor, if you must keep them separate, set both:\n  devops-ai-agent.env.MCP_AUTH_TOKEN\n  devops-mcp-server.env.MCP_AUTH_TOKEN\n\nFor a real deployment prefer global.mcp.authTokenSecret (an existing Secret) so the token is not in values.yaml.\n" -}}
  {{- end -}}
  {{- if and $agentToken $mcpToken (ne $agentToken $mcpToken) -}}
    {{- fail (printf "\n\nMCP auth token mismatch.\n\n  devops-ai-agent.env.MCP_AUTH_TOKEN     = %q\n  devops-mcp-server.env.MCP_AUTH_TOKEN   = %q\n\nThese must be identical — the agent sends this token as a bearer and the server compares it. Different values means every tool call returns 401 and every investigation dies on its first tool.\n\nSet global.mcp.authToken once instead of maintaining two copies.\n" $agentToken $mcpToken) -}}
  {{- end -}}
{{- end -}}

{{/* ---- agent -> mcp-server: transport agreement ---- */}}
{{- if and $agentOn $mcpOn -}}
  {{- $agentTransport := ($agent.env | default dict).MCP_TRANSPORT | default "http" -}}
  {{- $mcpTransport := ($mcp.env | default dict).MCP_TRANSPORT | default "http" -}}
  {{- if ne $agentTransport $mcpTransport -}}
    {{- fail (printf "\n\nMCP transport mismatch: agent speaks %q, server speaks %q.\n\nBoth must be \"http\" when they run as separate Deployments — \"stdio\" only works when the server is a child process of the agent, which it is not here.\n" $agentTransport $mcpTransport) -}}
  {{- end -}}
  {{- if ne $agentTransport "http" -}}
    {{- fail (printf "\n\nMCP_TRANSPORT is %q, but this chart deploys the MCP server as its own Deployment reached over the network.\n\nUse \"http\".\n" $agentTransport) -}}
  {{- end -}}
{{- end -}}

{{/* ---- agent <-> llm-worker: the SQS queue pair ---- */}}
{{- if and $agentOn $workerOn -}}
  {{- $agentEnv := $agent.env | default dict -}}
  {{- $workerEnv := $worker.env | default dict -}}
  {{- $gq := ($g.sqs) | default dict -}}

  {{- $agentReq := $agentEnv.SQS_REQUEST_QUEUE_NAME | default $gq.requestQueue -}}
  {{- $workerReq := $workerEnv.SQS_REQUEST_QUEUE_NAME | default $gq.requestQueue -}}
  {{- if and $agentReq $workerReq (ne $agentReq $workerReq) -}}
    {{- fail (printf "\n\nSQS request queue mismatch.\n\n  devops-ai-agent    SQS_REQUEST_QUEUE_NAME = %q\n  devops-llm-worker  SQS_REQUEST_QUEUE_NAME = %q\n\nThe agent writes requests to this queue and the worker reads them. Different names means the agent's requests are never consumed: every investigation hangs until it times out.\n\nSet global.sqs.requestQueue once.\n" $agentReq $workerReq) -}}
  {{- end -}}

  {{- $agentRes := $agentEnv.SQS_RESPONSE_QUEUE_NAME | default $gq.responseQueue -}}
  {{- $workerRes := $workerEnv.SQS_RESPONSE_QUEUE_NAME | default $gq.responseQueue -}}
  {{- if and $agentRes $workerRes (ne $agentRes $workerRes) -}}
    {{- fail (printf "\n\nSQS response queue mismatch.\n\n  devops-ai-agent    SQS_RESPONSE_QUEUE_NAME = %q\n  devops-llm-worker  SQS_RESPONSE_QUEUE_NAME = %q\n\nThis is the SHARED response queue: the worker writes replies to it and the agent routes them back by requestId. Different names means every reply is written where nobody is listening.\n\nSet global.sqs.responseQueue once.\n" $agentRes $workerRes) -}}
  {{- end -}}

  {{/* The GitOps PR flow is a second contract on its own request queue. */}}
  {{- if eq ($agentEnv.GITOPS_REMEDIATION_ENABLED | toString) "true" -}}
    {{- $agentGq := $agentEnv.SQS_GITOPS_REQUEST_QUEUE_NAME | default $gq.gitopsRequestQueue -}}
    {{- $workerGq := $workerEnv.SQS_GITOPS_REQUEST_QUEUE_NAME | default $gq.gitopsRequestQueue -}}
    {{- if not (and $agentGq $workerGq) -}}
      {{- fail "\n\nGITOPS_REMEDIATION_ENABLED is true but the GitOps request queue is not set on both sides.\n\nSet global.sqs.gitopsRequestQueue, or set SQS_GITOPS_REQUEST_QUEUE_NAME in both devops-ai-agent.env and devops-llm-worker.env.\n\nWithout it the agent will open GitOps proposals that no worker ever picks up.\n" -}}
    {{- end -}}
    {{- if and $agentGq $workerGq (ne $agentGq $workerGq) -}}
      {{- fail (printf "\n\nSQS GitOps request queue mismatch.\n\n  devops-ai-agent    SQS_GITOPS_REQUEST_QUEUE_NAME = %q\n  devops-llm-worker  SQS_GITOPS_REQUEST_QUEUE_NAME = %q\n\nSet global.sqs.gitopsRequestQueue once.\n" $agentGq $workerGq) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* ---- agent: a private-llm backend needs the worker ---- */}}
{{- if $agentOn -}}
  {{- $agentEnv := $agent.env | default dict -}}
  {{- $hasPrivate := false -}}
  {{- range $k, $v := $agentEnv -}}
    {{- if and (regexMatch "^LLM_BACKEND_[0-9]+_KIND$" $k) (eq ($v | toString) "private-llm") -}}
      {{- $hasPrivate = true -}}
    {{- end -}}
  {{- end -}}
  {{- if and $hasPrivate (not $workerOn) -}}
    {{- fail "\n\nA private-llm backend is configured on the agent, but devops-llm-worker is disabled.\n\nprivate-llm backends do not call an API directly — they put the request on SQS and wait for llm-worker to answer. With no worker running, every call routed to that backend hangs until SQS_LLM_TIMEOUT_SECONDS.\n\nEither set devops-llm-worker.enabled: true, or remove the private-llm backend from the agent's LLM_BACKEND_<N>_* variables and its LLM_ROUTE_* entries.\n" -}}
  {{- end -}}

  {{/* Same shape, other contract: the worker is the only side holding GitHub creds. */}}
  {{- if and (eq ($agentEnv.GITOPS_REMEDIATION_ENABLED | toString) "true") (not $workerOn) -}}
    {{- fail "\n\nGITOPS_REMEDIATION_ENABLED is true on the agent, but devops-llm-worker is disabled.\n\nThe agent holds no GitHub credentials by design. It puts PR requests on the GitOps SQS queue and llm-worker — the private-network bridge that does hold them — opens the pull request. With no worker running, every remediation proposal the agent makes is silently dropped.\n\nEither set devops-llm-worker.enabled: true (with its gitops.* values), or set GITOPS_REMEDIATION_ENABLED: \"false\".\n" -}}
  {{- end -}}
{{- end -}}

{{/* ---- the GitOps bridge must be switched on at BOTH ends ----

The agent's GITOPS_REMEDIATION_ENABLED makes it emit PR requests; the worker's
gitops.enabled is what gives that worker its GitHub token and repo. On without the other
means proposals land on a queue whose consumer cannot act on them.
*/}}
{{- if and $agentOn $workerOn -}}
  {{- $agentGitops := eq (($agent.env | default dict).GITOPS_REMEDIATION_ENABLED | toString) "true" -}}
  {{- $workerGitops := ($worker.gitops | default dict).enabled | default false -}}
  {{- if and $agentGitops (not $workerGitops) -}}
    {{- fail "\n\nThe agent has GITOPS_REMEDIATION_ENABLED: \"true\", but devops-llm-worker.gitops.enabled is false.\n\nThe worker will consume the agent's PR requests without a GITHUB_TOKEN or a GITOPS_REPO to act on them, so every remediation proposal fails at the worker.\n\nSet devops-llm-worker.gitops.enabled: true (with repo and tokenSecret), or turn off GITOPS_REMEDIATION_ENABLED on the agent.\n" -}}
  {{- end -}}
{{- end -}}

{{/* ---- worker: the wire format must be one the worker knows ---- */}}
{{- if $workerOn -}}
  {{- $fmt := (($worker.env | default dict).LLM_API_FORMAT) | default "openai" -}}
  {{- if not (has $fmt (list "openai" "anthropic")) -}}
    {{- fail (printf "\n\nLLM_API_FORMAT is %q, which llm-worker does not implement.\n\nValid values: \"openai\" (POSTs /v1/chat/completions) or \"anthropic\" (POSTs /v1/messages).\n\nThis names the WIRE FORMAT, not the vendor — a self-hosted model behind an OpenAI-compatible gateway is \"openai\".\n" $fmt) -}}
  {{- end -}}
{{- end -}}

{{/* ---- the backing-service switch must be the one the subcharts are gated on ----

Setting `postgresql.enabled` at the root is the natural guess and it does nothing: the
dependency is gated on global.postgresql.enabled, so the guess yields no Postgres and an
agent with no DB_HOST. Silent, and only visible once the agent is crash-looping.
*/}}
{{- range $name := list "postgresql" "redis" -}}
  {{- $rootVals := index $.Values $name | default dict -}}
  {{- if hasKey $rootVals "enabled" -}}
    {{- fail (printf "\n\n%s.enabled has no effect — it is ignored.\n\nThis chart gates the %s dependency on global.%s.enabled, because a subchart can only read its own values plus global, and the agent has to know whether a %s was deployed here in order to point DB_HOST/REDIS_HOST at it.\n\nMove it:\n  global:\n    %s:\n      enabled: %v\n\nEverything else under %s: is passed to the Bitnami chart as usual — leave it where it is.\n" $name $name $name $name $name (index $rootVals "enabled") $name) -}}
  {{- end -}}
{{- end -}}

{{/* ---- agent -> postgres: bundled subchart must agree on the database name ---- */}}
{{- $pgGlobal := ($g.postgresql | default dict) -}}
{{- if $pgGlobal.enabled -}}
  {{- $auth := ((.Values.postgresql | default dict).auth | default dict) -}}
  {{- if not $auth.database -}}
    {{- fail "\n\nglobal.postgresql.enabled is true but postgresql.auth.database is not set.\n\nThe Bitnami postgresql chart only CREATES a database when auth.database is set, and only on first init of an empty volume. App migrations create tables, never the database itself — so without this the agent starts, connects, and fails every query.\n\nSet postgresql.auth.database (\"devops_agent\" unless you have a reason).\n" -}}
  {{- end -}}
  {{- if $agentOn -}}
    {{- $dbName := ($agent.env | default dict).DB_NAME -}}
    {{- if and $dbName (ne $dbName $auth.database) -}}
      {{- fail (printf "\n\nDatabase name mismatch.\n\n  devops-ai-agent.env.DB_NAME     = %q\n  postgresql.auth.database        = %q\n\nThe bundled Postgres will create %q, and the agent will look for %q.\n" $dbName $auth.database $auth.database $dbName) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* ---- a renamed subchart must be renamed in both places ----

DB_HOST is derived from global.<svc>.fullnameOverride, while the Service itself is named
from the subchart's own fullnameOverride. Set one without the other and the agent looks
up a hostname that does not resolve.
*/}}
{{- range $name := list "postgresql" "redis" -}}
  {{- $gsvc := index ($g | default dict) $name | default dict -}}
  {{- if $gsvc.enabled -}}
    {{- $subOverride := (index $.Values $name | default dict).fullnameOverride | default "" -}}
    {{- $globalOverride := $gsvc.fullnameOverride | default "" -}}
    {{- if ne $subOverride $globalOverride -}}
      {{- fail (printf "\n\n%s fullnameOverride mismatch.\n\n  %s.fullnameOverride         = %q   # names the Service\n  global.%s.fullnameOverride  = %q   # what the agent connects to\n\nBoth must carry the same value, or leave both empty to use the default name.\n" $name $name $subOverride $name $globalOverride) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- end -}}
