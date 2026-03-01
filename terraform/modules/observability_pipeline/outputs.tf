# terraform/modules/observability_pipeline/outputs.tf

output "pipeline_id" {
  description = "The Datadog-assigned ID of the Observability Pipeline."
  value       = datadog_observability_pipeline.this.id
}

output "pipeline_name" {
  description = "The display name of the pipeline."
  value       = datadog_observability_pipeline.this.name
}
