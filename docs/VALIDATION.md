# What the chart refuses to render

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
- `LLM_API_FORMAT` is not `openai`, `anthropic` or `agent-builder` (it names a wire format,
  not a vendor: a self-hosted model behind an OpenAI-compatible gateway is `openai`)
- the worker has no LLM endpoint or no model — both are read with a non-null assertion, so
  unset means a healthy Pod that crashes on its first message
- an OpenAI-only sampling parameter is set under the `anthropic` wire format, a parameter
  the Langflow envelope cannot carry is set under `agent-builder`, or the
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

The why behind several of these lives with the values they guard, in [VALUES.md](VALUES.md):
the wire-format rules under [the worker's values](VALUES.md#the-workers-values), the write
bounds under [remediation is bounded twice](VALUES.md#remediation-is-bounded-twice), the
`global.postgresql` switch under [backing services](VALUES.md#backing-services).

## Shared values are written once

The other half is that shared values are written once. `global.sqs`, `global.aws` and
`global.tracing` render into both sides of their respective contracts (tracing into all three,
and `enabled` without an `endpoint` fails the render), and `MCP_HTTP_URL` is derived from
the MCP server's own Service name and port rather than written a second time.

MCP is the deliberate exception: it is configured under `devops-ai-agent.mcp` and
`devops-mcp-server.mcp`, not under `global`. The contract is between exactly those two
services, so each states its own half — and the bearer token is therefore written twice.
That is safe only because `_validate.tpl` compares the two copies (literals, Secret refs,
transport, service name and port) and refuses to render when they differ.

One asymmetry is worth knowing about, because the chart used to get it wrong. The agent
reads `MCP_TRANSPORT`; the server reads `TRANSPORT`. Two repos named one contract two
ways, so each side renders the variable its own code reads, and `_validate.tpl` compares
the values across that difference. A shared helper emitting `MCP_TRANSPORT` on both sides
produced a variable the server never reads: it rendered, it validated, and the Deployment
ran on whatever the image's own `ENV TRANSPORT=http` said.
