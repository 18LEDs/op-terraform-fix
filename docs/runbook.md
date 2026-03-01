# Gitea Setup Runbook — Datadog OP CI/CD Pipeline

This document covers everything needed to configure your self-hosted Gitea instance
to act as the SCM and CI/CD gate for Datadog Observability Pipeline changes.

---

## 1. Prerequisites

- Gitea **≥ 1.21** (Actions support is stable from this version onward)
- A machine or container to run `act_runner` (the Gitea Actions executor)
- Docker installed on the runner host
- An S3-compatible object store for Terraform state (MinIO works well)
- Datadog API + App keys per environment (dev, staging, prod)

---

## 2. Enable Gitea Actions

In your Gitea `app.ini`:

```ini
[actions]
ENABLED = true
DEFAULT_ACTIONS_URL = github   # lets workflows pull actions from github.com marketplace
```

Restart Gitea after making this change.

---

## 3. Deploy the act_runner

### Option A — Docker Compose (recommended for single-host setups)

```yaml
# docker-compose.yml (append to your existing Gitea compose)
services:
  gitea-runner:
    image: gitea/act_runner:latest
    restart: unless-stopped
    environment:
      CONFIG_FILE: /config/config.yaml
      GITEA_INSTANCE_URL: "https://gitea.internal.example.com"
      GITEA_RUNNER_REGISTRATION_TOKEN: "${RUNNER_TOKEN}"
    volumes:
      - ./runner-config:/config
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      - gitea
```

Get the registration token from:
**Gitea Admin Panel → Site Administration → Runners → Create new Runner**

### Option B — Systemd service on a VM

```bash
# Download
curl -Lo /usr/local/bin/act_runner \
  https://gitea.com/gitea/act_runner/releases/latest/download/act_runner-linux-amd64
chmod +x /usr/local/bin/act_runner

# Register
act_runner register \
  --no-interactive \
  --instance "https://gitea.internal.example.com" \
  --token "<RUNNER_REGISTRATION_TOKEN>" \
  --name "terraform-runner-01" \
  --labels "ubuntu-latest:docker://node:20-bullseye"

# Systemd unit
cat > /etc/systemd/system/gitea-runner.service <<'EOF'
[Unit]
Description=Gitea Actions Runner
After=network.target

[Service]
ExecStart=/usr/local/bin/act_runner daemon
WorkingDirectory=/opt/gitea-runner
Restart=always
User=gitea-runner

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gitea-runner
```

### Runner Labels

The workflows use `runs-on: ubuntu-latest`. Map this label in your runner config:

```yaml
# /config/config.yaml
runner:
  labels:
    - "ubuntu-latest:docker://node:20-bullseye"
    - "self-hosted:host://"
```

---

## 4. Create the Repository

1. Log in to Gitea as an admin
2. Create a new repository: `org/datadog-op-cicd`
3. Push this repo content:

```bash
git remote add origin https://gitea.internal.example.com/org/datadog-op-cicd.git
git push -u origin main
```

---

## 5. Configure Repository Secrets

Go to: **Repository → Settings → Secrets and Variables → Actions**

Add the following secrets:

| Secret Name              | Description                                      |
|--------------------------|--------------------------------------------------|
| `DD_API_KEY_DEV`         | Datadog API key for dev org/environment          |
| `DD_APP_KEY_DEV`         | Datadog App key for dev org/environment          |
| `DD_API_KEY_STAGING`     | Datadog API key for staging                      |
| `DD_APP_KEY_STAGING`     | Datadog App key for staging                      |
| `DD_API_KEY_PROD`        | Datadog API key for production                   |
| `DD_APP_KEY_PROD`        | Datadog App key for production                   |
| `TF_STATE_ACCESS_KEY`    | S3/MinIO access key for Terraform state bucket   |
| `TF_STATE_SECRET_KEY`    | S3/MinIO secret key for Terraform state bucket   |
| `SLACK_WEBHOOK_URL`      | (Optional) Slack webhook for failure alerts      |

> **Security note**: Use a dedicated Datadog service account per environment
> with minimum required permissions:
> - `observability_pipelines_write` on the Observability Pipelines resource
> - Read-only on everything else

---

## 6. Configure Branch Protection (THE GATING MECHANISM)

This is the most critical step — it prevents anyone from pushing directly to `main`
and ensures every change flows through review.

Go to: **Repository → Settings → Branches**

### Protect the `main` branch:

| Setting | Value |
|---------|-------|
| Branch name pattern | `main` |
| Require pull request before merging | ✅ Enabled |
| Required number of approvals | **2** (prod changes warrant 2 reviewers) |
| Dismiss stale approvals on new commits | ✅ Enabled |
| Require review from code owners | ✅ Enabled (see CODEOWNERS below) |
| Require status checks to pass before merging | ✅ Enabled |
| Required status checks | `Validate & Format`, `Plan: Dev`, `Plan: Staging`, `Plan: Prod` |
| Restrict who can push to this branch | ✅ Enabled — only CI service account |
| Allow force pushes | ❌ Disabled |
| Allow deletions | ❌ Disabled |

### Add a CODEOWNERS file

```
# CODEOWNERS
# Changes to any terraform file require approval from the platform team
terraform/                          @org/platform-team
terraform/environments/prod/        @org/platform-team @org/security-team
.gitea/workflows/                   @org/platform-team
```

Commit this to the root of the repository as `CODEOWNERS`.

---

## 7. Configure Deployment Environments (Approval Gates)

Gitea environments add a **manual approval gate** before a job runs.
This is how the prod apply job pauses and waits for a human to click "Approve".

Go to: **Repository → Settings → Environments**

### Create environment: `dev-deploy`

| Setting | Value |
|---------|-------|
| Name | `dev-deploy` |
| Required reviewers | (none — auto-deploys) |
| Wait timer | 0 minutes |

### Create environment: `staging-deploy`

| Setting | Value |
|---------|-------|
| Name | `staging-deploy` |
| Required reviewers | `@org/platform-team` (1 reviewer) |
| Wait timer | 0 minutes |

### Create environment: `prod-deploy`

| Setting | Value |
|---------|-------|
| Name | `prod-deploy` |
| Required reviewers | `@org/platform-team`, `@org/security-team` (2 reviewers, **both** required) |
| Wait timer | 5 minutes (gives reviewers time to review the final plan output) |
| Deployment branch policy | Only allow `main` branch |

> When the apply workflow reaches the `apply-prod` job, it pauses at the
> `environment: prod-deploy` gate. Gitea sends a notification to the required
> reviewers. They review the final plan (re-run within the job for confidence)
> and click "Approve" in the UI at:
> **Repository → Actions → [Run] → prod-deploy → Review deployments**

---

## 8. Gitea API-Based Access Token for CI Comments

The plan workflow posts comments to PRs. Create a dedicated bot token:

1. Create a Gitea user: `ci-bot`
2. Generate a token: **User Settings → Applications → Generate Token**
   - Scope: `issue` (write), `repository` (read)
3. Add as repository secret: `GITEA_TOKEN`

Update the workflow `env` or `github-script` steps to use `GITEA_TOKEN`
when posting comments (Gitea uses the same `GITHUB_TOKEN` variable name
for the built-in token, so this may work automatically).

---

## 9. Terraform State Backend — MinIO Setup

```bash
# Create the state bucket
mc alias set minio https://minio.internal.example.com ACCESS_KEY SECRET_KEY
mc mb minio/terraform-state-datadog-op
mc anonymous set none minio/terraform-state-datadog-op

# Enable versioning (critical for state recovery)
mc version enable minio/terraform-state-datadog-op
```

For the DynamoDB-compatible state locking, use a local tfstate lock file
or deploy [DynamoDB Local](https://hub.docker.com/r/amazon/dynamodb-local) / 
use [Terraform's built-in locking with S3](https://developer.hashicorp.com/terraform/language/backend/s3).

---

## 10. End-to-End Workflow Summary

```
Developer
  │
  ├─ git checkout -b feature/add-pii-redactor
  ├─ [edit terraform/environments/prod/main.tf]
  ├─ bash scripts/validate_processors.sh   ← pre-push validation
  ├─ git push origin feature/add-pii-redactor
  │
  ▼
Gitea MR created against main
  │
  ├─ CI runs: plan.yaml
  │     ├─ terraform fmt -check
  │     ├─ terraform validate
  │     ├─ terraform plan (dev)   → comment posted on MR
  │     ├─ terraform plan (staging) → comment posted on MR
  │     └─ terraform plan (prod) → ⚠️ highlighted comment posted on MR
  │
  ├─ Required reviewers review plan output in MR comments
  ├─ 2 approvals granted (enforced by branch protection)
  ├─ All CI checks green
  │
  ▼
Merge to main
  │
  ├─ CD runs: apply.yaml
  │     ├─ apply-dev (auto)
  │     ├─ apply-staging → PAUSES for 1 approval in Gitea UI
  │     └─ apply-prod   → PAUSES for 2 approvals + 5-min wait timer
  │                         (shows final plan before approvers click approve)
  │
  ▼
Datadog Observability Pipeline processors updated ✅
```

---

## 11. Rollback Procedure

If a processor change causes issues in Datadog:

```bash
# Option 1: Git revert (preferred — creates a new commit, full audit trail)
git revert HEAD
git push origin main
# The apply workflow will automatically revert the processor config

# Option 2: Emergency manual rollback (skip CI — use sparingly)
cd terraform/environments/prod
terraform init
export TF_VAR_datadog_api_key="..."
export TF_VAR_datadog_app_key="..."
terraform apply -auto-approve  # after manually reverting main.tf
```

> For option 2, ensure the state file is up to date by running
> `terraform refresh` first, or check that no concurrent CI run is active
> (Terraform state locking will prevent conflicts).

---

## 12. Observability of the Pipeline Itself

Monitor the health of your CI/CD pipeline:

- **Gitea Actions dashboards**: Repository → Actions tab
- **Terraform state**: Check MinIO for state file age/size anomalies  
- **Datadog**: Create a monitor on the `datadog_observability_pipeline` resource
  to alert if processor count or pipeline status changes unexpectedly outside
  of a CI window
- **Alert on long-running `prod-deploy` gates**: If an apply is waiting for
  approval for >30 minutes, something may be wrong — add a Datadog monitor
  or Gitea webhook to flag stale environment approvals
