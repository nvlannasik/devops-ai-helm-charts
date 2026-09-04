{{/*
Renders the env vars that come from `global:` — the values two services must agree on.

This is what makes `global:` load-bearing rather than documentation. Each subchart calls
the helper for its side of the contract, so one setting in the umbrella reaches both
Deployments and there is no second copy to keep in sync.

Precedence: a service's own `env` wins. These helpers emit a global-derived variable only
when the service has not set it explicitly, so an overlay can still override one value
without abandoning the shared defaults.
*/}}

{{/*
The MCP bearer token, rendered from the CALLING service's own `mcp:` block.

Unlike everything else in this file, this reads .Values.mcp rather than .Values.global —
MCP is not global, it belongs to the two services that speak it, and each states its own
side. The umbrella's _validate.tpl is what compares the two, so the duplication is
checked rather than merely hoped for.

The TOKEN is what both sides spell identically: same variable name, same value, one
compared against the other at request time. So it is rendered by one helper for both,
which is harder to spell two different ways than two literal env blocks are.

The transport is NOT here, and that asymmetry is deliberate. These are two repos, and
they named the variable differently: the agent reads MCP_TRANSPORT, the server reads
TRANSPORT. Each side therefore renders its own name from its own values, and this helper
does not pretend they are one variable — a shared helper emitting MCP_TRANSPORT on the
server side is a value that renders, validates, and does nothing, which is exactly what
this chart existed to prevent.
*/}}
{{- define "devops-ai.mcpAuthEnv" -}}
{{- $mcp := .Values.mcp | default dict -}}
{{- $ownEnv := merge (dict) (.Values.env | default dict) (.Values.secretEnv | default dict) -}}
{{- if not (hasKey $ownEnv "MCP_AUTH_TOKEN") -}}
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

The REQUEST queue is the one exception to "global is the value": with more than one private
LLM there is one request queue per MODEL, and each worker polls only its own. So a workload
may name its own in `.Values.requestQueue`, which wins over the global. The RESPONSE queue
has no such override and never will — replies are routed by requestId, never by which model
produced them, so every worker writes to the one queue the agent reads.
*/}}
{{- define "devops-ai.sqsEnv" -}}
{{- $sqs := (.Values.global | default dict).sqs | default dict -}}
{{- $ownEnv := .Values.env | default dict -}}
{{- $req := .Values.requestQueue | default $sqs.requestQueue -}}
{{- if and $req (not $ownEnv.SQS_REQUEST_QUEUE_NAME) }}
- name: SQS_REQUEST_QUEUE_NAME
  value: {{ $req | quote }}
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
{{- end -}}

{{/*
How a workload authenticates to AWS, and where.

The agent and the worker meet on SQS, so they must reach the same region with credentials
for the same account — a third pair of values that means nothing on one side alone. This
renders that pair from one place.

AWS_AUTH_MODE is the contract with entrypoint.sh inside both images, which dispatches on
it: "iam-anywhere" makes the script write ~/.aws/config with a credential_process and
REQUIRE the three ARNs and a readable certificate; the other three modes make it skip
setup entirely and let the SDK's own chain resolve credentials. Emitting the credentials
for one mode while the script runs another is how a Pod CrashLoops before Node starts,
so the mode and the variables it needs are rendered together, here.

  iam-anywhere      three ARNs from a Secret + CERT_PATH / CERT_KEY_PATH
  irsa              nothing — see the ServiceAccount annotation
  env               AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from a Secret
  instance-profile  nothing
*/}}
{{- define "devops-ai.awsEnv" -}}
{{- if (.Values.aws | default dict).enabled -}}
{{- $aws := (.Values.global | default dict).aws | default dict -}}
{{- $ownEnv := .Values.env | default dict -}}
{{- $mode := $aws.authMode | default "iam-anywhere" -}}
{{- if not $ownEnv.AWS_AUTH_MODE }}
- name: AWS_AUTH_MODE
  value: {{ $mode | quote }}
{{- end }}
{{- if and $aws.region (not $ownEnv.AWS_REGION) }}
- name: AWS_REGION
  value: {{ $aws.region | quote }}
{{- end }}
{{- $ra := $aws.rolesAnywhere | default dict -}}
{{- if eq $mode "iam-anywhere" }}
{{- $secret := $ra.configSecret | default dict }}
{{- if not $ownEnv.AWS_TRUST_ANCHOR_ARN }}
- name: AWS_TRUST_ANCHOR_ARN
  valueFrom:
    secretKeyRef:
      name: {{ required "global.aws.rolesAnywhere.configSecret.name is required when authMode is iam-anywhere" $secret.name }}
      key: {{ $secret.trustAnchorArnKey | default "trust-anchor-arn" }}
{{- end }}
{{- if not $ownEnv.AWS_ROLESANYWHERE_PROFILE_ARN }}
- name: AWS_ROLESANYWHERE_PROFILE_ARN
  valueFrom:
    secretKeyRef:
      name: {{ $secret.name }}
      key: {{ $secret.profileArnKey | default "profile-arn" }}
{{- end }}
{{- if not $ownEnv.AWS_ROLE_ARN }}
- name: AWS_ROLE_ARN
  valueFrom:
    secretKeyRef:
      name: {{ $secret.name }}
      key: {{ $secret.roleArnKey | default "role-arn" }}
{{- end }}
{{- $cert := $aws.certificate | default dict }}
{{- $mountPath := $cert.mountPath | default "/certs" }}
{{- if not $ownEnv.CERT_PATH }}
- name: CERT_PATH
  value: {{ printf "%s/tls.crt" $mountPath | quote }}
{{- end }}
{{- if not $ownEnv.CERT_KEY_PATH }}
- name: CERT_KEY_PATH
  value: {{ printf "%s/tls.key" $mountPath | quote }}
{{- end }}
{{- else if eq $mode "env" }}
{{- $secret := $aws.credentialsSecret | default dict }}
{{- if not $ownEnv.AWS_ACCESS_KEY_ID }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ required "global.aws.credentialsSecret.name is required when authMode is env" $secret.name }}
      key: {{ $secret.accessKeyIdKey | default "AWS_ACCESS_KEY_ID" }}
{{- end }}
{{- if not $ownEnv.AWS_SECRET_ACCESS_KEY }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret.name }}
      key: {{ $secret.secretAccessKeyKey | default "AWS_SECRET_ACCESS_KEY" }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The volume and mount carrying the Roles Anywhere workload certificate.

Kept beside the env helper above because they are one decision: the cert is useless
unmounted, and CERT_PATH pointing at an empty directory fails at runtime rather than at
render time.

Only "iam-anywhere" mounts it: the other three modes never read a certificate, and
entrypoint.sh skips its setup entirely for them.

Gated on the subchart's own `aws.enabled` as well, because not every workload here talks
to AWS — the MCP server never does, and mounting a credential into a Pod that has no use
for it is a credential in one more place than necessary.
*/}}
{{- define "devops-ai.usesAws" -}}
{{- $aws := (.Values.global | default dict).aws | default dict -}}
{{- if and (eq ($aws.authMode | default "iam-anywhere") "iam-anywhere") ((.Values.aws | default dict).enabled) -}}
true
{{- end -}}
{{- end -}}

{{/*
ServiceAccount annotations for IRSA.

The role ARN is what ties this ServiceAccount to an IAM role; without it the EKS webhook
injects nothing and the SDK falls through to the instance profile — the node's role, which
is a quiet privilege escalation rather than a failure. That is why the annotation is
rendered from a named value instead of being spelled into a free-form `annotations` map:
a typo in the KEY produces no error at all, just a workload running as the node.

Per-service serviceAccount.roleArn wins over global.aws.irsa.roleArn. The two services do
not need the same role — the agent writes to SQS, the worker reads it and also holds the
GitHub credentials — so the global value is a convenience, not the model.

Rendered on the agent and the worker, never on the MCP server: its `aws.enabled` is false.
*/}}
{{- define "devops-ai.awsServiceAccountAnnotations" -}}
{{- $aws := (.Values.global | default dict).aws | default dict -}}
{{- if and (eq ($aws.authMode | default "iam-anywhere") "irsa") ((.Values.aws | default dict).enabled) }}
{{- $roleArn := (.Values.serviceAccount | default dict).roleArn | default ($aws.irsa | default dict).roleArn }}
eks.amazonaws.com/role-arn: {{ required "authMode is \"irsa\" but no role ARN is set. Set serviceAccount.roleArn on this service, or global.aws.irsa.roleArn for all of them." $roleArn | quote }}
{{- end }}
{{- end -}}

{{- define "devops-ai.awsCertVolume" -}}
{{- if include "devops-ai.usesAws" . }}
{{- $cert := ((.Values.global | default dict).aws | default dict).certificate | default dict }}
- name: aws-workload-cert
  secret:
    secretName: {{ $cert.secretName | default "workload-tls" }}
{{- end }}
{{- end -}}

{{- define "devops-ai.awsCertVolumeMount" -}}
{{- if include "devops-ai.usesAws" . }}
{{- $cert := ((.Values.global | default dict).aws | default dict).certificate | default dict }}
- name: aws-workload-cert
  mountPath: {{ $cert.mountPath | default "/certs" }}
  readOnly: true
{{- end }}
{{- end -}}

{{/*
The bundled backing services used to be addressed from here. They are not any more: the
agent's `database:` and `redis:` blocks derive DB_HOST and REDIS_HOST in the subchart's
own devops-ai-agent.derivedEnv, beside the port, name and password that go with them —
one block per concern rather than a host here and everything else there. The agent is the
only consumer either helper ever had, so nothing shared is left to define.
*/}}
