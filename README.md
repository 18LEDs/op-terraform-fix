# Datadog Observability Pipelines — CI/CD with Terraform & Gitea

This repository manages **processor-only configuration changes** to existing Datadog Observability Pipeline workers via Terraform, with a full GitOps workflow backed by a self-hosted Gitea instance.

---

## Architecture Overview

```
Developer Workstation
      │
      ▼
  Feature Branch ──► Gitea MR ──► CI: tf validate + fmt + plan (posted as MR comment)
                                        │
                              Required Reviewers Approve
                                        │
                                        ▼
                               Merge to main branch
                                        │
                                        ▼
                              CD: tf apply (processors only)
                                        │
                                        ▼
                        Datadog Observability Pipeline API
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Processor-only changes | Worker topology (sources/destinations) managed separately; this repo gates only `processors` blocks |
| `lifecycle { ignore_changes }` on sources/destinations | Prevents Terraform from touching infrastructure managed outside this repo |
| Per-environment state | Separate state files per environment prevent blast radius |
| Plan-on-PR, Apply-on-merge | Classic GitOps gate — reviewers see the diff before any change hits Datadog |
| Gitea branch protection | Enforces required reviews + passing CI before merge to `main` |

---

## Repository Structure

```
.
├── .gitea/
│   └── workflows/
│       ├── plan.yaml          # Runs on every MR/PR
│       └── apply.yaml         # Runs on merge to main
├── terraform/
│   ├── modules/
│   │   └── observability_pipeline/
│   │       ├── main.tf        # datadog_observability_pipeline resource
│   │       ├── variables.tf
│   │       └── outputs.tf
│   └── environments/
│       ├── dev/
│       ├── staging/
│       └── prod/
├── scripts/
│   ├── import_existing.sh     # Bootstrap: import live pipelines into state
│   └── validate_processors.sh # Pre-commit processor schema validation
└── docs/
    └── runbook.md
```

---

## Quick Start

### 1. Bootstrap — Import Existing Pipelines

Before making any changes, import your live pipeline configurations into Terraform state:

```bash
cd terraform/environments/prod
export DD_API_KEY="<your-api-key>"
export DD_APP_KEY="<your-app-key>"

# Get your pipeline IDs from the Datadog UI or API
bash ../../../scripts/import_existing.sh <pipeline_id_1> <pipeline_id_2>
```

### 2. Make Processor Changes

Edit the relevant environment's `pipelines.tf`. All processor configuration lives in the module call under the `processors` variable.

### 3. Open a Merge Request

Push your branch and open an MR in Gitea. The CI pipeline will:
- Run `terraform fmt -check`
- Run `terraform validate`
- Run `terraform plan` and post the output as an MR comment

### 4. Review & Merge

After required approvals and passing CI, merge to `main`. The CD pipeline runs `terraform apply` automatically.

---

## Gitea Setup (Self-Hosted)

See [docs/runbook.md](docs/runbook.md) for the complete Gitea configuration guide including:
- Enabling Gitea Actions
- Deploying the act_runner
- Configuring branch protection rules
- Setting repository secrets
