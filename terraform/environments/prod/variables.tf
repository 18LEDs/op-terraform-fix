# terraform/environments/prod/variables.tf

variable "datadog_api_key" {
  description = "Datadog API key — set via DD_API_KEY env var or Gitea secret TF_VAR_datadog_api_key."
  type        = string
  sensitive   = true
}

variable "datadog_app_key" {
  description = "Datadog APP key — set via DD_APP_KEY env var or Gitea secret TF_VAR_datadog_app_key."
  type        = string
  sensitive   = true
}
