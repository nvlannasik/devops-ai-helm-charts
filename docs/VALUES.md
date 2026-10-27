# Chart values

Anything two services must agree on lives under `global:`; everything else lives under
the service's own key, as a named value object rather than a flat env map. A service's own
`env` (and `secretEnv`) always wins over any derived value, so an overlay can override one
variable without giving up the rest. What the chart refuses to render: [VALIDATION.md](VALIDATION.md).

## Key reference

| Key | Default | |
|---|---|---|
| `global.sqs.requestQueue` | `llm-request.fifo` | Agent writes, worker reads. |
| `global.sqs.responseQueue` | `llm-response.fifo` | Shared, routed by `requestId`. |
| `global.sqs.gitopsRequestQueue` | `gitops-request.fifo` | The PR-remediation contract. |
| `global.tracing.enabled` | `false` | OpenTelemetry export from all three services. |
| `global.tracing.endpoint` | `""` | OTLP/HTTP base URL; required when enabled. |
| `global.tracing.sampler` | `""` | `OTEL_TRACES_SAMPLER`; empty keeps `parentbased_always_on`. |
| `global.aws.region` | `ap-southeast-1` | Where the queues and the credentials are. Was `global.sqs.region`. |
| `global.aws.authMode` | `iam-anywhere` | `iam-anywhere` \| `irsa` \| `env` \| `instance-profile`. Rendered as `AWS_AUTH_MODE`. |
| `global.aws.rolesAnywhere.configSecret.name` | `aws-rolesanywhere-config` | `iam-anywhere` only: Secret holding the trust anchor, profile and role ARNs. |
| `global.aws.certificate.create` | `false` | `iam-anywhere` only. On: cert-manager issues the workload cert here. Off: mount one issued elsewhere. |
| `global.aws.certificate.secretName` / `.mountPath` | `workload-tls` / `/certs` | `CERT_PATH` and `CERT_KEY_PATH` are derived from the mount path. |
| `<service>.serviceAccount.roleArn` | `""` | `irsa` only: that service's IAM role, as the `eks.amazonaws.com/role-arn` annotation. |
| `global.aws.irsa.roleArn` | `""` | `irsa` only: the default role, for services that name none. |
| `global.aws.credentialsSecret.name` | `""` | `env` only: a static access key. |
| `global.postgresql.enabled` | `false` | Deploy a Postgres here, and point the agent at it. |
| `global.redis.enabled` | `false` | Same, for Redis. |
| `devops-ai-agent.enabled` | `true` | |
| `devops-mcp-server.enabled` | `true` | |
| `devops-llm-worker.enabled` | `false` | Required for `private-llm` backends and GitOps PRs. |
| `devops-llm-worker.llm.baseUrl` | `""` | Required when the worker is on. Under `agent-builder` it is the full run endpoint, flow id included. |
| `devops-llm-worker.llm.model` | `""` | Required under `openai` and `anthropic`; rejected under `agent-builder`, where the flow owns it. |
| `devops-llm-worker.llm.apiFormat` | `openai` | `openai` \| `anthropic` \| `agent-builder` — the wire format. |
| `devops-llm-worker.gitops.repo` | `""` | The only repository the PR handler may touch. |
| `devops-mcp-server.rbac.allowWrite` | `false` | Cluster-wide write. See [remediation is bounded twice](#remediation-is-bounded-twice). |
| `devops-mcp-server.rbac.allowOrphanDelete` | `false` | Cluster-wide `delete` on ConfigMaps/Services/ServiceAccounts/Deployments/StatefulSets, for `k8s_delete_orphan`. See [`allowOrphanDelete`](#alloworphandelete). |
| `devops-mcp-server.rbac.allowFluxReconcile` | `false` | Lets `flux_reconcile` annotate HelmReleases. |
| `devops-mcp-server.rbac.readAllCustomResources` | `true` | `get`/`list` on all API groups, for the CRD cross-check in `k8s_find_unused_resources`. See [`readAllCustomResources`](#readallcustomresources). |
| `<service>.env.NODE_ENV` | `prod` | `prod`, not `production` — all three compare the string exactly. |

## The agent's values

The agent's settings are objects, not env vars. `devops-ai-agent` groups its configuration into
`mcp`, `slack`, `alertWebhook`, `llm`, `investigation`, `gitops`, `database`, `redis` and
`dashboard`. Each renders the env vars the agent actually reads, so related values that must
agree cannot be set separately — the dashboard's container port, Service port and
`DASHBOARD_PORT` are one value, not three. `dashboard.publicUrl` is independent of
`dashboard.enabled`: it only builds the link `@agent postmortem` posts to Slack
(`DASHBOARD_PUBLIC_URL`), rendered when set and omitted otherwise — the dashboard a link points
at doesn't have to be this release's own. `dashboard.tracingUiUrl` (`TRACING_UI_URL`) is the
Jaeger UI an incident's "Open in Jaeger" button links into; unset shows no button.

**Tracing** (`global.tracing`, 0.8.0): each image starts OpenTelemetry in a `node --import`
preload that is inert without `OTEL_EXPORTER_OTLP_ENDPOINT`, so `enabled: false` renders nothing
and changes nothing. Enabled, `endpoint` reaches all three Deployments (`OTEL_TRACES_SAMPLER` too
when `sampler` is set); the service names are baked into the images. A service's own `env` wins —
an llm-worker that cannot reach the collector sets its own endpoint, or an empty one.

`llm.backends` is the largest of these. It is a list, rendered into the indexed
`LLM_BACKEND_<N>_*` variables the agent's registry parses:

```yaml
devops-ai-agent:
  llm:
    provider: router
    backends:
      - name: private-llm
        kind: private-llm           # takes the SQS path; needs devops-llm-worker
        priceInput: 0.05            # optional, USD per 1M tokens — dashboard cost figures
        priceOutput: 0.4
        priceCacheRead: 0.005
      - name: chatgpt
        kind: openai-compatible     # claude | openai-compatible | private-llm
        model: gpt-5-nano
        baseUrl: https://api.openai.com/v1
        existingSecret: devops-agent-secret
        apiKeyKey: OPENAI_KEY       # defaults to LLM_BACKEND_<N>_KEY
        maxTokens: 16384
      - name: deepseek
        kind: openai-compatible
        model: deepseek-chat
        baseUrl: https://api.deepseek.com/v1
        existingSecret: devops-agent-secret
        apiKeyKey: DEEPSEEK_KEY
    routes:
      heavy: [private-llm, chatgpt]  # failover chain for investigations
      light: [deepseek]              # cheap calls; never falls back onto heavy
```

A backend without `priceInput`/`priceOutput` still has its tokens counted; the dashboard
shows it as `not priced`, never as `$0`.

The two lanes must be disjoint, and the chart enforces that. Failover is up-only, so a
backend named in both is an ordering that means nothing — and the reason to separate them
is that the heavy lane's fallback should be no weaker than what it replaces.

The indices must be contiguous from 1 — the registry stops reading at the first gap — and
a list has no gaps to introduce, because order here IS the index order. Writing those
twelve variables by hand is what made a deleted middle entry a silent router failure.

`slack` takes user IDs as lists and renders the comma-separated strings the agent parses.
`allowedUsers` is who may mention the agent at all — on-call and approvers are always
admitted too, and an empty list means anyone in the channel (the agent warns at boot):

```yaml
devops-ai-agent:
  slack:
    alertChannel: C0123456789
    oncallUsers: [U01AAAAAAAA]
    approverUsers: [U01AAAAAAAA]
    allowedUsers: [U01BBBBBBBB, U01CCCCCCCC]
```

`env:` and `secretEnv:` are still there as escape hatches for anything the objects do not
model, and they win over the derived value of the same name.

## The MCP server's values

`devops-mcp-server` groups its own into `mcp`, `kubernetes`, `writeTools`, `prometheus`,
`alertmanager`, `loki`, `tracing` and `limits`. Each upstream is one block — a URL beside
the Secret its credentials come from — rather than a name in `env:` and two loosely
related names in `secretEnv:`. The username and password are read as a pair, so naming one
without the other emits neither.

```yaml
devops-mcp-server:
  writeTools:
    enabled: true
    allowedNamespaces: [apps, payments]   # an ALLOWLIST; empty blocks everything
    maxScaleDelta: 5
  prometheus:
    url: http://prometheus.monitoring:9090
  tracing:
    backend: jaeger                        # tempo | jaeger — the query API
    url: http://jaeger-query.observability:16686
```

`writeTools.enabled` and `rbac.allowWrite` are the two bounds on remediation, and the
chart refuses to render when they disagree in either direction — see
[remediation is bounded twice](#remediation-is-bounded-twice).

## The worker's values

`devops-llm-worker` groups its own into `llm`, `sqs` and `gitops`.

```yaml
devops-llm-worker:
  llm:
    apiFormat: openai              # the WIRE format — vLLM and LiteLLM are both "openai"
    baseUrl: http://vllm.llm:8000/v1
    model: qwen2.5-coder-32b-instruct
    sampling:
      temperature: 0.2
  gitops:
    enabled: true
    repo: my-org/gitops-devops-ai-manifest    # the only repo the handler may touch
    auth:
      githubApp:                              # or auth.tokenSecret for a PAT
        appId: "123456"
        installationId: "7890123"
        privateKeySecret: {name: github-app-key, key: private-key.pem}
```

Two things here are checked rather than documented. `sampling.reasoningEffort`, `seed` and
`useMaxCompletionTokens` are sent on the OpenAI path only — `src/anthropic.ts` sends
`temperature` and `top_p` and nothing else — so the chart renders them only under
`apiFormat: openai` and rejects them under `anthropic`, where an endpoint that validates
its request body answers 400 to every message.

`agent-builder` is the same rule one step further out, and it takes more with it. That path
posts a Langflow run endpoint whose whole envelope is `input_type`, `output_type`,
`input_value` and `session_id` — there is no field for a model name, a token cap or any
sampling parameter, because all of those belong to the flow's own Model component and are
set in the platform UI. So the chart **rejects** `model`, `maxTokens` and every `sampling`
key under that format rather than rendering them into a Deployment where they would look
authoritative and change nothing. For the same reason `model` is *required* under the other
two formats and must be *absent* under this one. Two more differences worth knowing:
`baseUrl` is the full run endpoint including the flow id (`https://<host>/api/v1/run/<flow-id>`),
not a `/v1` base, and `LLM_API_KEY` goes out as an `x-api-key` header.

And `gitops.enabled` is not a value the worker reads: its config *derives* the flag from
`(GITHUB_TOKEN || GITHUB_APP_ID) && GITOPS_REPO`. A half-configured bridge therefore does
not fail — it boots, logs itself as disabled, and drops every proposal the agent queues
while the agent waits for an answer. The chart requires the pieces together instead.

The GitHub App's private key is mounted as a file rather than passed inline. A multi-line
PEM survives an env var, but it is also the one credential here that `kubectl describe pod`
would print in full.

## Backing services

The backing-service switches are under `global` rather than beside the Bitnami values
because a subchart's templates can read only its own values plus `global` — the agent has
to see the flag in order to derive `DB_HOST`. Setting `postgresql.enabled` at the root
instead is a no-op, so the chart fails the render if it finds one. Everything else under
`postgresql:` and `redis:` is passed to the Bitnami charts as usual.

Both default to off, because the cluster this stack was built for already runs Postgres
and Redis as their own Flux HelmReleases; turning these on there yields a second Postgres
rather than a shared one. Turn them on for a fresh cluster or a demo.

## AWS credentials are one object

The agent and the worker meet on SQS, so they need the same region and credentials for the
same account — that is one decision, not two. `global.aws` states it once and both
Deployments render from it. Split across the two sides it was six `secretEnv` entries and
two `CERT_*` env vars written twice, with nothing to compare them against.

`authMode` is the load-bearing value, and it is an enum rather than a set of switches
because it is one half of a contract with the images. `entrypoint.sh` — byte-identical in
the agent and the worker — dispatches on `AWS_AUTH_MODE` and has exactly these four
branches. Rendering one mode's credentials while the script runs another does not degrade
gracefully: `iam-anywhere` is the image's own default and it `exit 1`s on a missing ARN or
an unreadable certificate, so the Pod CrashLoops before Node starts. The chart therefore
always states the mode, renders only that mode's inputs, and rejects the others.

| `authMode` | What the workload presents | What you set |
| --- | --- | --- |
| `iam-anywhere` | An X.509 workload certificate, exchanged for temporary credentials by `aws_signing_helper`. No long-lived key in the cluster. | `rolesAnywhere.configSecret`, `certificate` |
| `irsa` | A projected service-account token, on EKS. Also no long-lived key. | `irsa.roleArn` |
| `env` | A static access key. Local dev and clusters with neither of the above. | `credentialsSecret` |
| `instance-profile` | The node's own role, from instance metadata. | nothing |

Under `iam-anywhere` the Certificate is issued at the umbrella level, not inside a
subchart: two Certificates from one issuer for one identity are two things that rotate
separately and drift.

`irsa` needs only the `eks.amazonaws.com/role-arn` annotation. Because the role belongs to
a ServiceAccount, it is set there — as a named field, not as free-form annotation text:

```yaml
global:
  aws:
    authMode: irsa

devops-ai-agent:
  serviceAccount:
    roleArn: arn:aws:iam::123456789012:role/devops-ai-agent
devops-llm-worker:
  serviceAccount:
    roleArn: arn:aws:iam::123456789012:role/devops-llm-worker
```

Prefer a role per service. The agent writes to SQS; the worker reads it, calls the LLM
endpoint, and holds the GitHub credentials — one role for both grants each of them the
other's permissions. `global.aws.irsa.roleArn` is the shared fallback for the case where
that separation does not exist yet.

The annotation is a named value because its KEY is load-bearing and misspelling it raises
no error: the webhook injects nothing, the SDK falls through to the node's instance
profile, and the workload runs with the node's permissions. Rendering the key from the
chart removes that failure mode; `serviceAccount.annotations` still takes anything else and
is merged with it.

IRSA does **not** need `automountServiceAccountToken`. The EKS pod-identity webhook injects
its own projected volume, while automount governs the default kube-api token — a different
one. So these two workloads keep automount off and hold no Kubernetes credentials at all.

Values belonging to a mode other than the selected one are rejected rather than ignored:
a `credentialsSecret` under `authMode: irsa` would be a long-lived credential sitting in
the cluster that nothing reads.

Which workloads get any of this is `aws.enabled` in each subchart's own values — on for
the agent and the worker, off for the MCP server. The MCP server's credentials are
Kubernetes ones; it never calls an AWS API, so it gets no ARNs and no certificate mounted
into its Pod. A credential in a Pod that has no use for it is a credential in one more
place than necessary.

## Remediation is bounded twice

`devops-mcp-server.rbac.allowWrite` grants the ServiceAccount cluster-wide write. The
inner bound is `writeTools.enabled` and its `allowedNamespaces`. Narrowing the namespace
list does not narrow what the ServiceAccount may do — only RBAC does that. `helm install`
prints a warning whenever write access is on.

The two live in different subsystems and neither can see the other, so the chart compares
them: enabling one without the other fails the render. This is not tidiness. The inner
switch controls **registration**, not authorization — the agent caches `listTools()` at
startup, so a tool that is listed and then refused is one the model keeps choosing and
keeps failing on, mid-incident, until the investigation times out. An empty
`allowedNamespaces` is the same failure one layer in: it is an allowlist, so empty refuses
everything. RBAC granted with no tool behind it is the mirror image — a standing mutating
credential nothing in the release can use.

`kube-system`, `kube-public`, `kube-node-lease` and `flux-system` are refused by the
server whatever `allowedNamespaces` says. Flux-managed workloads are reached through
`flux_reconcile` and the GitOps PR flow instead, because a direct write there is reverted
on the next reconcile.

The MCP server is the only workload in the stack that holds Kubernetes credentials; the
agent reaches the cluster solely through it.

### `allowOrphanDelete`

A separate switch from `allowWrite`, and the separation is the point.

`allowWrite` grants `patch`/`update` plus `delete` on **pods**, and every one of those is
recoverable: a patched Deployment can be patched back, a deleted pod is recreated by its
controller. `allowOrphanDelete` grants `delete` on ConfigMaps, Services, ServiceAccounts,
Deployments and StatefulSets — objects with no controller behind them, so nothing recreates what
it removes. An operator enabling remediation for rolling restarts must not acquire that by
implication, which is why turning on `allowWrite` does not turn this on.

The kind list is exactly the set a stored manifest restores. `secrets` and
`persistentvolumeclaims` are absent, and `k8s_delete_orphan` refuses them regardless of RBAC: a
Secret's backup **is** its credentials, so storing one to make the delete reversible copies them
somewhere they do not belong; and a PVC's manifest is not its data, so re-applying it returns an
empty volume.

The tool captures the object's manifest immediately before deleting it, stores it on the
`remediations` row that authorised the action, and posts it into the Slack thread. That copy is
the undo.

The chart fails the render when `allowOrphanDelete` is true and `writeTools.enabled` is false —
a standing delete credential with no consumer. The opposite direction is allowed on purpose:
write tools without this grant means `k8s_delete_orphan` registers and refuses on RBAC, which is
the correct outcome for someone who wants restarts but not deletions.

### `readAllCustomResources`

On by default, and it is a **read** grant: `get`/`list` on `apiGroups: ["*"], resources: ["*"]`.
No value of this flag emits a mutating verb.

It exists for one tool. Before `k8s_find_unused_resources` reports a ConfigMap or Secret as
unused, it looks for that name in every custom resource in the cluster — an operator that
references an object **by name** leaves no `ownerReference` and no pod reference, so reading the
CRs is the only way to see it. Which API groups an operator will occupy is not knowable from a
chart, hence the wildcard.

Turning it off does not break the tool: it reports the CRDs it could not read in
`crossCheck.crdsUnreadable` and downgrades its own note from "not referenced" to "not referenced
as far as I could look". That is the honest claim, but not a useful one to act on. Turn it off if
your cluster's policy forbids the wildcard, and expect the cleanup list to stay advisory.

The marginal exposure is smaller than the wildcard suggests: the rules above this one already
grant cluster-wide read on **Secrets**, which is the sensitive part of "read everything".
