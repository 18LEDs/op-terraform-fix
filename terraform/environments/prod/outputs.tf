# terraform/environments/prod/outputs.tf

output "security_pipeline_id" {
  description = "Datadog ID of the security/compliance pipeline."
  value       = module.security_pipeline.pipeline_id
}

output "apm_pipeline_id" {
  description = "Datadog ID of the APM logs pipeline."
  value       = module.apm_pipeline.pipeline_id
}
