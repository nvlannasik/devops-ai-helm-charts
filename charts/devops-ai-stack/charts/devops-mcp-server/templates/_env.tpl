{{/*
Renders the MCP server's value objects into the env vars src/config/index.ts reads.

Same shape and same precedence rules as the agent's helper next door: `.Values.env` and
`.Values.secretEnv` WIN over anything derived here (`hasKey`, so setting a variable to the
empty string is an honoured "unset"), nil and empty values are not emitted at all so the
app's own defaults apply, and zero and false ARE emitted because they are choices.

One thing here has no counterpart in the agent's helper. The server reads TRANSPORT; the
agent reads MCP_TRANSPORT. Two repos, two names for one contract — so the shared helper
renders only the token, and each side renders its own transport variable under the name
its own code reads. The umbrella's _validate.tpl compares the two VALUES across that name
difference. Before this block, the server's `mcp.transport` rendered as MCP_TRANSPORT,
which the server does not read: it validated correctly and did nothing, and the Deployment
worked only because the image's own `ENV TRANSPORT=http` was underneath it.
*/}}

{{- define "devops-mcp-server.derivedEnv" -}}
{{- $own := merge (dict) (.Values.env | default dict) (.Values.secretEnv | default dict) -}}
{{- $mcp := .Values.mcp | default dict -}}
{{- $svc := .Values.service | default dict -}}
{{- $k8s := .Values.kubernetes | default dict -}}
{{- $write := .Values.writeTools | default dict -}}
{{- $limits := .Values.limits | default dict -}}

{{- $plain := dict
      "TRANSPORT" $mcp.transport
      "PORT" $svc.port
      "K8S_AUTH_MODE" $k8s.authMode
      "K8S_KUBECONFIG_PATH" $k8s.kubeconfigPath
      "K8S_LIST_LIMIT" $limits.k8sListLimit
      "UPSTREAM_TIMEOUT_SECONDS" $limits.upstreamTimeoutSeconds
-}}
{{- $secrets := dict -}}

{{/* ---- Write tools ----

Two independent gates guard remediation and this block is the INNER one: rbac.allowWrite
grants the ServiceAccount the verbs, and MCP_ENABLE_WRITE_TOOLS decides whether the tools
are registered at all. Narrowing the namespace list does not narrow what the
ServiceAccount may do — only RBAC does that.

Registration, not authorization, is why enabled must be explicit: the agent caches
listTools() at startup, so a tool that is listed and then refuses makes the model loop on
it. Off means absent, not present-and-refusing.

An empty namespace list blocks every namespace — the allowlist is opt-in per namespace,
enforced server-side. kube-system, kube-public, kube-node-lease and flux-system are
refused by the server no matter what this list says. */}}
{{- if $write.enabled -}}
  {{- $_ := merge $plain (dict
        "MCP_ENABLE_WRITE_TOOLS" "true"
        "ALLOWED_REMEDIATION_NAMESPACES" (join "," ($write.allowedNamespaces | default list))
        "MAX_SCALE_DELTA" $write.maxScaleDelta) -}}
{{- end -}}

{{/* ---- Upstreams ----

Four observability backends, each a URL plus optional basic-auth credentials. One loop
rather than four near-identical blocks: the variable names are the upstream's own name
uppercased, which is the convention the server's config already follows.

Credentials are a pair — a username with no password is a request that authenticates as
nobody — so both come from the same Secret and neither is emitted without the other.

tracing carries a `backend` as well (tempo | jaeger), because the query API differs; the
umbrella rejects any other value rather than letting getAdapter() throw on first use. */}}
{{- range $name := list "prometheus" "alertmanager" "loki" "tracing" -}}
  {{- $up := index $.Values $name | default dict -}}
  {{- $prefix := upper $name -}}
  {{- $_ := set $plain (printf "%s_URL" $prefix) $up.url -}}
  {{- if and $up.existingSecret $up.usernameKey $up.passwordKey -}}
    {{- $_ := set $secrets (printf "%s_USERNAME" $prefix) (dict "secret" $up.existingSecret "key" $up.usernameKey) -}}
    {{- $_ := set $secrets (printf "%s_PASSWORD" $prefix) (dict "secret" $up.existingSecret "key" $up.passwordKey) -}}
  {{- end -}}
{{- end -}}
{{- $_ := set $plain "TRACING_BACKEND" (.Values.tracing | default dict).backend -}}

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
