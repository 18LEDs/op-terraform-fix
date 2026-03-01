# terraform/modules/observability_pipeline/variables.tf

variable "pipeline_name" {
  description = "Display name of the Observability Pipeline in the Datadog UI."
  type        = string
}

variable "sources_passthrough" {
  description = <<-EOT
    Passthrough representation of the pipeline sources.
    These values are read from state on import and are NEVER modified by apply
    (lifecycle.ignore_changes covers this block). Provide enough structure to
    satisfy the provider schema at plan time.
  EOT
  type = list(object({
    id   = string
    type = string
    # extend as needed for your source types
  }))
  default = []
}

variable "destinations_passthrough" {
  description = <<-EOT
    Passthrough representation of the pipeline destinations.
    Same ignore_changes treatment as sources.
  EOT
  type = list(object({
    id   = string
    type = string
    # extend as needed for your destination types
  }))
  default = []
}

variable "processor_groups" {
  description = <<-EOT
    List of processor groups, each targeting one or more destinations.
    This is the ONLY block actively managed by this repository.

    Each object:
      id           - Unique ID for the group
      description  - Optional human-readable label
      filter       - Optional object { query = "..." } to gate which events enter the group
      processors   - Ordered list of processor objects (see module README for schema per type)
      destinations - List of destination IDs this group fans out to
  EOT
  type = list(object({
    id          = string
    description = optional(string)
    filter = optional(object({
      query = string
    }))
    processors = optional(list(object({
      type = string  # filter | grok_parser | parse_json | remap | add_fields |
                     # remove_fields | rename_fields | dedupe | quota | sample |
                     # generate_metrics | sensitive_data_scanner
      id   = string
      # All remaining keys are type-specific and passed through via lookup()
    })), [])
    destinations = list(string)
  }))
}

variable "tags" {
  description = "Key-value tags applied to the pipeline resource."
  type        = map(string)
  default     = {}
}
