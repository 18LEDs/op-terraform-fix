#!/usr/bin/env python3
"""
scripts/automation_push.py

Reference client for a trusted internal service to submit processor
configuration changes via the automation bypass path.

This script is meant to be embedded in (or called by) your internal tool.
It handles:
  1. Cloning the repo to a temp dir using the automation bot token
  2. Fetching current live pipeline state from Datadog
  3. Merging the desired processor changes into the Terraform config
  4. Committing and pushing to the `automation` branch
  5. The push triggers .gitea/workflows/automation-sync.yaml automatically

Required environment variables:
  AUTOMATION_BOT_TOKEN   - GitHub/Gitea token for the automation service account
  DD_API_KEY             - Datadog API key (for live sync)
  DD_APP_KEY             - Datadog App key (for live sync)
  REPO_URL               - Full HTTPS URL of the repo (e.g. https://github.com/18LEDs/op-terraform-fix)

Usage:
  python3 scripts/automation_push.py \\
    --env prod \\
    --pipeline-name "prod-security-compliance" \\
    --patch-file /path/to/processor_patch.json \\
    --commit-message "Auto: add dedup processor to security pipeline"
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import shutil
import urllib.request
from pathlib import Path
from datetime import datetime, timezone


# ── Config ────────────────────────────────────────────────────────────────────
AUTOMATION_TOKEN = os.environ.get("AUTOMATION_BOT_TOKEN", "")
DD_API_KEY       = os.environ.get("DD_API_KEY", "")
DD_APP_KEY       = os.environ.get("DD_APP_KEY", "")
DD_API_URL       = os.environ.get("DD_API_URL", "https://api.datadoghq.com")
REPO_URL         = os.environ.get("REPO_URL", "")
AUTOMATION_BRANCH = "automation"
BOT_NAME         = "automation-bot"
BOT_EMAIL        = "automation-bot@internal.example.com"


def run(cmd: list[str], cwd: str = None, check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command, streaming output."""
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd, capture_output=False, text=True, check=check)
    return result


def dd_get(path: str) -> dict:
    url = f"{DD_API_URL}{path}"
    req = urllib.request.Request(url, headers={
        "DD-API-KEY": DD_API_KEY,
        "DD-APPLICATION-KEY": DD_APP_KEY,
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def fetch_live_processor_groups(pipeline_id: str) -> list:
    """Fetch the live processor groups from Datadog for the given pipeline."""
    data = dd_get(f"/api/v2/remote_configuration/products/obs_pipelines/pipelines/{pipeline_id}")
    attrs  = data.get("data", {}).get("attributes", {})
    config = attrs.get("config", {})
    return config.get("processor_groups", [])


def apply_patch(live_groups: list, patch: dict) -> list:
    """
    Apply a patch to the live processor groups.

    Patch format (processor_patch.json):
    {
      "operation": "upsert_processor",  // upsert_processor | remove_processor | reorder_processors | replace_group
      "group_id": "enrich-to-datadog",
      "processor": {                     // for upsert_processor
        "id": "new-dedup",
        "type": "dedupe",
        "fields": ["trace_id", "timestamp"]
      },
      "processor_id": "old-proc-id",    // for remove_processor
      "order": ["proc-a", "proc-b"],    // for reorder_processors
      "after_processor_id": "parse-json" // optional: insert after this processor (upsert)
    }
    """
    operation = patch.get("operation")
    group_id  = patch.get("group_id")

    groups_by_id = {g["id"]: g for g in live_groups}

    if group_id and group_id not in groups_by_id:
        raise ValueError(f"Group '{group_id}' not found in live pipeline. Available: {list(groups_by_id.keys())}")

    if operation == "upsert_processor":
        proc      = patch["processor"]
        group     = groups_by_id[group_id]
        procs     = group.get("processors", [])
        after_id  = patch.get("after_processor_id")

        # Remove existing processor with same ID if present (update case)
        procs = [p for p in procs if p.get("id") != proc["id"]]

        if after_id:
            idx = next((i for i, p in enumerate(procs) if p.get("id") == after_id), len(procs) - 1)
            procs.insert(idx + 1, proc)
        else:
            procs.append(proc)

        group["processors"] = procs

    elif operation == "remove_processor":
        proc_id = patch["processor_id"]
        group   = groups_by_id[group_id]
        before  = len(group.get("processors", []))
        group["processors"] = [p for p in group.get("processors", []) if p.get("id") != proc_id]
        after = len(group["processors"])
        if before == after:
            raise ValueError(f"Processor '{proc_id}' not found in group '{group_id}'")

    elif operation == "reorder_processors":
        order = patch["order"]
        group = groups_by_id[group_id]
        procs_by_id = {p["id"]: p for p in group.get("processors", [])}
        group["processors"] = [procs_by_id[pid] for pid in order if pid in procs_by_id]

    elif operation == "replace_group":
        new_group = patch["group"]
        idx = next((i for i, g in enumerate(live_groups) if g["id"] == group_id), None)
        if idx is not None:
            live_groups[idx] = new_group

    else:
        raise ValueError(f"Unknown operation: {operation}")

    return live_groups


def update_tfvars(env_dir: Path, pipeline_name: str, patched_groups: list):
    """Write updated processor groups to live_processors.auto.tfvars.json."""
    tfvars_path = env_dir / "live_processors.auto.tfvars.json"
    tfvars = {}
    if tfvars_path.exists():
        with open(tfvars_path) as f:
            try:
                tfvars = json.load(f)
            except json.JSONDecodeError:
                pass

    safe_name = pipeline_name.lower().replace(" ", "_").replace("-", "_")
    tfvars[f"{safe_name}_processor_groups"] = patched_groups

    with open(tfvars_path, "w") as f:
        json.dump(tfvars, f, indent=2)

    print(f"  Updated: {tfvars_path}")


def main():
    parser = argparse.ArgumentParser(description="Automation bypass: push processor changes to automation branch")
    parser.add_argument("--env",            required=True, help="Target environment (dev/staging/prod)")
    parser.add_argument("--pipeline-id",    required=True, help="Datadog pipeline ID")
    parser.add_argument("--pipeline-name",  required=True, help="Pipeline name (must match TF config)")
    parser.add_argument("--patch-file",     required=True, help="Path to processor_patch.json")
    parser.add_argument("--commit-message", required=True, help="Git commit message")
    parser.add_argument("--dry-run",        action="store_true", help="Show what would change without pushing")
    args = parser.parse_args()

    for var, name in [(AUTOMATION_TOKEN, "AUTOMATION_BOT_TOKEN"), (DD_API_KEY, "DD_API_KEY"),
                      (DD_APP_KEY, "DD_APP_KEY"), (REPO_URL, "REPO_URL")]:
        if not var:
            print(f"ERROR: {name} environment variable is required")
            sys.exit(1)

    with open(args.patch_file) as f:
        patch = json.load(f)

    print(f"=== Automation Push: {args.env} / {args.pipeline_name} ===")
    print(f"Operation: {patch.get('operation')}")
    print()

    # ── Clone repo to temp dir ────────────────────────────────────────────────
    tmpdir = tempfile.mkdtemp(prefix="op-automation-")
    try:
        auth_url = REPO_URL.replace("https://", f"https://{AUTOMATION_TOKEN}@")
        print("Cloning repo...")
        run(["git", "clone", "--branch", AUTOMATION_BRANCH, auth_url, tmpdir])
        run(["git", "config", "user.name",  BOT_NAME],  cwd=tmpdir)
        run(["git", "config", "user.email", BOT_EMAIL], cwd=tmpdir)

        env_dir = Path(tmpdir) / "terraform" / "environments" / args.env

        # ── Fetch live state ──────────────────────────────────────────────────
        print(f"\nFetching live state for pipeline: {args.pipeline_id}")
        live_groups = fetch_live_processor_groups(args.pipeline_id)
        print(f"  Live groups: {[g['id'] for g in live_groups]}")

        # ── Apply the patch ───────────────────────────────────────────────────
        print(f"\nApplying patch: {patch.get('operation')}")
        patched_groups = apply_patch(live_groups, patch)

        if args.dry_run:
            print("\n=== DRY RUN — patched processor groups ===")
            print(json.dumps(patched_groups, indent=2))
            print("=== No changes pushed ===")
            return

        # ── Write tfvars ──────────────────────────────────────────────────────
        print("\nWriting updated tfvars...")
        update_tfvars(env_dir, args.pipeline_name, patched_groups)

        # ── Commit and push ───────────────────────────────────────────────────
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        commit_msg = f"{args.commit_message}\n\nAutomated change via automation_push.py\nTimestamp: {timestamp}\nPipeline: {args.pipeline_id}"

        run(["git", "add", "-A"], cwd=tmpdir)

        # Check if there's anything to commit
        result = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=tmpdir, check=False)
        if result.returncode == 0:
            print("\n⚠️  No changes detected after patching — nothing to push.")
            return

        run(["git", "commit", "-m", commit_msg], cwd=tmpdir)
        run(["git", "push", "origin", AUTOMATION_BRANCH], cwd=tmpdir)

        print(f"\n✅ Successfully pushed to `{AUTOMATION_BRANCH}` branch.")
        print("   The automation-sync workflow will now apply the changes to Datadog.")
        print("   An audit PR will be opened from automation → main automatically.")

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
