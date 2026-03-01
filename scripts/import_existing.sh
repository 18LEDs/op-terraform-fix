#!/usr/bin/env bash
# scripts/import_existing.sh
#
# Bootstrap script: imports existing live Datadog Observability Pipeline
# configurations into Terraform state so they can be managed going forward.
#
# Usage:
#   export DD_API_KEY="<key>"
#   export DD_APP_KEY="<key>"
#   bash scripts/import_existing.sh [--env prod] <pipeline_id_1> [pipeline_id_2 ...]
#
# The script will:
#   1. Call the Datadog API to fetch the pipeline JSON
#   2. Generate a scaffold Terraform resource stub you can paste into your env file
#   3. Run terraform import to seed the state

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
ENV="prod"
DD_API_URL="${DD_API_URL:-https://api.datadoghq.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Arg parsing ──────────────────────────────────────────────────────────────
PIPELINE_IDS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENV="$2"; shift 2 ;;
    --api-url) DD_API_URL="$2"; shift 2 ;;
    -*) echo "Unknown flag: $1"; exit 1 ;;
    *) PIPELINE_IDS+=("$1"); shift ;;
  esac
done

if [[ ${#PIPELINE_IDS[@]} -eq 0 ]]; then
  echo "Usage: $0 [--env ENV] <pipeline_id_1> [pipeline_id_2 ...]"
  echo ""
  echo "Get pipeline IDs from:"
  echo "  curl -H 'DD-API-KEY: \$DD_API_KEY' -H 'DD-APPLICATION-KEY: \$DD_APP_KEY' \\"
  echo "    '${DD_API_URL}/api/v2/remote_configuration/products/obs_pipelines/pipelines'"
  exit 1
fi

if [[ -z "${DD_API_KEY:-}" || -z "${DD_APP_KEY:-}" ]]; then
  echo "ERROR: DD_API_KEY and DD_APP_KEY must be set as environment variables."
  exit 1
fi

ENV_DIR="$REPO_ROOT/terraform/environments/$ENV"
if [[ ! -d "$ENV_DIR" ]]; then
  echo "ERROR: Environment directory not found: $ENV_DIR"
  exit 1
fi

echo "=== Datadog Observability Pipeline Import Tool ==="
echo "Environment: $ENV"
echo "Pipelines:   ${PIPELINE_IDS[*]}"
echo ""

# ── Fetch pipeline details from Datadog API ───────────────────────────────────
for PIPELINE_ID in "${PIPELINE_IDS[@]}"; do
  echo "──────────────────────────────────────────────"
  echo "Fetching pipeline: $PIPELINE_ID"

  PIPELINE_JSON=$(curl -sf \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    "${DD_API_URL}/api/v2/remote_configuration/products/obs_pipelines/pipelines/${PIPELINE_ID}")

  PIPELINE_NAME=$(echo "$PIPELINE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('attributes',{}).get('name','unknown'))" 2>/dev/null || echo "unknown")

  echo "Pipeline name: $PIPELINE_NAME"

  # Generate a safe Terraform resource identifier from the name
  TF_RESOURCE_NAME=$(echo "$PIPELINE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')

  echo ""
  echo "┌─ Suggested module call for terraform/environments/$ENV/main.tf ─────"
  cat <<SCAFFOLD
module "${TF_RESOURCE_NAME}" {
  source        = "../../modules/observability_pipeline"
  pipeline_name = "${PIPELINE_NAME}"

  # TODO: Populate sources_passthrough and destinations_passthrough
  # by inspecting the pipeline JSON below, then run terraform import.
  sources_passthrough      = []
  destinations_passthrough = []

  # TODO: Define your processor_groups here.
  # These are the ONLY blocks this repo will modify going forward.
  processor_groups = []

  tags = {
    env        = "${ENV}"
    managed-by = "terraform"
  }
}
SCAFFOLD
  echo "└────────────────────────────────────────────────────────────────────"
  echo ""

  # Save full pipeline JSON for reference
  OUTPUT_FILE="$SCRIPT_DIR/imported_${PIPELINE_ID}.json"
  echo "$PIPELINE_JSON" > "$OUTPUT_FILE"
  echo "Full pipeline JSON saved to: $OUTPUT_FILE"
  echo "Review it to extract source/destination IDs and processor structure."
  echo ""

  # Run terraform import
  echo "Running: terraform import module.${TF_RESOURCE_NAME}.datadog_observability_pipeline.this ${PIPELINE_ID}"
  echo ""
  echo "NOTE: Add the module stub to main.tf BEFORE running the import below."
  echo "Once added, run:"
  echo ""
  echo "  cd $ENV_DIR"
  echo "  terraform init"
  echo "  terraform import module.${TF_RESOURCE_NAME}.datadog_observability_pipeline.this ${PIPELINE_ID}"
  echo ""
done

echo "=== Import prep complete ==="
echo ""
echo "Next steps:"
echo "  1. Review the JSON files in scripts/ for each pipeline"
echo "  2. Add the module stubs to terraform/environments/${ENV}/main.tf"
echo "  3. Run 'terraform import' commands shown above"
echo "  4. Run 'terraform plan' — it should show no changes if stubs are accurate"
echo "  5. Commit the .tf files and initial state to git"
