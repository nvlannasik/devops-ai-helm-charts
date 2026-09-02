{{/*
Renders the worker's value objects into the env vars src/config.ts reads.

Same shape and same precedence as the other two subcharts: `.Values.env` and
`.Values.secretEnv` WIN over anything derived here (`hasKey`, so setting a variable to the
empty string is an honoured "unset"), nil and empty values are not emitted so the app's own
defaults apply, and zero and false ARE emitted because they are choices.

Not here: SQS queue names, the region, and the AWS credentials. Those come from
`global.sqs` and `global.aws` through the umbrella's shared helpers, because the agent and
this worker meet on those queues — a value that means nothing on one side alone.
*/}}

{{- define "devops-llm-worker.derivedEnv" -}}
{{- $own := merge (dict) (.Values.env | default dict) (.Values.secretEnv | default dict) -}}
{{- $llm := .Values.llm | default dict -}}
{{- $sqs := .Values.sqs | default dict -}}
{{- $gitops := .Values.gitops | default dict -}}

{{/* model and maxTokens live in the flow on the agent-builder path — its run envelope has
     no field for either — so they are dropped rather than rendered inert. maxTokens has a
     chart default, which is why this is a gate here and not a rejection in _validate.tpl. */}}
{{- $inFlow := eq ($llm.apiFormat | default "openai") "agent-builder" -}}
{{- $plain := dict
      "LLM_API_FORMAT" $llm.apiFormat
      "LLM_BASE_URL" $llm.baseUrl
      "LLM_MODEL" (ternary "" ($llm.model | toString) $inFlow)
      "LLM_MAX_TOKENS" (ternary "" ($llm.maxTokens | toString) $inFlow)
      "LLM_SOCKS_PROXY" $llm.socksProxy
      "SQS_POLL_WAIT_SECONDS" $sqs.pollWaitSeconds
      "SQS_MAX_MESSAGES" $sqs.maxMessages
      "SQS_MAX_CONCURRENCY" $sqs.maxConcurrency
      "SQS_VISIBILITY_TIMEOUT_SECONDS" $sqs.visibilityTimeoutSeconds
      "SQS_MAX_RECEIVE_COUNT" $sqs.maxReceiveCount
-}}
{{- $secrets := dict -}}

{{/* ---- Sampling, and the ones only one wire format accepts ----

temperature and topP are sent on both paths. The other three are OpenAI-only: the
Anthropic path does not send them, and a backend that receives an unknown field on
/v1/messages answers 400 rather than ignoring it. So they render only under
apiFormat "openai" — a value that silently does nothing is the thing this chart exists to
prevent, and here it does not even do nothing.

Rendered from `sampling:` rather than named individually above because they share that
one condition. */}}
{{- $s := $llm.sampling | default dict -}}
{{- $_ := merge $plain (dict
      "LLM_TEMPERATURE" $s.temperature
      "LLM_TOP_P" $s.topP) -}}
{{- if eq ($llm.apiFormat | default "openai") "openai" -}}
  {{- $_ := merge $plain (dict
        "LLM_REASONING_EFFORT" $s.reasoningEffort
        "LLM_SEED" $s.seed
        "LLM_USE_MAX_COMPLETION_TOKENS" $llm.useMaxCompletionTokens) -}}
{{- end -}}

{{/* The API key is optional: the config defaults it to the string "none", which is what a
     self-hosted endpoint with no auth expects. Mounted optional so a missing key is a 401
     from the endpoint rather than a Pod that never starts. */}}
{{- if and $llm.existingSecret $llm.apiKeyKey -}}
  {{- $_ := set $secrets "LLM_API_KEY" (dict "secret" $llm.existingSecret "key" $llm.apiKeyKey "optional" true) -}}
{{- end -}}

{{/* ---- GitOps: the worker's second job ----

This is the private network's only bridge to GitHub Enterprise, so the credentials live
here and the agent holds none. Two auth flows, and the app's own config picks the PAT when
both are set:

  PAT          one Secret key, used directly as the bearer. The initial-phase path.
  GitHub App   appId + installationId + a private key, exchanged for a short-lived
               installation token per call.

The private key is mounted as a FILE (GITHUB_APP_PRIVATE_KEY_FILE) rather than passed
inline: a multi-line PEM in an env var survives, but it is also the one credential here
that a `kubectl describe pod` would print in full. The app reads either, and prefers the
file.

`enabled` in the app's config is derived, not read: it is true when a credential AND a
repo are present. So the render requires the repo — a worker with credentials and no repo
would start, report gitops as disabled, and silently drop every proposal the agent sends
to a queue nothing is reading. */}}
{{- if $gitops.enabled -}}
  {{- $auth := $gitops.auth | default dict -}}
  {{- $app := $auth.githubApp | default dict -}}
  {{- $_ := merge $plain (dict
        "GITOPS_REPO" (required "devops-llm-worker.gitops.repo is required when gitops.enabled — \"owner/name\", and the ONLY repo the handler may touch" $gitops.repo)
        "GITOPS_BRANCH" $gitops.branch
        "GITOPS_PATH_PREFIX" $gitops.pathPrefix
        "GITHUB_API_URL" $gitops.apiUrl) -}}
  {{- $ts := $auth.tokenSecret | default dict -}}
  {{- if $ts.name -}}
    {{- $_ := set $secrets "GITHUB_TOKEN" (dict "secret" $ts.name "key" ($ts.key | default "token")) -}}
  {{- else if $app.appId -}}
    {{- $_ := merge $plain (dict
          "GITHUB_APP_ID" ($app.appId | toString)
          "GITHUB_APP_INSTALLATION_ID" (required "devops-llm-worker.gitops.auth.githubApp.installationId is required — the App's ID identifies the app, the installation ID identifies its grant on this org" $app.installationId | toString)
          "GITHUB_APP_PRIVATE_KEY_FILE" (printf "%s/%s" ($app.privateKeyMountPath | default "/github-app") ($app.privateKeySecret | default dict).key)) -}}
  {{- else -}}
    {{- fail "\n\ndevops-llm-worker.gitops.enabled is true but no GitHub credentials are configured.\n\nSet one of:\n\n  gitops.auth.tokenSecret:              # PAT — the simple path\n    name: github-token-secret\n    key: token\n\n  gitops.auth.githubApp:                # short-lived installation tokens\n    appId: \"123456\"\n    installationId: \"7890123\"\n    privateKeySecret: {name: github-app-key, key: private-key.pem}\n\nWithout either, the worker reports gitops as disabled at boot and every proposal the agent puts on the queue is dropped unanswered.\n" -}}
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

{{/*
The GitHub App private key volume, and its mount.

Kept beside the env helper for the same reason the AWS certificate is: the path in
GITHUB_APP_PRIVATE_KEY_FILE and the path the Secret is mounted at are one value, and
splitting them gives a worker that starts, reads an empty key, and fails its first token
exchange with a signature error that names nothing useful.

Rendered only for the App flow — the PAT flow has no file.
*/}}
{{- define "devops-llm-worker.githubAppVolume" -}}
{{- $app := ((.Values.gitops | default dict).auth | default dict).githubApp | default dict -}}
{{- if and (.Values.gitops | default dict).enabled $app.appId (not (((.Values.gitops.auth | default dict).tokenSecret | default dict).name)) }}
- name: github-app-key
  secret:
    secretName: {{ (required "devops-llm-worker.gitops.auth.githubApp.privateKeySecret.name is required for the GitHub App flow" ($app.privateKeySecret | default dict).name) }}
    defaultMode: 0400
{{- end }}
{{- end -}}

{{- define "devops-llm-worker.githubAppVolumeMount" -}}
{{- $app := ((.Values.gitops | default dict).auth | default dict).githubApp | default dict -}}
{{- if and (.Values.gitops | default dict).enabled $app.appId (not (((.Values.gitops.auth | default dict).tokenSecret | default dict).name)) }}
- name: github-app-key
  mountPath: {{ $app.privateKeyMountPath | default "/github-app" }}
  readOnly: true
{{- end }}
{{- end -}}
