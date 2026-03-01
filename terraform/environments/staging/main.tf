# terraform/environments/staging/main.tf
# Mirror prod structure with staging-appropriate settings

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
    key      = "staging/observability-pipelines.tfstate"
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
  pipeline_name = "staging-security-compliance"

  sources_passthrough = [
    { id = "datadog-agent-src-staging", type = "datadog_agent" }
  ]
  destinations_passthrough = [
    { id = "datadog-logs-dst-staging", type = "datadog_logs_destination" }
  ]

  processor_groups = [
    {
      id          = "enrich-staging"
      description = "Staging — production-like processors with test PII redaction"
      destinations = ["datadog-logs-dst-staging"]
      processors = [
        {
          type  = "parse_json"
          id    = "parse-json-staging"
          field = "message"
        },
        {
          type = "sensitive_data_scanner"
          id   = "redact-pii-staging"
          rules = [
            {
              name            = "credit-card-staging"
              pattern         = "\\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14})\\b"
              targets         = ["message"]
              on_match        = "hash"   # hash in staging, redact in prod
              keywords        = ["card", "cc"]
              character_count = 30
            }
          ]
        },
        {
          type   = "add_fields"
          id     = "tag-staging-env"
          fields = [
            { name = "env", value = "staging" }
          ]
        }
      ]
    }
  ]

  tags = {
    env        = "staging"
    managed-by = "terraform"
  }
}
