# Cross product of connections x environments — this is the full set of
# credentials/keys/routes this customer needs, per-customer-per-backend-per-env.
# e.g. sf-node x {dev,qa,prd}, sap-node x {dev,qa,prd}, sap-java x {dev,qa,prd} = 9 entries.
locals {
  connection_envs = {
    for pair in setproduct(var.connections, var.environments) :
    "${pair[0].key}-${pair[1]}" => {
      conn_key = pair[0].key
      backend  = pair[0].backend
      env      = pair[1]
      scope    = "${pair[0].backend}.invoke.${pair[1]}"
      is_prod  = pair[1] == "prd"
    }
  }

  # Distinct backends this customer actually uses, for base-path-mapping.
  backends = distinct([for c in var.connections : c.backend])
}

check "api_ids_cover_backends" {
  assert {
    condition     = length(setsubtract(local.backends, keys(var.api_ids))) == 0
    error_message = "var.api_ids is missing an entry for: ${join(", ", setsubtract(local.backends, keys(var.api_ids)))}"
  }
}
