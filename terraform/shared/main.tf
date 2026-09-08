# One REST API per BACKEND (not per environment) — dev/qa/prd are STAGES of
# that one API, each with its own stage variable (gwPort) driving where the
# integration forwards. This is what keeps the API/authorizer count low
# instead of ballooning to one-per-environment.
#
# Java is deliberately NOT a backend here. Per ADR-0039, Java/Spring Batch
# is scoped exclusively to nightly OUTBOUND extraction (AIARAP calling out
# to each Tenant's SAP system) — it never receives inbound calls, so it has
# no Tenant-facing REST API, Cognito scope, or NLB listener. Its
# infrastructure is the outbound piece in java_outbound.tf instead.
locals {
  backends = toset(["node", "sap"])
}

# Flattened (backend, env) -> {instance_id, port} — this is what drives the
# NLB listeners/target groups and the per-backend stages, since those DO
# need one entry per physical destination.
locals {
  backend_envs = merge(
    { for env, cfg in var.node_environments : "node-${env}" => merge(cfg, { backend = "node", env = env }) },
    {
      for env, cfg in var.sap_environments :
      "sap-${env}" => { instance_id = var.sap_proxy_instance_id, port = cfg.port, backend = "sap", env = env }
    },
  )

  placeholder_envs = [for k, v in local.backend_envs : k if strcontains(v.instance_id, "PLACEHOLDER")]
}

# Warns (doesn't block) on two ways this map can be wrong: a placeholder
# instance_id left in past the point of actually applying, or prd
# accidentally reusing the dev/qa shared instance instead of getting its own.
check "no_placeholder_instances" {
  assert {
    condition     = length(local.placeholder_envs) == 0
    error_message = "Placeholder instance_id still set for: ${join(", ", local.placeholder_envs)} — replace before applying against real infrastructure."
  }
}

check "prd_not_sharing_devqa_instance" {
  assert {
    condition = (
      !contains(keys(var.node_environments), "prd") || (
        var.node_environments["prd"].instance_id != try(var.node_environments["dev"].instance_id, null)
      )
    )
    error_message = "node prd's instance_id matches dev's — prod must be its own dedicated instance, not the dev/qa shared box."
  }
}
