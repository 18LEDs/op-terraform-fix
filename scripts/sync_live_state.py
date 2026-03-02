#!/usr/bin/env python3
"""
scripts/sync_live_state.py

Fetches the CURRENT live configuration of all Datadog Observability Pipelines
for a given environment via the Datadog API, then:

  1. Writes a `live_state.json` for reference/auditing
  2. Generates `live_processors.auto.tfvars.json` so Terraform always plans/applies
     against real pipeline state, not potentially stale repo values
  3. Detects and reports drift between live state and what's committed in the repo
  4. Exits non-zero if drift is detected AND --fail-on-drift is passed

Usage:
    python3 scripts/sync_live_state.py \\
        --env prod \\
        --pipeline-ids <id1> <id2> \\
        --out-dir terraform/environments/prod \\
        [--fail-on-drift]

Environment variables required:
    DD_API_KEY   - Datadog API key
    DD_APP_KEY   - Datadog Application key
    DD_API_URL   - (optional) defaults to https://api.datadoghq.com
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path
from typing import Any


DD_API_URL = os.environ.get("DD_API_URL", "https://api.datadoghq.com")
DD_API_KEY = os.environ.get("DD_API_KEY", "")
DD_APP_KEY = os.environ.get("DD_APP_KEY", "")

PIPELINES_ENDPOINT = "/api/v2/remote_configuration/products/obs_pipelines/pipelines"


def dd_get(path: str) -> dict:
    """Make an authenticated GET request to the Datadog API."""
    url = f"{DD_API_URL}{path}"
    req = urllib.request.Request(url, headers={
        "DD-API-KEY": DD_API_KEY,
        "DD-APPLICATION-KEY": DD_APP_KEY,
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"ERROR: Datadog API returned {e.code} for {url}")
        print(f"       {body}")
        sys.exit(1)


def fetch_pipeline(pipeline_id: str) -> dict:
    """Fetch a single pipeline's full configuration."""
    data = dd_get(f"{PIPELINES_ENDPOINT}/{pipeline_id}")
    return data.get("data", {}).get("attributes", {})


def extract_processor_groups(pipeline_attrs: dict) -> list:
    """
    Extract processor_groups from the live pipeline config.
    Normalizes the Datadog API response structure into our Terraform variable shape.
    """
    groups = []
    config = pipeline_attrs.get("config", {})

    for group in config.get("processor_groups", []):
        normalized = {
            "id":          group.get("id", ""),
            "description": group.get("description", ""),
            "destinations": group.get("destinations", []),
            "processors":  [],
        }

        # Preserve filter if present
        if "filter" in group and group["filter"]:
            normalized["filter"] = {"query": group["filter"].get("query", "*")}

        # Normalize each processor — preserve type and all fields as-is
        for proc in group.get("processors", []):
            normalized["processors"].append(proc)

        groups.append(normalized)

    return groups


def detect_drift(live_groups: list, repo_tfvars_path: Path) -> list[str]:
    """
    Compare live processor_groups against what's currently in the repo tfvars.
    Returns a list of human-readable drift descriptions.
    """
    drift_notes = []

    if not repo_tfvars_path.exists():
        return ["No existing tfvars file found in repo — first run, no drift baseline."]

    try:
        with open(repo_tfvars_path) as f:
            repo_state = json.load(f)
    except (json.JSONDecodeError, KeyError):
        return ["Could not parse existing tfvars for drift comparison."]

    repo_groups = repo_state.get("processor_groups", [])

    live_ids  = {g["id"] for g in live_groups}
    repo_ids  = {g["id"] for g in repo_groups}

    added   = live_ids - repo_ids
    removed = repo_ids - live_ids

    if added:
        drift_notes.append(f"Groups in Datadog but NOT in repo: {', '.join(sorted(added))}")
    if removed:
        drift_notes.append(f"Groups in repo but NOT in Datadog: {', '.join(sorted(removed))}")

    # Per-group processor count comparison
    live_map = {g["id"]: g for g in live_groups}
    repo_map = {g["id"]: g for g in repo_groups}

    for gid in live_ids & repo_ids:
        live_procs = live_map[gid].get("processors", [])
        repo_procs = repo_map[gid].get("processors", [])

        if len(live_procs) != len(repo_procs):
            drift_notes.append(
                f"Group '{gid}': live has {len(live_procs)} processors, "
                f"repo has {len(repo_procs)}"
            )
        else:
            # Deep compare processor IDs in order
            live_proc_ids = [p.get("id") for p in live_procs]
            repo_proc_ids = [p.get("id") for p in repo_procs]
            if live_proc_ids != repo_proc_ids:
                drift_notes.append(
                    f"Group '{gid}': processor order/IDs differ. "
                    f"Live: {live_proc_ids} | Repo: {repo_proc_ids}"
                )

    return drift_notes


def write_outputs(
    pipeline_id: str,
    pipeline_name: str,
    live_groups: list,
    out_dir: Path,
) -> Path:
    """
    Write live_state.json and live_processors.auto.tfvars.json for Terraform consumption.
    Returns path to the tfvars file.
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    # Full live state dump for auditing
    state_path = out_dir / f"live_state_{pipeline_id}.json"
    with open(state_path, "w") as f:
        json.dump({
            "pipeline_id":   pipeline_id,
            "pipeline_name": pipeline_name,
            "processor_groups": live_groups,
        }, f, indent=2)
    print(f"  Live state written: {state_path}")

    # Terraform-consumable tfvars
    tfvars_path = out_dir / "live_processors.auto.tfvars.json"
    tfvars: dict[str, Any] = {}

    # Load existing if present (may have multiple pipelines)
    if tfvars_path.exists():
        with open(tfvars_path) as f:
            try:
                tfvars = json.load(f)
            except json.JSONDecodeError:
                tfvars = {}

    # Key by pipeline name so multiple pipelines co-exist in the same file
    safe_name = pipeline_name.lower().replace(" ", "_").replace("-", "_")
    tfvars[f"{safe_name}_processor_groups"] = live_groups

    with open(tfvars_path, "w") as f:
        json.dump(tfvars, f, indent=2)
    print(f"  tfvars written:     {tfvars_path}")

    return tfvars_path


def main():
    parser = argparse.ArgumentParser(description="Sync live Datadog OP state to Terraform tfvars")
    parser.add_argument("--env",          required=True, help="Environment name (dev/staging/prod)")
    parser.add_argument("--pipeline-ids", required=True, nargs="+", help="One or more pipeline IDs")
    parser.add_argument("--out-dir",      required=True, help="Output directory (terraform/environments/<env>)")
    parser.add_argument("--fail-on-drift", action="store_true",
                        help="Exit non-zero if live state differs from repo tfvars")
    args = parser.parse_args()

    if not DD_API_KEY or not DD_APP_KEY:
        print("ERROR: DD_API_KEY and DD_APP_KEY must be set as environment variables.")
        sys.exit(1)

    out_dir = Path(args.out_dir)
    all_drift: list[str] = []

    print(f"=== Live State Sync — {args.env.upper()} ===")
    print(f"API endpoint: {DD_API_URL}")
    print()

    for pipeline_id in args.pipeline_ids:
        print(f"── Pipeline: {pipeline_id}")

        attrs         = fetch_pipeline(pipeline_id)
        pipeline_name = attrs.get("name", pipeline_id)
        live_groups   = extract_processor_groups(attrs)

        print(f"   Name:   {pipeline_name}")
        print(f"   Groups: {len(live_groups)}")
        for g in live_groups:
            print(f"     • {g['id']} ({len(g.get('processors', []))} processors) → {g['destinations']}")

        # Detect drift vs repo
        safe_name    = pipeline_name.lower().replace(" ", "_").replace("-", "_")
        tfvars_path  = out_dir / "live_processors.auto.tfvars.json"
        drift        = detect_drift(live_groups, tfvars_path)

        if drift:
            print(f"\n  ⚠️  DRIFT DETECTED for {pipeline_name}:")
            for note in drift:
                print(f"     - {note}")
            all_drift.extend([f"[{pipeline_name}] {d}" for d in drift])
        else:
            print("   ✅ No drift detected vs repo state")

        write_outputs(pipeline_id, pipeline_name, live_groups, out_dir)
        print()

    # Write drift summary for CI to pick up and post as a comment
    drift_report_path = out_dir / "drift_report.txt"
    with open(drift_report_path, "w") as f:
        if all_drift:
            f.write("DRIFT DETECTED\n")
            f.write("\n".join(all_drift))
        else:
            f.write("NO_DRIFT")
    print(f"Drift report: {drift_report_path}")

    if all_drift and args.fail_on_drift:
        print("\nExiting non-zero due to --fail-on-drift flag.")
        sys.exit(2)

    print("=== Sync complete ===")


if __name__ == "__main__":
    main()
