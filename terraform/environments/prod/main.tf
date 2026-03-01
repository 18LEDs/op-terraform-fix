# terraform/environments/prod/main.tf
#
# Production environment — processor configuration for all prod OP pipelines.
# Sources and destinations are imported into state but never modified here.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.89"
    }
  }

  backend "s3" {
    # Example using an S3-compatible backend (MinIO works great for self-hosted)
    # Override with your actual backend config or use a local backend for testing.
    bucket   = "terraform-state-datadog-op"
    key      = "prod/observability-pipelines.tfstate"
    region   = "us-east-1"
    endpoint = "https://minio.internal.example.com"

    # State locking via DynamoDB (or compatible)
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

provider "datadog" {
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
  api_url = "https://api.datadoghq.com/"  # change for EU: https://api.datadoghq.eu/
}

# ─── Pipeline: Security & Compliance Log Routing ─────────────────────────────
module "security_pipeline" {
  source        = "../../modules/observability_pipeline"
  pipeline_name = "prod-security-compliance"

  # These are placeholders that satisfy the schema. After `terraform import`,
  # the real values live in state and ignore_changes prevents drift.
  sources_passthrough = [
    { id = "datadog-agent-src", type = "datadog_agent" }
  ]
  destinations_passthrough = [
    { id = "datadog-logs-dst", type = "datadog_logs_destination" },
    { id = "splunk-dst",       type = "splunk_hec" }
  ]

  processor_groups = [
    # ── Group 1: Enrich and sanitize before sending to Datadog ───────────────
    {
      id          = "enrich-to-datadog"
      description = "Parse, enrich, and redact PII before Datadog ingest"
      filter = {
        query = "service:auth OR service:payments"
      }
      destinations = ["datadog-logs-dst"]
      processors = [
        {
          type  = "parse_json"
          id    = "parse-raw-json"
          field = "message"
        },
        {
          type    = "grok_parser"
          id      = "parse-auth-logs"
          field   = "message"
          rules = [
            {
              name    = "auth_success"
              pattern = "%{TIMESTAMP_ISO8601:timestamp} %{LOGLEVEL:level} user=%{USERNAME:user} action=%{WORD:action} ip=%{IP:client_ip}"
            },
            {
              name    = "auth_failure"
              pattern = "%{TIMESTAMP_ISO8601:timestamp} FAILED user=%{USERNAME:user} reason=%{GREEDYDATA:reason}"
            }
          ]
        },
        {
          type   = "add_fields"
          id     = "tag-environment"
          fields = [
            { name = "env",  value = "prod" },
            { name = "team", value = "security" }
          ]
        },
        {
          type = "sensitive_data_scanner"
          id   = "redact-pii"
          rules = [
            {
              name      = "credit-card"
              pattern   = "\\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14})\\b"
              targets   = ["message"]
              on_match  = "redact"
              keywords  = ["card", "cc", "visa", "mastercard"]
              character_count = 30
            },
            {
              name      = "ssn"
              pattern   = "\\b[0-9]{3}-[0-9]{2}-[0-9]{4}\\b"
              targets   = ["message", "user"]
              on_match  = "hash"
              keywords  = ["ssn", "social"]
              character_count = 30
            }
          ]
        },
        {
          type   = "remove_fields"
          id     = "drop-internal-fields"
          fields = ["_raw", "_internal_trace_id"]
        }
      ]
    },

    # ── Group 2: High-severity events to Splunk ───────────────────────────────
    {
      id          = "critical-to-splunk"
      description = "Route only CRITICAL/ERROR level events to Splunk SIEM"
      filter = {
        query = "@level:(CRITICAL ERROR) service:auth"
      }
      destinations = ["splunk-dst"]
      processors = [
        {
          type   = "remap"
          id     = "normalize-splunk-schema"
          source = <<-VRL
            .splunk_index = "security_prod"
            .splunk_sourcetype = "auth:json"
            .severity = downcase(string!(.level))
            del(.internal_debug)
          VRL
        },
        {
          type = "sample"
          id   = "no-sample-critical"
          rate = 1  # 100% — never drop critical events
        }
      ]
    }
  ]

  tags = {
    env        = "prod"
    managed-by = "terraform"
    repo       = "gitea/datadog-op-cicd"
  }
}

# ─── Pipeline: Application Performance Logs ──────────────────────────────────
module "apm_pipeline" {
  source        = "../../modules/observability_pipeline"
  pipeline_name = "prod-apm-logs"

  sources_passthrough = [
    { id = "otel-src", type = "open_telemetry" }
  ]
  destinations_passthrough = [
    { id = "datadog-logs-dst-apm", type = "datadog_logs_destination" }
  ]

  processor_groups = [
    {
      id          = "apm-processing"
      description = "Parse OTel logs and generate request rate metrics"
      destinations = ["datadog-logs-dst-apm"]
      processors = [
        {
          type  = "parse_json"
          id    = "parse-otel-body"
          field = "body"
        },
        {
          type = "generate_metrics"
          id   = "request-metrics"
          metrics = [
            {
              name        = "app.request.count"
              type        = "count"
              include_tag = "http.status_code"
            },
            {
              name  = "app.request.duration"
              type  = "distribution"
              field = "duration_ms"
            }
          ]
        },
        {
          type = "quota"
          id   = "apm-volume-cap"
          limit         = 5000000   # 5M events
          window_duration = 1
          window_unit   = "minute"
          drop_events   = false     # throttle, don't drop
        },
        {
          type = "dedupe"
          id   = "dedup-trace-events"
          fields = ["trace_id", "span_id", "timestamp"]
        }
      ]
    }
  ]

  tags = {
    env        = "prod"
    managed-by = "terraform"
  }
}
