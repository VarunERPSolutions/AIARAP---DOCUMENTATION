output "inventory_writer_function_name" {
  description = "Feed this into tenants/variables.tf's inventory_writer_function_name."
  value       = module.pg_writer.function_name
}
