# terraform/environments/dev/main.tf

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.89"
    }
  }

  backend "s3" {
    bucket   = "terraform-state-datadog-op"
    key      = "dev/observability-pipelines.tfstate"
    region   = "us-east-1"
    endpoint = "https://minio.internal.example.com"

    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

provider "datadog" {
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
  api_url = "https://api.datadoghq.com/"
}

module "security_pipeline" {
  source        = "../../modules/observability_pipeline"
  pipeline_name = "dev-security-compliance"

  sources_passthrough = [
    { id = "datadog-agent-src-dev", type = "datadog_agent" }
  ]
  destinations_passthrough = [
    { id = "datadog-logs-dst-dev", type = "datadog_logs_destination" }
  ]

  processor_groups = [
    {
      id          = "enrich-dev"
      description = "Dev parsing — no PII redaction, verbose logging"
      destinations = ["datadog-logs-dst-dev"]
      processors = [
        {
          type  = "parse_json"
          id    = "parse-json-dev"
          field = "message"
        },
        {
          type   = "add_fields"
          id     = "tag-dev-env"
          fields = [
            { name = "env",   value = "dev" },
            { name = "debug", value = "true" }
          ]
        }
      ]
    }
  ]

  tags = {
    env        = "dev"
    managed-by = "terraform"
  }
}
