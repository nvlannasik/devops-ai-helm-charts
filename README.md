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
- the SQS request, response, or GitOps queue names differ between agent and worker
- the agent has a `private-llm` backend but the worker is disabled — nothing would ever
  answer those messages
- the agent has GitOps remediation on while the worker is disabled, or has
  `gitops.enabled: false` — the agent holds no GitHub credentials by design, so every
  proposal it makes would be dropped by the one side that could act on it
- GitOps remediation is on without a queue for it
- `LLM_API_FORMAT` is neither `openai` nor `anthropic` (it names a wire format, not a
  vendor: a self-hosted model behind an OpenAI-compatible gateway is `openai`)
- bundled Postgres is on without `auth.database` — the Bitnami chart only creates a
  database when that is set, and only on first init; migrations create tables, never the
  database itself
- the agent's `DB_NAME` and `postgresql.auth.database` disagree

Each failure names the two values, shows what they are, and says which to change. They
fire in `helm template`, so CI and Flux's dry-run catch them before anything reaches a
cluster.

The other half is that shared values are written once. `MCP_HTTP_URL` is derived from the
MCP server's own Service name and port, so it cannot drift. `global.mcp` and `global.sqs`
render into both sides of their respective contracts.

## Install

```bash
helm dependency build charts/devops-ai-stack     # only if you change dependencies

helm install devops-ai charts/devops-ai-stack \
  -n devops-tools --create-namespace \
  -f examples/values-dev.yaml \
  --set global.mcp.authTokenSecret.name=devops-agent-secret
```

The chart references Secrets but never creates them. `examples/values-dev.yaml` lists
which ones, and `helm install` prints the full list on success.

## Configuration

Anything two services must agree on lives under `global:`; everything else lives under
the service's own key. A service's own `env` always wins over a `global`-derived value,
so an overlay can override one variable without giving up the shared defaults.

| Key | Default | |
|---|---|---|
| `global.mcp.authToken` | `""` | Shared bearer token. Prefer `authTokenSecret`. |
| `global.mcp.authTokenSecret.name` / `.key` | `""` / `MCP_AUTH_TOKEN` | Read the token from an existing Secret. |
| `global.mcp.url` | `""` | Only if the MCP server lives outside this release. Otherwise derived. |
| `global.sqs.requestQueue` | `llm-request.fifo` | Agent writes, worker reads. |
| `global.sqs.responseQueue` | `llm-response.fifo` | Shared, routed by `requestId`. |
| `global.sqs.gitopsRequestQueue` | `gitops-request.fifo` | The PR-remediation contract. |
| `global.postgresql.enabled` | `false` | Deploy a Postgres here, and point the agent at it. |
| `global.redis.enabled` | `false` | Same, for Redis. |
| `devops-ai-agent.enabled` | `true` | |
| `devops-mcp-server.enabled` | `true` | |
| `devops-llm-worker.enabled` | `false` | Required for `private-llm` backends and GitOps PRs. |
| `devops-mcp-server.rbac.allowWrite` | `false` | Cluster-wide write. See below. |
| `devops-mcp-server.rbac.allowFluxReconcile` | `false` | Lets `flux_reconcile` annotate HelmReleases. |

The backing-service switches are under `global` rather than beside the Bitnami values
because a subchart's templates can read only its own values plus `global` — the agent has
to see the flag in order to derive `DB_HOST`. Setting `postgresql.enabled` at the root
instead is a no-op, so the chart fails the render if it finds one. Everything else under
`postgresql:` and `redis:` is passed to the Bitnami charts as usual.

Both default to off, because the cluster this stack was built for already runs Postgres
and Redis as their own Flux HelmReleases; turning these on there yields a second Postgres
rather than a shared one. Turn them on for a fresh cluster or a demo.

### Remediation is bounded twice

`devops-mcp-server.rbac.allowWrite` grants the ServiceAccount cluster-wide write. The
inner bound is `MCP_ENABLE_WRITE_TOOLS` and `ALLOWED_REMEDIATION_NAMESPACES` in the
server's env. Narrowing the namespace list does not narrow what the ServiceAccount may
do — only RBAC does that. `helm install` prints a warning whenever write access is on.

The MCP server is the only workload in the stack that holds Kubernetes credentials; the
agent reaches the cluster solely through it.

## Relationship to the GitOps repo

`gitops-devops-ai-manifest/` remains the source of truth for what runs in a cluster. This
chart is what a HelmRelease there can point at, replacing three separate releases with
one — which is what makes the cross-service checks possible, since they can only run
where all three sets of values are visible at once.
