#!/usr/bin/env bash
# scripts/validate_processors.sh
#
# Pre-commit / pre-push validation script.
# Checks that processor configs in all environments are syntactically valid
# before wasting a CI run. Runs terraform validate + a lightweight custom check.
#
# Install as a pre-commit hook:
#   cp scripts/validate_processors.sh .git/hooks/pre-push
#   chmod +x .git/hooks/pre-push

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENVS=("dev" "staging" "prod")
FAILED=0

echo "=== Datadog OP Processor Validation ==="
echo ""

for ENV in "${ENVS[@]}"; do
  ENV_DIR="$REPO_ROOT/terraform/environments/$ENV"
  [[ ! -d "$ENV_DIR" ]] && continue

  echo "── Validating: $ENV ──────────────────────────"

  # Check that terraform fmt is clean
  if ! terraform fmt -check -diff "$ENV_DIR" 2>&1; then
    echo "  ❌ Formatting issues in $ENV — run: terraform fmt terraform/environments/$ENV"
    FAILED=1
  else
    echo "  ✅ Formatting OK"
  fi

  # Validate HCL syntax (backend init skipped with -backend=false)
  if ! (cd "$ENV_DIR" && terraform init -backend=false -no-color > /dev/null 2>&1 && terraform validate -no-color); then
    echo "  ❌ Validation failed for $ENV"
    FAILED=1
  else
    echo "  ✅ Validation OK"
  fi

  echo ""
done

# ── Custom checks ─────────────────────────────────────────────────────────────
echo "── Custom Processor Checks ──────────────────────────────────────────"

# Ensure no sensitive values are hardcoded in .tf files
if grep -rn 'api_key\s*=\s*"[a-zA-Z0-9]' "$REPO_ROOT/terraform/" 2>/dev/null | grep -v 'var\.'; then
  echo "❌ Possible hardcoded API key found in terraform files!"
  FAILED=1
else
  echo "✅ No hardcoded credentials detected"
fi

# Ensure lifecycle ignore_changes is present in the module
if ! grep -q "ignore_changes" "$REPO_ROOT/terraform/modules/observability_pipeline/main.tf"; then
  echo "❌ lifecycle.ignore_changes missing from module main.tf — sources/destinations may be modified!"
  FAILED=1
else
  echo "✅ lifecycle.ignore_changes present"
fi

# Warn if processor_groups is empty anywhere (not a hard failure, but worth flagging)
for ENV in "${ENVS[@]}"; do
  ENV_FILE="$REPO_ROOT/terraform/environments/$ENV/main.tf"
  [[ ! -f "$ENV_FILE" ]] && continue
  if grep -q 'processor_groups\s*=\s*\[\]' "$ENV_FILE"; then
    echo "⚠️  $ENV has empty processor_groups — is this intentional?"
  fi
done

echo ""
if [[ $FAILED -eq 1 ]]; then
  echo "=== VALIDATION FAILED — fix issues before pushing ==="
  exit 1
else
  echo "=== All checks passed ✅ ==="
fi
