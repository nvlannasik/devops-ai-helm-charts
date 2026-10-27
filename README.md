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

The three services meet on values that mean nothing alone and everything in agreement — the
MCP bearer token, the SQS queue names, the GitOps bridge. Split across three HelmReleases a
typo in any of them deploys perfectly and fails at 3am inside an incident. So the chart's real
payload is `templates/_validate.tpl`: it **refuses to render** when the two sides of a contract
disagree, and it fires in `helm template`, so CI and Flux's dry-run catch it before anything
reaches a cluster. Shared values are written once (`global.sqs`, `global.aws`, a derived
`MCP_HTTP_URL`).

The full list of refusals, and why each one exists: [docs/VALIDATION.md](docs/VALIDATION.md).

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

## Configuration

Anything two services must agree on lives under `global:`; everything else lives under the
service's own key, as a named value object rather than a flat env map. A service's own `env`
(and `secretEnv`) always wins over any derived value.

Every key, the per-service value objects (`llm.backends`, `writeTools`, the worker's wire
formats), AWS auth modes, the backing-service switches and the two bounds on remediation:
[docs/VALUES.md](docs/VALUES.md).

## Publishing

Releases are cut by tag. `.github/workflows/release.yml` packages the chart and pushes it
to GHCR as an OCI artifact when a `v*` tag lands:

```bash
# bump version: in charts/devops-ai-stack/Chart.yaml first — the workflow refuses a tag
# that disagrees with it, because otherwise `v0.7.0` would republish 0.6.0 silently.
git tag v0.7.0 && git push origin v0.7.0
```

The result is `ghcr.io/nvlannasik/charts/devops-ai-stack:<version>`, installable directly:

```bash
helm install devops-ai oci://ghcr.io/nvlannasik/charts/devops-ai-stack \
  --version 0.8.0 -n devops-tools -f my-values.yaml
```

The workflow authenticates with the job's own `GITHUB_TOKEN`, so no secret needs
configuring. GHCR publishes a package **private** on first push: make it public under the
package's settings, or give the puller credentials — Flux needs an `OCIRepository`/
`HelmRepository` with a `secretRef` either way if it stays private. Pushing the tag also
runs `lint`, so the same commit is rendered before it reaches the registry, and the
workflow pulls the chart back after pushing — a push that reports success but leaves
nothing installable is the failure worth catching in CI.

## Relationship to the GitOps repo

`gitops-devops-ai-manifest/` remains the source of truth for what runs in a cluster. This
chart is what a HelmRelease there can point at, replacing three separate releases with
one — which is what makes the cross-service checks possible, since they can only run
where all three sets of values are visible at once.
