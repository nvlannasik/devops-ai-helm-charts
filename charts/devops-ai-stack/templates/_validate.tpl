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

{{/* Read a setting the way the Deployment renders it: the object states it, and the
     service's own `env` map is the escape hatch that wins. Anything read from a value
     object here MUST honour that override, or this file will reject a release that would
     have deployed correctly — the worst kind of false positive, since the render is the
     only thing standing between a typo and 3am. */}}
{{- $agentEnvAll := merge (dict) ($agent.env | default dict) ($agent.secretEnv | default dict) -}}
{{- $agentGitopsOn := ternary (eq ($agentEnvAll.GITOPS_REMEDIATION_ENABLED | toString) "true") (($agent.gitops | default dict).enabled | default false) (hasKey $agentEnvAll "GITOPS_REMEDIATION_ENABLED") -}}

{{/* ---- agent <-> mcp-server: the two halves of the MCP contract ----

This block is the reason MCP configuration may live under each service instead of under
`global`. Each side states its own transport and token; these checks are what make the
second copy safe. Read each side the way its Deployment does — the service's own `mcp:`
block, with `env.MCP_*` as the override that wins.
*/}}
{{- $agentMcp := $agent.mcp | default dict -}}
{{- $mcpMcp := $mcp.mcp | default dict -}}
{{- $agentMcpEnv := merge (dict) ($agent.env | default dict) ($agent.secretEnv | default dict) -}}
{{- $mcpMcpEnv := merge (dict) ($mcp.env | default dict) ($mcp.secretEnv | default dict) -}}

{{- if and $agentOn $mcpOn -}}
  {{/* A token is "set" when the side has a literal, a Secret to read one from, or its own
       env override — the last of which may be a secretEnv entry, so compare only the
       literals below. */}}
  {{- $agentTok := $agentMcp.authToken -}}
  {{- $mcpTok := $mcpMcp.authToken -}}
  {{- $agentHas := or $agentTok ($agentMcp.authTokenSecret | default dict).name (hasKey $agentMcpEnv "MCP_AUTH_TOKEN") -}}
  {{- $mcpHas := or $mcpTok ($mcpMcp.authTokenSecret | default dict).name (hasKey $mcpMcpEnv "MCP_AUTH_TOKEN") -}}
  {{- if not (and $agentHas $mcpHas) -}}
    {{- fail "\n\nMCP auth token is not set on both sides.\n\nThe agent and the MCP server authenticate over HTTP with a shared bearer token, and each states its own copy:\n\n  devops-ai-agent:\n    mcp:\n      authTokenSecret: { name: devops-agent-secret, key: MCP_AUTH_TOKEN }\n  devops-mcp-server:\n    mcp:\n      authTokenSecret: { name: devops-agent-secret, key: MCP_AUTH_TOKEN }\n\nPointing both at the same Secret key is the way to keep one value while writing it twice. For a throwaway install, --set devops-ai-agent.mcp.authToken=<v> --set devops-mcp-server.mcp.authToken=<v> works too.\n\nThis is not optional: the MCP server exposes the cluster's read and write tools, so an unauthenticated one is a way in, not a degraded mode.\n" -}}
  {{- end -}}
  {{- if and $agentTok $mcpTok (ne $agentTok $mcpTok) -}}
    {{- fail (printf "\n\nMCP auth token mismatch.\n\n  devops-ai-agent.mcp.authToken     = %q\n  devops-mcp-server.mcp.authToken   = %q\n\nThese must be identical — the agent sends this token as a bearer and the server compares it. Different values means every tool call returns 401 and every investigation dies on its first tool.\n\nPoint both sides at the same authTokenSecret instead of maintaining two literals.\n" $agentTok $mcpTok) -}}
  {{- end -}}
  {{/* Two Secrets are as much a mismatch as two literals, and a quieter one: both sides
       render, both mount something, and only the 401s say otherwise. */}}
  {{- $agentRef := $agentMcp.authTokenSecret | default dict -}}
  {{- $mcpRef := $mcpMcp.authTokenSecret | default dict -}}
  {{- if and $agentRef.name $mcpRef.name -}}
    {{- $a := printf "%s/%s" $agentRef.name ($agentRef.key | default "MCP_AUTH_TOKEN") -}}
    {{- $b := printf "%s/%s" $mcpRef.name ($mcpRef.key | default "MCP_AUTH_TOKEN") -}}
    {{- if ne $a $b -}}
      {{- fail (printf "\n\nMCP auth token Secrets differ.\n\n  devops-ai-agent.mcp.authTokenSecret     = %s\n  devops-mcp-server.mcp.authTokenSecret   = %s\n\nNothing here can compare what is INSIDE two Secrets, so pointing the two sides at different keys is a mismatch this chart cannot catch later: both Pods start, and every tool call returns 401.\n\nPoint both at the same Secret and key.\n" $a $b) -}}
    {{- end -}}
  {{- end -}}

  {{/* Transport — one contract, two variable names.

       The agent reads MCP_TRANSPORT; the server reads TRANSPORT. Two repos that named the
       same decision differently, so each side renders the name its own code reads and this
       is the only place the two are held against each other. Read each through its OWN
       name, including in the env escape hatch: reading the server's side as MCP_TRANSPORT
       is exactly the bug this check exists to catch — it compared a variable the server
       never reads, so it passed while the Deployment ran on whatever the image's
       `ENV TRANSPORT=http` happened to say. */}}
  {{- $agentTransport := $agentMcpEnv.MCP_TRANSPORT | default $agentMcp.transport | default "http" -}}
  {{- $mcpTransport := $mcpMcpEnv.TRANSPORT | default $mcpMcp.transport | default "http" -}}
  {{- if ne $agentTransport $mcpTransport -}}
    {{- fail (printf "\n\nMCP transport mismatch: agent speaks %q, server speaks %q.\n\n  devops-ai-agent.mcp.transport      # rendered as MCP_TRANSPORT\n  devops-mcp-server.mcp.transport    # rendered as TRANSPORT — the server's own name for it\n\nBoth must be \"http\" when they run as separate Deployments — \"stdio\" only works when the server is a child process of the agent, which it is not here.\n" $agentTransport $mcpTransport) -}}
  {{- end -}}
  {{- if ne $agentTransport "http" -}}
    {{- fail (printf "\n\nmcp.transport is %q, but this chart deploys the MCP server as its own Deployment reached over the network.\n\nUse \"http\".\n" $agentTransport) -}}
  {{- end -}}

  {{/* The address. MCP_HTTP_URL is derived from the agent's serviceName/namespace/port,
       and the Service is named from the mcp-server subchart's own fullnameOverride. Set
       one without the other and the agent dials a name that does not resolve — a DNS
       failure on the first tool call of the first investigation, not at deploy time. */}}
  {{- if not $agentMcp.url -}}
    {{- $target := $agentMcp.serviceName | default "devops-mcp-server" -}}
    {{- $actual := $mcp.fullnameOverride | default "" -}}
    {{- if and $actual (ne $target $actual) -}}
      {{- fail (printf "\n\nThe agent is pointed at an MCP Service that this release does not create.\n\n  devops-ai-agent.mcp.serviceName        = %q   # what the agent dials\n  devops-mcp-server.fullnameOverride     = %q   # what the Service is called\n\nSet them to the same name, or set devops-ai-agent.mcp.url explicitly if the agent should reach an MCP server outside this release.\n" $target $actual) -}}
    {{- end -}}
    {{- $agentPort := $agentMcp.port | default 3000 -}}
    {{- $mcpPort := ($mcp.service | default dict).port | default 3000 -}}
    {{- if ne ($agentPort | toString) ($mcpPort | toString) -}}
      {{- fail (printf "\n\nMCP port mismatch.\n\n  devops-ai-agent.mcp.port        = %v   # what the agent dials\n  devops-mcp-server.service.port  = %v   # what the Service listens on\n\nThe agent's MCP_HTTP_URL is built from its own value, so these must agree.\n" $agentPort $mcpPort) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* ---- mcp-server: the two bounds on remediation must agree ----

Write access is gated twice and the gates live in different subsystems: `rbac.allowWrite`
renders the ClusterRole's mutating verbs, and `writeTools.enabled` decides whether the
tools exist at all. Each is checkable on its own — neither can see the other — so the
agreement between them is checkable only here.

This is not a style preference. Registration is not authorization: the agent caches
listTools() at startup, so a write tool the server registers and RBAC then refuses is a
tool the model keeps choosing and keeps failing on, mid-incident, until the investigation
times out. And RBAC granted with no tool behind it is cluster-wide write access that
nothing in the release can use.
*/}}
{{- if $mcpOn -}}
  {{- $mcpEnvAll := merge (dict) ($mcp.env | default dict) ($mcp.secretEnv | default dict) -}}
  {{- $write := $mcp.writeTools | default dict -}}
  {{- $rbac := $mcp.rbac | default dict -}}
  {{- $writeOn := ternary (eq ($mcpEnvAll.MCP_ENABLE_WRITE_TOOLS | toString) "true") ($write.enabled | default false) (hasKey $mcpEnvAll "MCP_ENABLE_WRITE_TOOLS") -}}
  {{- $rbacWrite := $rbac.allowWrite | default false -}}

  {{- if and $writeOn (not $rbacWrite) -}}
    {{- fail "\n\ndevops-mcp-server.writeTools.enabled is true, but rbac.allowWrite is false.\n\nThe write tools would be REGISTERED and then refused by the Kubernetes API. That is worse than either bound alone: the agent caches listTools() at startup, so the model sees the tool, calls it, gets 403, and calls it again — an investigation that loops instead of reporting.\n\nSet devops-mcp-server.rbac.allowWrite: true to grant the verbs, or writeTools.enabled: false so the tools are not offered.\n" -}}
  {{- end -}}
  {{- if and $rbacWrite (not $writeOn) -}}
    {{- fail "\n\ndevops-mcp-server.rbac.allowWrite is true, but writeTools.enabled is false.\n\nThe ClusterRole grants cluster-wide patch/update/delete and nothing in this release can use it — a standing mutating credential with no consumer.\n\nSet writeTools.enabled: true (with allowedNamespaces) if remediation is wanted, or rbac.allowWrite: false.\n" -}}
  {{- end -}}
  {{/* An allowlist, not a denylist: empty blocks everything. The tools would register and
       refuse every call — the same loop as the RBAC case, one layer in. */}}
  {{- if and $writeOn (not (hasKey $mcpEnvAll "ALLOWED_REMEDIATION_NAMESPACES")) (not ($write.allowedNamespaces | default list)) -}}
    {{- fail "\n\ndevops-mcp-server.writeTools.enabled is true but allowedNamespaces is empty.\n\nThat list is an ALLOWLIST — empty means every namespace is refused, so the write tools register and then decline every call. The model sees them, uses them, and gets a refusal each time.\n\nName the namespaces remediation may touch:\n\n  devops-mcp-server:\n    writeTools:\n      allowedNamespaces: [default, apps]\n\nkube-system, kube-public, kube-node-lease and flux-system are refused whatever this list says.\n" -}}
  {{- end -}}

  {{/* The tracing backend names a QUERY API, and the two are not interchangeable. An
       unknown value throws inside the adapter on the first trace lookup — mid-investigation,
       not at deploy. */}}
  {{- $backend := $mcpEnvAll.TRACING_BACKEND | default ($mcp.tracing | default dict).backend | default "tempo" -}}
  {{- if not (has $backend (list "tempo" "jaeger")) -}}
    {{- fail (printf "\n\ndevops-mcp-server.tracing.backend is %q, which the server does not implement.\n\nValid values: \"tempo\" or \"jaeger\" — the query API to speak.\n\nAn OTel Collector is not a value here: it only ingests. Point this at the store the collector exports to.\n" $backend) -}}
  {{- end -}}

  {{/* How it reaches the Kubernetes API. Two values, and "kubeconfig" needs a file that
       this chart does not mount for you. */}}
  {{- $k8s := $mcp.kubernetes | default dict -}}
  {{- $k8sMode := $mcpEnvAll.K8S_AUTH_MODE | default $k8s.authMode | default "kubeconfig" -}}
  {{- if not (has $k8sMode (list "incluster" "kubeconfig")) -}}
    {{- fail (printf "\n\ndevops-mcp-server.kubernetes.authMode is %q.\n\nValid values:\n  incluster   the Pod's own ServiceAccount token — what this chart deploys\n  kubeconfig  a mounted kubeconfig file\n" $k8sMode) -}}
  {{- end -}}
  {{- if eq $k8sMode "kubeconfig" -}}
    {{- if not ($mcpEnvAll.K8S_KUBECONFIG_PATH | default $k8s.kubeconfigPath) -}}
      {{- fail "\n\ndevops-mcp-server.kubernetes.authMode is \"kubeconfig\" but no kubeconfigPath is set.\n\nIn a cluster the answer is almost always authMode: \"incluster\" — the ServiceAccount and ClusterRole this chart already renders. Use kubeconfig only when pointing at a cluster this Pod does not run in, and mount the file yourself with extraVolumes/extraVolumeMounts.\n" -}}
    {{- end -}}
  {{- else if not ($mcp.serviceAccount | default dict).automountServiceAccountToken -}}
    {{- fail "\n\ndevops-mcp-server.kubernetes.authMode is \"incluster\" but serviceAccount.automountServiceAccountToken is false.\n\nIn-cluster auth IS that token. Without it mounted, the client has no credentials and every Kubernetes tool fails on its first call — the Pod starts and reports itself healthy.\n" -}}
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
  {{- if $agentGitopsOn -}}
    {{- $agentGq := $agentEnv.SQS_GITOPS_REQUEST_QUEUE_NAME | default $gq.gitopsRequestQueue -}}
    {{- $workerGq := $workerEnv.SQS_GITOPS_REQUEST_QUEUE_NAME | default $gq.gitopsRequestQueue -}}
    {{- if not (and $agentGq $workerGq) -}}
      {{- fail "\n\ndevops-ai-agent.gitops.enabled is true but the GitOps request queue is not set on both sides.\n\nSet global.sqs.gitopsRequestQueue, or set SQS_GITOPS_REQUEST_QUEUE_NAME in both devops-ai-agent.env and devops-llm-worker.env.\n\nWithout it the agent will open GitOps proposals that no worker ever picks up.\n" -}}
    {{- end -}}
    {{- if and $agentGq $workerGq (ne $agentGq $workerGq) -}}
      {{- fail (printf "\n\nSQS GitOps request queue mismatch.\n\n  devops-ai-agent    SQS_GITOPS_REQUEST_QUEUE_NAME = %q\n  devops-llm-worker  SQS_GITOPS_REQUEST_QUEUE_NAME = %q\n\nSet global.sqs.gitopsRequestQueue once.\n" $agentGq $workerGq) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* ---- more than one private LLM: one request queue per MODEL ----

The pair check above is the whole story only while there is one private LLM. With two, the
queue is what makes a model reachable: the agent's route picks a NAME, the name carries a
queue, and the worker on that queue is the model that answers. Point two backends at one
queue and the route becomes a coin flip — whichever worker grabs the message first replies,
and the symptom is an answer from the wrong model, which reads as a bad answer rather than
as a misconfiguration. That is precisely the class of bug this file exists to move from 3am
to CI.

This is also the one agreement neither side can check alone. The agent knows which queues it
writes to and llm-worker knows which one it polls; only the umbrella sees both lists.
*/}}
{{- if and $agentOn $workerOn -}}
  {{- $gq := ($g.sqs) | default dict -}}
  {{- $workerEnv := $worker.env | default dict -}}
  {{- $globalReq := $agentEnvAll.SQS_REQUEST_QUEUE_NAME | default $gq.requestQueue -}}

  {{- $privates := list -}}
  {{- range $b := (($agent.llm | default dict).backends | default list) -}}
    {{- if eq ($b.kind | default "") "private-llm" -}}
      {{- $privates = append $privates $b -}}
    {{- end -}}
  {{- end -}}

  {{- if $privates -}}
    {{/* What each worker actually polls, read the way its Deployment renders it: the
         entry's own queue, else the chart-level one, else its env override, else global.
         An empty `workers` is the single Deployment this chart has always produced. */}}
    {{- $entries := $worker.workers | default list -}}
    {{- $pollers := dict -}}
    {{- if $entries -}}
      {{- range $i, $w := $entries -}}
        {{- $wn := $w.name | default (printf "workers[%d]" $i) -}}
        {{- $q := $w.requestQueue | default $worker.requestQueue | default $workerEnv.SQS_REQUEST_QUEUE_NAME | default $gq.requestQueue -}}
        {{- if not $q -}}
          {{- fail (printf "\n\ndevops-llm-worker.workers[%d] (%q) has no request queue, and neither global.sqs.requestQueue nor devops-llm-worker.requestQueue supplies one.\n\nA worker with no queue polls nothing.\n" $i $wn) -}}
        {{- end -}}
        {{- if hasKey $pollers $q -}}
          {{- fail (printf "\n\ndevops-llm-worker workers %q and %q both poll %q.\n\nOne queue per MODEL. Two workers on one queue race for every message, so the agent's choice of backend decides nothing — whichever pod receives first is the model that answers.\n\nReplicas of ONE model are the supported way to scale: set replicaCount on that entry instead. They share the queue on purpose, and SQS spreads the backlog across them because every request carries its own MessageGroupId.\n" (index $pollers $q) $wn $q) -}}
        {{- end -}}
        {{- $_ := set $pollers $q $wn -}}
      {{- end -}}
    {{- else -}}
      {{- $q := $worker.requestQueue | default $workerEnv.SQS_REQUEST_QUEUE_NAME | default $gq.requestQueue -}}
      {{- if $q -}}
        {{- $_ := set $pollers $q "devops-llm-worker" -}}
      {{- end -}}
    {{- end -}}

    {{/* Every private-llm backend must have a worker on the queue it writes to. Iterated
         over the WHOLE list so $i is the index the values file actually shows. */}}
    {{- range $i, $b := (($agent.llm | default dict).backends | default list) -}}
      {{- if eq ($b.kind | default "") "private-llm" -}}
      {{- if and (gt (len $privates) 1) (not $b.requestQueue) -}}
        {{- fail (printf "\n\ndevops-ai-agent.llm.backends[%d] (%q) is private-llm but names no requestQueue, and it is not the only one.\n\nWith %d private-llm backends every one of them states its own queue. Inheriting global.sqs.requestQueue for one while another overrides is the asymmetry that hides a forgotten queue — the agent rejects it at boot for the same reason.\n\n  backends:\n    - name: %s\n      kind: private-llm\n      requestQueue: llm-request-%s.fifo\n" $i $b.name (len $privates) $b.name $b.name) -}}
      {{- end -}}
      {{- if and $b.requestQueue (not (hasSuffix ".fifo" $b.requestQueue)) -}}
        {{- fail (printf "\n\ndevops-ai-agent.llm.backends[%d] (%q) has requestQueue %q, which is not a FIFO queue name.\n\nEvery request carries a MessageGroupId and a standard queue rejects it. Worse, the agent CREATES a missing queue on first use, so a non-.fifo name produces a standard queue and then fails on every send instead of at boot.\n" $i $b.name $b.requestQueue) -}}
      {{- end -}}
      {{- $q := $b.requestQueue | default $globalReq -}}
      {{- if not (hasKey $pollers $q) -}}
        {{- fail (printf "\n\ndevops-ai-agent.llm.backends[%d] (%q) writes to SQS queue %q, which no llm-worker polls.\n\nWorkers currently polling: %s\n\nEvery call routed to %q would sit on that queue until the agent's llm.sqs.timeoutSeconds. Add the worker:\n\n  devops-llm-worker:\n    workers:\n      - name: %s\n        requestQueue: %s\n        llm:\n          baseUrl: http://<endpoint>/v1\n          model: <model>\n" $i $b.name $q (ternary (join ", " (keys $pollers)) "(none)" (gt (len $pollers) 0)) $b.name $b.name $q) -}}
      {{- end -}}
      {{- end -}}
    {{- end -}}

    {{/* And the mirror: a worker polling a queue nobody writes to is a pod that will never
         receive a message. Only checkable from here, same as the direction above. */}}
    {{- $claimed := dict -}}
    {{- range $b := $privates -}}
      {{- $_ := set $claimed ($b.requestQueue | default $globalReq) true -}}
    {{- end -}}
    {{- range $q, $wn := $pollers -}}
      {{- if not (hasKey $claimed $q) -}}
        {{- fail (printf "\n\ndevops-llm-worker %q polls SQS queue %q, which no agent backend writes to.\n\nQueues the agent's private-llm backends write to: %s\n\nThat worker will never receive a message. Either point a backend's requestQueue at %q, or drop the worker.\n" $wn $q (join ", " (keys $claimed)) $q) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* ---- agent: the LLM backend list ----

The agent's own registry validates these at boot; the value of repeating the rules here
is WHERE they fail. A bad backend list is a CrashLoop after the image pulls — this makes
it a rejected render, in CI, next to the line that caused it.

Kept deliberately narrow: only what is knowable from values. Whether the model name is
real, or the key valid, is not.
*/}}
{{- if $agentOn -}}
  {{- $llm := $agent.llm | default dict -}}
  {{- $backends := $llm.backends | default list -}}
  {{- $kinds := list "claude" "openai-compatible" "private-llm" -}}
  {{- $names := list -}}
  {{- $hasPrivate := false -}}
  {{- range $i, $b := $backends -}}
    {{- $n := add1 $i -}}
    {{- if not $b.name -}}
      {{- fail (printf "\n\ndevops-ai-agent.llm.backends[%d] has no name.\n\nThe name is how llm.routes.heavy / .light refer to a backend, so an unnamed one can never be routed to. It is rendered as LLM_BACKEND_%d_NAME.\n" $i $n) -}}
    {{- end -}}
    {{- if has $b.name $names -}}
      {{- fail (printf "\n\nDuplicate LLM backend name %q in devops-ai-agent.llm.backends.\n\nRoutes name a single backend, so two entries answering to the same name means one of them can never be selected.\n" $b.name) -}}
    {{- end -}}
    {{- $names = append $names $b.name -}}
    {{- if not (has ($b.kind | default "") $kinds) -}}
      {{- fail (printf "\n\ndevops-ai-agent.llm.backends[%d] (%q) has kind %q.\n\nValid kinds: %s.\n\n  claude             calls the Anthropic API directly\n  openai-compatible  calls an OpenAI-shaped /v1 endpoint directly (needs baseUrl)\n  private-llm        goes over SQS to llm-worker, which holds the credentials\n" $i $b.name ($b.kind | default "") (join ", " $kinds)) -}}
    {{- end -}}
    {{- if eq $b.kind "private-llm" -}}
      {{- $hasPrivate = true -}}
    {{- end -}}
    {{- if and (eq $b.kind "openai-compatible") (not $b.baseUrl) -}}
      {{- fail (printf "\n\ndevops-ai-agent.llm.backends[%d] (%q) is openai-compatible but has no baseUrl.\n\nThat kind names a wire format, not a vendor — the chart has no default endpoint to fall back to.\n" $i $b.name) -}}
    {{- end -}}
    {{/* A key belongs to the side that makes the call. On a private-llm backend it is
         the worker that calls out, so a key here is a credential mounted into a Pod that
         has no use for it. */}}
    {{- if and (eq $b.kind "private-llm") (or $b.existingSecret $b.apiKeyKey) -}}
      {{- fail (printf "\n\ndevops-ai-agent.llm.backends[%d] (%q) is private-llm but carries an API key.\n\nprivate-llm backends never call an API from the agent: the request goes over SQS and llm-worker makes the call with its own LLM_API_KEY. A key set here is mounted into the agent and never read.\n\nSet it on devops-llm-worker instead.\n" $i $b.name) -}}
    {{- end -}}
  {{- end -}}

  {{/* Routing. Only meaningful under the router; the other providers name one backend. */}}
  {{- $provider := $agentEnvAll.LLM_PROVIDER | default $llm.provider | default "claude" -}}
  {{- $routes := $llm.routes | default dict -}}
  {{- if eq $provider "router" -}}
    {{- if not $backends -}}
      {{- fail "\n\ndevops-ai-agent.llm.provider is \"router\" but llm.backends is empty.\n\nThe router picks a backend per call; with none declared there is nothing to pick. Declare at least one backend, or set a single-backend provider (claude, openai-compatible, private-llm).\n" -}}
    {{- end -}}
    {{- if not ($routes.heavy | default list) -}}
      {{- fail "\n\ndevops-ai-agent.llm.provider is \"router\" but llm.routes.heavy is empty.\n\nheavy is the failover chain investigations run on — the router has no default for it. Name at least one backend there.\n" -}}
    {{- end -}}
  {{- end -}}
  {{- range $lane := list "heavy" "light" -}}
    {{- range $n := (index $routes $lane) | default list -}}
      {{- if not (has $n $names) -}}
        {{- fail (printf "\n\ndevops-ai-agent.llm.routes.%s names %q, which is not a declared backend.\n\nDeclared: %s\n\nRoutes refer to backends by llm.backends[].name.\n" $lane $n (ternary (join ", " $names) "(none)" (gt (len $names) 0))) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{/* A backend in both lanes makes failover circular: heavy falls back onto a light
       backend that can itself fall back into heavy. The agent rejects this at boot. */}}
  {{- range $n := ($routes.heavy | default list) -}}
    {{- if has $n ($routes.light | default list) -}}
      {{- fail (printf "\n\nBackend %q appears in both llm.routes.heavy and llm.routes.light.\n\nFailover is up-only — light never falls back onto heavy — and a backend in both lanes makes that ordering meaningless.\n" $n) -}}
    {{- end -}}
  {{- end -}}

  {{- if and $hasPrivate (not $workerOn) -}}
    {{- fail "\n\nA private-llm backend is configured on the agent, but devops-llm-worker is disabled.\n\nprivate-llm backends do not call an API directly — they put the request on SQS and wait for llm-worker to answer. With no worker running, every call routed to that backend hangs until llm.sqs.timeoutSeconds.\n\nEither set devops-llm-worker.enabled: true, or remove the private-llm entry from devops-ai-agent.llm.backends and from llm.routes.\n" -}}
  {{- end -}}

  {{/* Same shape, other contract: the worker is the only side holding GitHub creds. */}}
  {{- if and $agentGitopsOn (not $workerOn) -}}
    {{- fail "\n\ndevops-ai-agent.gitops.enabled is true, but devops-llm-worker is disabled.\n\nThe agent holds no GitHub credentials by design. It puts PR requests on the GitOps SQS queue and llm-worker — the private-network bridge that does hold them — opens the pull request. With no worker running, every remediation proposal the agent makes is silently dropped.\n\nEither set devops-llm-worker.enabled: true (with its gitops.* values), or set devops-ai-agent.gitops.enabled: false.\n" -}}
  {{- end -}}
{{- end -}}

{{/* ---- the GitOps bridge must be switched on at BOTH ends ----

The agent's GITOPS_REMEDIATION_ENABLED makes it emit PR requests; the worker's
gitops.enabled is what gives that worker its GitHub token and repo. On without the other
means proposals land on a queue whose consumer cannot act on them.
*/}}
{{- if and $agentOn $workerOn -}}
  {{- $workerGitops := ($worker.gitops | default dict).enabled | default false -}}
  {{- if and $agentGitopsOn (not $workerGitops) -}}
    {{- fail "\n\ndevops-ai-agent.gitops.enabled is true, but devops-llm-worker.gitops.enabled is false.\n\nThe worker will consume the agent's PR requests without a GITHUB_TOKEN or a GITOPS_REPO to act on them, so every remediation proposal fails at the worker.\n\nSet devops-llm-worker.gitops.enabled: true (with repo and its auth), or turn off gitops.enabled on the agent.\n" -}}
  {{- end -}}
{{- end -}}

{{/* ---- worker: the LLM it is pointed at ----

Every check here reads `env`/`secretEnv` first, because those win in the Deployment. A
check that reads only the object rejects a release that would have deployed correctly.
*/}}
{{- if $workerOn -}}
  {{- $wEnvAll := merge (dict) ($worker.env | default dict) ($worker.secretEnv | default dict) -}}
  {{- $llm := $worker.llm | default dict -}}

  {{- $fmt := $wEnvAll.LLM_API_FORMAT | default $llm.apiFormat | default "openai" -}}
  {{- if not (has $fmt (list "openai" "anthropic" "agent-builder")) -}}
    {{- fail (printf "\n\nLLM_API_FORMAT is %q, which llm-worker does not implement.\n\nValid values: \"openai\" (POSTs /v1/chat/completions), \"anthropic\" (POSTs /v1/messages), or \"agent-builder\" (POSTs a Langflow run endpoint).\n\nThis names the WIRE FORMAT, not the vendor — a self-hosted model behind an OpenAI-compatible gateway is \"openai\".\n" $fmt) -}}
  {{- end -}}

  {{/* baseUrl and model are read with a non-null assertion in src/config.ts. Unset means
       `undefined` interpolated into the request URL and a crash on the first message,
       long after the Pod has passed every probe. */}}
  {{- if not ($wEnvAll.LLM_BASE_URL | default $llm.baseUrl) -}}
    {{- fail "\n\ndevops-llm-worker.llm.baseUrl is not set.\n\nThe worker reads LLM_BASE_URL with no default. Unset, it starts, reports healthy, and crashes on the first request with a URL built from `undefined`.\n\n  devops-llm-worker:\n    llm:\n      baseUrl: http://vllm.llm:8000/v1\n\nUnder apiFormat \"agent-builder\" this is the FULL run endpoint, not a /v1 base — the flow id is part of it:\n\n      baseUrl: https://<agent-builder-host>/api/v1/run/<flow-id>\n" -}}
  {{- end -}}
  {{- if and (ne $fmt "agent-builder") (not ($wEnvAll.LLM_MODEL | default $llm.model)) -}}
    {{- fail "\n\ndevops-llm-worker.llm.model is not set.\n\nThe worker reads LLM_MODEL with no default, and passes it through verbatim as the model name in every request.\n\n  devops-llm-worker:\n    llm:\n      model: qwen2.5-coder-32b-instruct\n" -}}
  {{- end -}}

  {{/* Three parameters exist only on the OpenAI path. src/anthropic.ts sends temperature
       and top_p and nothing else, so these reach /v1/messages only if someone writes them
       into `env` by hand — where an endpoint that rejects unknown fields answers 400 on
       every request rather than ignoring them. */}}
  {{- if eq $fmt "anthropic" -}}
    {{- $s := $llm.sampling | default dict -}}
    {{- $openaiOnly := dict
          "LLM_REASONING_EFFORT" (or $wEnvAll.LLM_REASONING_EFFORT $s.reasoningEffort)
          "LLM_SEED" (or $wEnvAll.LLM_SEED $s.seed)
          "LLM_USE_MAX_COMPLETION_TOKENS" (or $wEnvAll.LLM_USE_MAX_COMPLETION_TOKENS $llm.useMaxCompletionTokens) -}}
    {{- range $k, $v := $openaiOnly -}}
      {{- if $v -}}
        {{- fail (printf "\n\n%s is set, but LLM_API_FORMAT is \"anthropic\".\n\nThat parameter belongs to /v1/chat/completions. The Anthropic path posts /v1/messages, which has no such field — an endpoint that validates its request body answers 400 to every message rather than ignoring it.\n\nEither remove it, or set llm.apiFormat: openai.\n" $k) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{/* The agent-builder path posts a Langflow run endpoint, whose envelope is four fields:
       input_type, output_type, input_value, session_id. There is nowhere to put a model
       name, a token cap or a sampling parameter — every one of those belongs to the flow's
       own Model component and is set in the platform UI, not here. Left renderable they
       would sit in the Deployment looking authoritative while changing nothing, which is
       the failure this chart exists to prevent. Same rule as the anthropic block above,
       one wire format further out.

       LLM_MAX_TOKENS is absent from this list on purpose: values.yaml defaults it to 16384,
       so rejecting a truthy value would fail the render for everyone who never set it. It is
       dropped from the environment in _env.tpl instead — the only one of these that is
       silently ignored rather than refused, and only because a chart default is not a claim
       the operator made. */}}
  {{- if eq $fmt "agent-builder" -}}
    {{- $s := $llm.sampling | default dict -}}
    {{- $inFlow := dict
          "LLM_MODEL" (or $wEnvAll.LLM_MODEL $llm.model)
          "LLM_TEMPERATURE" (or $wEnvAll.LLM_TEMPERATURE $s.temperature)
          "LLM_TOP_P" (or $wEnvAll.LLM_TOP_P $s.topP)
          "LLM_REASONING_EFFORT" (or $wEnvAll.LLM_REASONING_EFFORT $s.reasoningEffort)
          "LLM_SEED" (or $wEnvAll.LLM_SEED $s.seed)
          "LLM_USE_MAX_COMPLETION_TOKENS" (or $wEnvAll.LLM_USE_MAX_COMPLETION_TOKENS $llm.useMaxCompletionTokens) -}}
    {{- range $k, $v := $inFlow -}}
      {{- if $v -}}
        {{- fail (printf "\n\n%s is set, but LLM_API_FORMAT is \"agent-builder\".\n\nThe Langflow run envelope carries only input_type, output_type, input_value and session_id. This parameter has nowhere to go — the worker never sends it, and the flow's own Model component decides it. Setting it here changes nothing while looking like it does.\n\nRemove it and set the value in the flow, or switch to llm.apiFormat: openai once the OpenAI endpoint is approved.\n" $k) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- $effort := $wEnvAll.LLM_REASONING_EFFORT | default ($llm.sampling | default dict).reasoningEffort -}}
  {{- if and $effort (not (has ($effort | toString) (list "low" "medium" "high"))) -}}
    {{- fail (printf "\n\nLLM_REASONING_EFFORT is %q.\n\nThe only values the OpenAI API accepts are \"low\", \"medium\" and \"high\".\n" $effort) -}}
  {{- end -}}
{{- end -}}

{{/* ---- worker: the GitOps bridge ----

`enabled` is not a value the worker reads. src/config.ts DERIVES it:

    enabled: !!((GITHUB_TOKEN || GITHUB_APP_ID) && GITOPS_REPO)

so a half-configured bridge does not fail — it reports itself disabled at boot and drops
every proposal the agent queues, with the agent still waiting for an answer. That is the
failure this section exists to turn into a render error.
*/}}
{{- if and $workerOn (($worker.gitops | default dict).enabled) -}}
  {{- $gitops := $worker.gitops -}}
  {{- $wEnvAll := merge (dict) ($worker.env | default dict) ($worker.secretEnv | default dict) -}}
  {{- $auth := $gitops.auth | default dict -}}
  {{- $app := $auth.githubApp | default dict -}}
  {{- $tokenName := ($auth.tokenSecret | default dict).name -}}

  {{- if not ($wEnvAll.GITOPS_REPO | default $gitops.repo) -}}
    {{- fail "\n\ndevops-llm-worker.gitops.enabled is true but gitops.repo is empty.\n\nThe worker derives its own gitops flag from having BOTH a credential and a repo, so with no repo it logs \"gitops disabled\" at boot and silently drops every PR request the agent puts on the queue — the agent waits for an answer that never comes.\n\nThis is also the ONLY repository the handler may touch, so it is a bound, not just an address.\n\n  devops-llm-worker:\n    gitops:\n      repo: my-org/gitops-devops-ai-manifest\n" -}}
  {{- end -}}

  {{- if not (or $tokenName $app.appId (hasKey $wEnvAll "GITHUB_TOKEN") (hasKey $wEnvAll "GITHUB_APP_ID")) -}}
    {{- fail "\n\ndevops-llm-worker.gitops.enabled is true but no GitHub credentials are configured.\n\nSet exactly one of:\n\n  gitops.auth.tokenSecret.name        a PAT — the simple path\n  gitops.auth.githubApp.appId         short-lived installation tokens\n\nWith neither, the worker reports gitops as disabled and every proposal is dropped unanswered.\n" -}}
  {{- end -}}

  {{/* Both configured is not an error the app raises — it just picks the PAT — but it
       means a GitHub App was set up and is not being used, which is the opposite of what
       whoever configured it intended. */}}
  {{- if and $tokenName $app.appId -}}
    {{- fail (printf "\n\ndevops-llm-worker.gitops has BOTH a PAT and a GitHub App configured.\n\n  auth.tokenSecret.name  = %q\n  auth.githubApp.appId   = %q\n\nThe worker prefers the token, so the App — and its short-lived installation credentials — would never be used. Set auth.tokenSecret.name: \"\" to use the App.\n" $tokenName ($app.appId | toString)) -}}
  {{- end -}}

  {{- if $app.appId -}}
    {{- if not $app.installationId -}}
      {{- fail "\n\ndevops-llm-worker.gitops.auth.githubApp.appId is set but installationId is empty.\n\nThey are different IDs: appId identifies the App itself, installationId identifies its grant on ONE org or account. The token exchange needs both — with only the appId the worker can sign a JWT and has nowhere to redeem it.\n\nFind it in the installation's settings URL: .../installations/<installationId>\n" -}}
    {{- end -}}
    {{- if not ($app.privateKeySecret | default dict).name -}}
      {{- fail "\n\ndevops-llm-worker.gitops.auth.githubApp.privateKeySecret.name is empty.\n\nThe App authenticates by signing a JWT with its private key; without the key nothing can be signed.\n\n  privateKeySecret:\n    name: github-app-key\n    key: private-key.pem\n" -}}
    {{- end -}}
  {{- end -}}

  {{/* GitHub Enterprise's API is not at the host root. The web UI hostname works in a
       browser and 404s here, which reads like a missing repo rather than a wrong URL. */}}
  {{- $api := $wEnvAll.GITHUB_API_URL | default $gitops.apiUrl | default "https://api.github.com" -}}
  {{- if and (ne $api "https://api.github.com") (not (hasSuffix "/api/v3" $api)) -}}
    {{- fail (printf "\n\ndevops-llm-worker.gitops.apiUrl is %q.\n\nGitHub Enterprise serves its REST API at https://<host>/api/v3 — the hostname alone is the web UI, which answers 404 to API paths and looks like a missing repository rather than a wrong URL.\n\nUse https://api.github.com for public GitHub, or add /api/v3.\n" $api) -}}
  {{- end -}}
{{- end -}}

{{/* ---- the AWS region moved out of global.sqs ----

It was in two places that could disagree; now it is one. Silently ignoring the old key
would leave a release pointed at the default region while values.yaml plainly says
otherwise.
*/}}
{{- if hasKey ($g.sqs | default dict) "region" -}}
  {{- fail (printf "\n\nglobal.sqs.region has moved to global.aws.region.\n\nThe queues and the credentials that reach them are in the same region, so it is stated once. Setting it here has no effect.\n\n  global:\n    aws:\n      region: %q\n" (index $g.sqs "region")) -}}
{{- end -}}

{{/* ---- MCP moved out of global ----

It is a contract between exactly two services, not a property of the release, so each
side states its own. Ignoring the old key would leave a values file that plainly names a
token and a Service while the render quietly uses neither — and for the token, that is a
release whose MCP server ends up unauthenticated.
*/}}
{{- if hasKey $g "mcp" -}}
  {{- fail "\n\nglobal.mcp has moved into each service.\n\n  devops-ai-agent:\n    mcp:\n      transport: http\n      serviceName: devops-mcp-server   # plus namespace / port, or an explicit url\n      authTokenSecret: { name: devops-agent-secret, key: MCP_AUTH_TOKEN }\n\n  devops-mcp-server:\n    mcp:\n      transport: http\n      authTokenSecret: { name: devops-agent-secret, key: MCP_AUTH_TOKEN }\n\nMCP is an agreement between those two services, not a property of the release, so each states its own half — and this file compares them, which is why writing the token twice is safe. Point both at the same Secret key to keep one real value.\n" -}}
{{- end -}}

{{/* ---- AWS: the auth mode is a contract with entrypoint.sh, not a free-text label ----

The agent and worker images dispatch on AWS_AUTH_MODE in entrypoint.sh. An unknown value
falls into that script's else branch, which skips credential setup and logs a line nobody
reads — the Pod then starts and fails on its first SQS call instead of at render time.
*/}}
{{- $aws := $g.aws | default dict -}}
{{- $ra := $aws.rolesAnywhere | default dict -}}
{{- $mode := $aws.authMode | default "iam-anywhere" -}}
{{- $modes := list "iam-anywhere" "irsa" "env" "instance-profile" -}}
{{- if not (has $mode $modes) -}}
  {{- fail (printf "\n\nglobal.aws.authMode is %q, which entrypoint.sh does not implement.\n\nValid values:\n  iam-anywhere      an X.509 workload certificate exchanged for temporary credentials (default)\n  irsa              EKS IAM Roles for Service Accounts\n  env               a static access key from a Secret\n  instance-profile  EC2/ECS instance metadata\n\nAn unrecognised value does not fail the container: entrypoint.sh skips credential setup and the workload starts with no credentials at all.\n" $mode) -}}
{{- end -}}

{{- if eq $mode "iam-anywhere" -}}
  {{- if not ($ra.configSecret | default dict).name -}}
    {{- fail "\n\nglobal.aws.authMode is \"iam-anywhere\" but global.aws.rolesAnywhere.configSecret.name is not set.\n\nThe trust anchor, profile, and role ARNs are read from that Secret. entrypoint.sh REQUIRES all three — it exits before Node starts if any is missing, so this is a CrashLoop, not a degraded start.\n" -}}
  {{- end -}}
  {{- if and ($aws.certificate | default dict).create (not (($aws.certificate.issuerRef) | default dict).name) -}}
    {{- fail "\n\nglobal.aws.certificate.create is true but no issuerRef.name is set.\n\ncert-manager needs an Issuer or ClusterIssuer to sign the workload certificate; this chart does not create one. Set global.aws.certificate.issuerRef.name, or set create: false and mount a Secret issued elsewhere.\n" -}}
  {{- end -}}
{{- end -}}

{{- if eq $mode "env" -}}
  {{- if not ($aws.credentialsSecret | default dict).name -}}
    {{- fail "\n\nglobal.aws.authMode is \"env\" but global.aws.credentialsSecret.name is not set.\n\nThat mode means the credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, and this chart reads them from a Secret. Without it the workloads start with no credentials and every SQS call fails.\n\nFor a cluster, prefer \"iam-anywhere\" or \"irsa\" — neither stores a long-lived key.\n" -}}
  {{- end -}}
{{- end -}}

{{/* Under irsa, each AWS-using service needs a role — its own, or the shared default. */}}
{{- $globalRole := ($aws.irsa | default dict).roleArn -}}
{{- $awsServices := dict "devops-ai-agent" $agentOn "devops-llm-worker" $workerOn -}}
{{- if eq $mode "irsa" -}}
  {{- range $svc, $on := $awsServices -}}
    {{- if $on -}}
      {{- $svcVals := index $.Values $svc | default dict -}}
      {{- if not (or (($svcVals.serviceAccount | default dict).roleArn) $globalRole) -}}
        {{- fail (printf "\n\nglobal.aws.authMode is \"irsa\" but %s has no role ARN.\n\nSet one of:\n  %s.serviceAccount.roleArn   # this service's own role\n  global.aws.irsa.roleArn     # shared by every service here\n\nThe role ARN is what ties the ServiceAccount to an IAM role. Without the eks.amazonaws.com/role-arn annotation the EKS webhook injects nothing and the SDK falls through to the node's instance profile — the workload gets the NODE's permissions, which is a quiet privilege escalation rather than a failure.\n" $svc $svc) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* Values that belong to a mode other than the one selected are silently ignored, which
is how a values file comes to claim one thing and deploy another. */}}
{{- if and (ne $mode "env") ($aws.credentialsSecret | default dict).name -}}
  {{- fail (printf "\n\nglobal.aws.credentialsSecret.name is set, but authMode is %q.\n\nThe access key is only read when authMode is \"env\". As written, a long-lived credential sits in the cluster and nothing uses it.\n\nEither set authMode: \"env\", or remove credentialsSecret.\n" $mode) -}}
{{- end -}}
{{- if ne $mode "irsa" -}}
  {{- if $globalRole -}}
    {{- fail (printf "\n\nglobal.aws.irsa.roleArn is set, but authMode is %q.\n\nThe annotation is only rendered when authMode is \"irsa\", so this role is never assumed.\n\nEither set authMode: \"irsa\", or remove irsa.roleArn.\n" $mode) -}}
  {{- end -}}
  {{- range $svc, $on := $awsServices -}}
    {{- if (((index $.Values $svc | default dict).serviceAccount | default dict).roleArn) -}}
      {{- fail (printf "\n\n%s.serviceAccount.roleArn is set, but authMode is %q.\n\nThe eks.amazonaws.com/role-arn annotation is only rendered under \"irsa\", so this role is never assumed.\n" $svc $mode) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{/* The MCP server holds Kubernetes credentials, not AWS ones — it has no aws.enabled and
never gets the annotation, so a role ARN there is a role nobody assumes. */}}
{{- if (($mcp.serviceAccount | default dict).roleArn) -}}
  {{- fail "\n\ndevops-mcp-server.serviceAccount.roleArn is set, but the MCP server does not use AWS.\n\nIt talks to the Kubernetes API and to Prometheus/Loki/Jaeger; it has no SQS client and gets no AWS credentials from this chart, so the annotation is not rendered for it.\n\nIf a tool there really does need AWS, that is a change to the server, not to this chart.\n" -}}
{{- end -}}
{{- if and (ne $mode "iam-anywhere") ($aws.certificate | default dict).create -}}
  {{- fail (printf "\n\nglobal.aws.certificate.create is true, but authMode is %q.\n\nOnly \"iam-anywhere\" presents a certificate; in the other modes entrypoint.sh skips certificate setup entirely, so cert-manager would issue and rotate one that nothing mounts.\n" $mode) -}}
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
    {{- $dbName := $agentEnvAll.DB_NAME | default ($agent.database | default dict).name -}}
    {{- if and $dbName (ne $dbName $auth.database) -}}
      {{- fail (printf "\n\nDatabase name mismatch.\n\n  devops-ai-agent.database.name   = %q\n  postgresql.auth.database        = %q\n\nThe bundled Postgres will create %q, and the agent will look for %q.\n" $dbName $auth.database $auth.database $dbName) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* ---- the agent's backing services must be reachable ----

`redis.enabled: true` switches MEMORY_BACKEND to "redis". With no host from either side,
the client goes to localhost — where nothing is listening — so every conversation lookup
fails against a Pod that reports itself healthy. Unset is the better failure: the agent
keeps state in memory and says so.
*/}}
{{- if $agentOn -}}
  {{- $aRedis := $agent.redis | default dict -}}
  {{- if and $aRedis.enabled (not (or $aRedis.host ($g.redis | default dict).enabled (hasKey $agentEnvAll "REDIS_HOST"))) -}}
    {{- fail "\n\ndevops-ai-agent.redis.enabled is true but no Redis host is known.\n\nSet one of:\n  devops-ai-agent.redis.host   # a Redis this release did not deploy\n  global.redis.enabled: true   # deploy one here, and the host is derived\n\nLeft as is, the agent would use MEMORY_BACKEND=redis against localhost: the Pod passes its health check and every conversation lookup fails. Turning redis off instead is a supported mode — conversation state lives in the pod and is lost on restart.\n" -}}
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
