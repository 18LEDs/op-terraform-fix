# terraform/modules/observability_pipeline/main.tf
#
# Manages processor-only changes to an existing Datadog Observability Pipeline.
#
# IMPORTANT: Sources and destinations are declared here only to satisfy the
# required schema — they are placed under lifecycle.ignore_changes so Terraform
# NEVER modifies them. Only the `processors` block is managed by this repo.

terraform {
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.89"
    }
  }
}

resource "datadog_observability_pipeline" "this" {
  name = var.pipeline_name

  config {
    sources = var.sources_passthrough

    # ─── Processor Groups ────────────────────────────────────────────────────
    # Each processor_group targets one destination and contains an ordered list
    # of processors. All changes here are the ONLY mutations this repo applies.
    dynamic "processor_group" {
      for_each = var.processor_groups
      content {
        id          = processor_group.value.id
        description = lookup(processor_group.value, "description", null)

        # Optional group-level filter — only matching events pass through
        dynamic "filter" {
          for_each = lookup(processor_group.value, "filter", null) != null ? [processor_group.value.filter] : []
          content {
            query = filter.value.query
          }
        }

        # Ordered processors within this group
        dynamic "processors" {
          for_each = lookup(processor_group.value, "processors", [])
          content {
            # ── Filter Processor ─────────────────────────────────────────────
            dynamic "filter" {
              for_each = processors.value.type == "filter" ? [processors.value] : []
              content {
                id      = filter.value.id
                include = filter.value.include
              }
            }

            # ── Grok Parser ──────────────────────────────────────────────────
            dynamic "grok_parser" {
              for_each = processors.value.type == "grok_parser" ? [processors.value] : []
              content {
                id       = grok_parser.value.id
                field    = grok_parser.value.field
                dynamic "rules" {
                  for_each = grok_parser.value.rules
                  content {
                    name    = rules.value.name
                    pattern = rules.value.pattern
                  }
                }
              }
            }

            # ── Parse JSON ───────────────────────────────────────────────────
            dynamic "parse_json" {
              for_each = processors.value.type == "parse_json" ? [processors.value] : []
              content {
                id    = parse_json.value.id
                field = parse_json.value.field
              }
            }

            # ── Edit Fields (Remap) ──────────────────────────────────────────
            dynamic "remap" {
              for_each = processors.value.type == "remap" ? [processors.value] : []
              content {
                id     = remap.value.id
                source = remap.value.source
              }
            }

            # ── Add Fields ───────────────────────────────────────────────────
            dynamic "add_fields" {
              for_each = processors.value.type == "add_fields" ? [processors.value] : []
              content {
                id = add_fields.value.id
                dynamic "fields" {
                  for_each = add_fields.value.fields
                  content {
                    name  = fields.value.name
                    value = fields.value.value
                  }
                }
              }
            }

            # ── Remove Fields ────────────────────────────────────────────────
            dynamic "remove_fields" {
              for_each = processors.value.type == "remove_fields" ? [processors.value] : []
              content {
                id     = remove_fields.value.id
                fields = remove_fields.value.fields
              }
            }

            # ── Rename Fields ────────────────────────────────────────────────
            dynamic "rename_fields" {
              for_each = processors.value.type == "rename_fields" ? [processors.value] : []
              content {
                id = rename_fields.value.id
                dynamic "fields" {
                  for_each = rename_fields.value.fields
                  content {
                    source      = fields.value.source
                    destination = fields.value.destination
                    preserve    = lookup(fields.value, "preserve", false)
                  }
                }
              }
            }

            # ── Deduplicate ──────────────────────────────────────────────────
            dynamic "dedupe" {
              for_each = processors.value.type == "dedupe" ? [processors.value] : []
              content {
                id     = dedupe.value.id
                fields = dedupe.value.fields
              }
            }

            # ── Quota ────────────────────────────────────────────────────────
            dynamic "quota" {
              for_each = processors.value.type == "quota" ? [processors.value] : []
              content {
                id    = quota.value.id
                limit = quota.value.limit
                window {
                  duration = quota.value.window_duration
                  unit     = quota.value.window_unit
                }
                drop_events = lookup(quota.value, "drop_events", false)
              }
            }

            # ── Sample ───────────────────────────────────────────────────────
            dynamic "sample" {
              for_each = processors.value.type == "sample" ? [processors.value] : []
              content {
                id   = sample.value.id
                rate = sample.value.rate
              }
            }

            # ── Generate Metrics ─────────────────────────────────────────────
            dynamic "generate_metrics" {
              for_each = processors.value.type == "generate_metrics" ? [processors.value] : []
              content {
                id = generate_metrics.value.id
                dynamic "metrics" {
                  for_each = generate_metrics.value.metrics
                  content {
                    name        = metrics.value.name
                    type        = metrics.value.type
                    field       = lookup(metrics.value, "field", null)
                    include_tag = lookup(metrics.value, "include_tag", null)
                  }
                }
              }
            }

            # ── Sensitive Data Scanner ───────────────────────────────────────
            dynamic "sensitive_data_scanner" {
              for_each = processors.value.type == "sensitive_data_scanner" ? [processors.value] : []
              content {
                id = sensitive_data_scanner.value.id
                dynamic "rules" {
                  for_each = sensitive_data_scanner.value.rules
                  content {
                    name    = rules.value.name
                    pattern = rules.value.pattern
                    targets = rules.value.targets
                    keyword_options {
                      keywords          = lookup(rules.value, "keywords", [])
                      character_count   = lookup(rules.value, "character_count", 30)
                    }
                    on_match = rules.value.on_match
                  }
                }
              }
            }
          }
        }

        destinations = processor_group.value.destinations
      }
    }

    destinations = var.destinations_passthrough
  }

  # ─── Critical: Ignore sources and destinations ───────────────────────────
  # Worker topology is managed outside this repo. We only own processors.
  lifecycle {
    ignore_changes = [
      config[0].sources,
      config[0].destinations,
    ]
  }
}
