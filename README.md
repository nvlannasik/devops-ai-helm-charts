# devops-ai-helm-charts

Helm chart for the DevOps AI incident-investigation stack: the Slack agent, the MCP tool
server, and the SQS LLM worker, deployed as one release.

```
charts/devops-ai-stack/     umbrella chart
  charts/
    devops-ai-agent/        Slack bot + agentic investigation loop
    devops-mcp-server/      MCP tool server (Kubernetes, Prometheus, Loki, tracing)
    devops-llm-worker/      SQS consumer; bridge to a private LLM and to GitHub
    postgresql-*.tgz        Bitnami, optional
    redis-*.tgz             Bitnami, optional
examples/values-dev.yaml    the dev cluster, as chart values
examples/values-prod.yaml   a production shape: the other fork of every choice
```

## Why this chart exists

Every service here was already deployable — three HelmReleases of a generic chart with
about 170 lines of `extraEnvVars` between them. What that arrangement cannot do is notice
when the three stop agreeing.

The agent and the MCP server authenticate to each other with a shared bearer token, held
as a literal string in two different files. The agent and the worker meet on three SQS
queues named separately on each side. Each pair is a value that means nothing on its own
and everything in agreement — and a typo in any of them deploys perfectly, passes every
readiness probe, and fails at 3am inside an incident, which is the worst possible moment
to discover a configuration error.

So the chart's real payload is `templates/_validate.tpl`. It refuses to render when:

- the MCP token is missing, or set to different values on the two sides
- MCP transport is `http` on one side and something else on the other
- the MCP server registers its write tools without the RBAC to execute them, or holds
  cluster-wide write RBAC with no tool behind it, or enables them with an empty namespace
  allowlist — all three are a tool the agent will call and be refused, in a loop
- the MCP server names a tracing backend it does not implement, or `kubeconfig` auth with
  no kubeconfig, or in-cluster auth with its ServiceAccount token unmounted
- the SQS request, response, or GitOps queue names differ between agent and worker
- the agent has a `private-llm` backend but the worker is disabled — nothing would ever
  answer those messages
- the agent has GitOps remediation on while the worker is disabled, or has
  `gitops.enabled: false` — the agent holds no GitHub credentials by design, so every
  proposal it makes would be dropped by the one side that could act on it
- GitOps remediation is on without a queue for it
- `LLM_API_FORMAT` is neither `openai` nor `anthropic` (it names a wire format, not a
  vendor: a self-hosted model behind an OpenAI-compatible gateway is `openai`)
- the worker has no LLM endpoint or no model — both are read with a non-null assertion, so
  unset means a healthy Pod that crashes on its first message
- an OpenAI-only sampling parameter is set under the `anthropic` wire format, or the
  GitOps bridge is half-configured: credentials with no repo, a repo with no credentials,
  a GitHub App missing its installation ID or its private key, or a GitHub Enterprise URL
  with no `/api/v3` on it
- bundled Postgres is on without `auth.database` — the Bitnami chart only creates a
  database when that is set, and only on first init; migrations create tables, never the
  database itself
- the agent's database name and `postgresql.auth.database` disagree
- an LLM backend names a kind the agent's registry does not know, two backends answer to
  the same name, a route names a backend that was never declared, or one backend appears
  in both routes — failover is up-only, so a backend in both lanes makes the ordering
  meaningless
- `redis.enabled` is on with no host to reach it at

Each failure names the two values, shows what they are, and says which to change. They
fire in `helm template`, so CI and Flux's dry-run catch them before anything reaches a
cluster.

The other half is that shared values are written once. `global.sqs` and `global.aws`
render into both sides of their respective contracts, and `MCP_HTTP_URL` is derived from
the MCP server's own Service name and port rather than written a second time.

MCP is the deliberate exception: it is configured under `devops-ai-agent.mcp` and
`devops-mcp-server.mcp`, not under `global`. The contract is between exactly those two
services, so each states its own half — and the bearer token is therefore written twice.
That is safe only because `_validate.tpl` compares the two copies (literals, Secret refs,
transport, service name and port) and refuses to render when they differ.

## Install

```bash
helm dependency build charts/devops-ai-stack     # only if you change dependencies

helm install devops-ai charts/devops-ai-stack \
  -n devops-tools --create-namespace \
  -f examples/values-dev.yaml
```

The chart references Secrets but never creates them. `examples/values-dev.yaml` lists
which ones, and `helm install` prints the full list on success.

Two examples ship, and they are deliberately opposites. `values-dev.yaml` mirrors one real
cluster — IAM Roles Anywhere, hosted LLM APIs, a GitHub PAT, Postgres and Redis running as
their own Flux releases. `values-prod.yaml` takes the other fork of each of those: IRSA
with a role per workload, a `private-llm` backend over SQS, a GitHub App whose key is
mounted as a file, and the bundled subcharts. Between them every branch in the chart is
rendered by CI, so a path nobody deploys today cannot rot unnoticed.

## Publishing

Releases are cut by tag. `.github/workflows/release.yml` packages the chart and pushes it
to GHCR as an OCI artifact when a `v*` tag lands:

```bash
# bump version: in charts/devops-ai-stack/Chart.yaml first — the workflow refuses a tag
# that disagrees with it, because otherwise `v0.2.0` would republish 0.1.0 silently.
git tag v0.2.0 && git push origin v0.2.0
```

The result is `ghcr.io/nvlannasik/charts/devops-ai-stack:0.2.0`, installable directly:

```bash
helm install devops-ai oci://ghcr.io/nvlannasik/charts/devops-ai-stack \
  --version 0.2.0 -n devops-tools -f my-values.yaml
```

The workflow authenticates with the job's own `GITHUB_TOKEN`, so no secret needs
configuring. GHCR publishes a package **private** on first push: make it public under the
package's settings, or give the puller credentials — Flux needs an `OCIRepository`/
`HelmRepository` with a `secretRef` either way if it stays private. Pushing the tag also
runs `lint`, so the same commit is rendered before it reaches the registry, and the
workflow pulls the chart back after pushing — a push that reports success but leaves
nothing installable is the failure worth catching in CI.

## Configuration

Anything two services must agree on lives under `global:`; everything else lives under
the service's own key, as a named value object rather than a flat env map. A service's own
`env` (and `secretEnv`) always wins over any derived value, so an overlay can override one
variable without giving up the rest.

### The agent's settings are objects, not env vars

`devops-ai-agent` groups its configuration into `mcp`, `slack`, `alertWebhook`, `llm`,
`investigation`, `gitops`, `database`, `redis` and `dashboard`. Each renders the env vars
the agent actually reads, so related values that must agree cannot be set separately — the
dashboard's container port, Service port and `DASHBOARD_PORT` are one value, not three.

`llm.backends` is the largest of these. It is a list, rendered into the indexed
`LLM_BACKEND_<N>_*` variables the agent's registry parses:

```yaml
devops-ai-agent:
  llm:
    provider: router
    backends:
      - name: private-llm
        kind: private-llm           # takes the SQS path; needs devops-llm-worker
      - name: sonnet
        kind: claude                # claude | openai-compatible | private-llm
        model: claude-sonnet-4-5
        existingSecret: devops-agent-secret
        apiKeyKey: CLAUDE_KEY       # defaults to LLM_BACKEND_<N>_KEY
      - name: haiku
        kind: claude
        model: claude-haiku-4-5
        existingSecret: devops-agent-secret
        apiKeyKey: CLAUDE_KEY
    routes:
      heavy: [private-llm, sonnet]  # failover chain for investigations
      light: [haiku]                # cheap calls; never falls back onto heavy
```

The two lanes must be disjoint, and the chart enforces that. Failover is up-only, so a
backend named in both is an ordering that means nothing — and the reason to separate them
is that the heavy lane's fallback should be no weaker than what it replaces.

The indices must be contiguous from 1 — the registry stops reading at the first gap — and
a list has no gaps to introduce, because order here IS the index order. Writing those
twelve variables by hand is what made a deleted middle entry a silent router failure.

`env:` and `secretEnv:` are still there as escape hatches for anything the objects do not
model, and they win over the derived value of the same name.

### So are the MCP server's

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
chart now refuses to render when they disagree in either direction — see below.

### And the worker's

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

One asymmetry is worth knowing about, because the chart used to get it wrong. The agent
reads `MCP_TRANSPORT`; the server reads `TRANSPORT`. Two repos named one contract two
ways, so each side renders the variable its own code reads, and `_validate.tpl` compares
the values across that difference. A shared helper emitting `MCP_TRANSPORT` on both sides
produced a variable the server never reads: it rendered, it validated, and the Deployment
ran on whatever the image's own `ENV TRANSPORT=http` said.

| Key | Default | |
|---|---|---|
| `global.sqs.requestQueue` | `llm-request.fifo` | Agent writes, worker reads. |
| `global.sqs.responseQueue` | `llm-response.fifo` | Shared, routed by `requestId`. |
| `global.sqs.gitopsRequestQueue` | `gitops-request.fifo` | The PR-remediation contract. |
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
| `devops-mcp-server.rbac.allowWrite` | `false` | Cluster-wide write. See below. |
| `devops-mcp-server.rbac.allowFluxReconcile` | `false` | Lets `flux_reconcile` annotate HelmReleases. |
| `<service>.env.NODE_ENV` | `prod` | `prod`, not `production` — all three compare the string exactly. |

The backing-service switches are under `global` rather than beside the Bitnami values
because a subchart's templates can read only its own values plus `global` — the agent has
to see the flag in order to derive `DB_HOST`. Setting `postgresql.enabled` at the root
instead is a no-op, so the chart fails the render if it finds one. Everything else under
`postgresql:` and `redis:` is passed to the Bitnami charts as usual.

Both default to off, because the cluster this stack was built for already runs Postgres
and Redis as their own Flux HelmReleases; turning these on there yields a second Postgres
rather than a shared one. Turn them on for a fresh cluster or a demo.

### AWS credentials are one object

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

### Remediation is bounded twice

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

## Relationship to the GitOps repo

`gitops-devops-ai-manifest/` remains the source of truth for what runs in a cluster. This
chart is what a HelmRelease there can point at, replacing three separate releases with
one — which is what makes the cross-service checks possible, since they can only run
where all three sets of values are visible at once.
