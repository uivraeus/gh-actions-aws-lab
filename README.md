# gh-actions-aws-lab

Lab for running Terraform against AWS both locally and from GitHub Actions, sharing one S3 backend.

- **Locally**: plan/apply with your own SSO credentials (`AWS_PROFILE` + `aws sso login`).
- **PRs**: `terraform plan` for every environment, using a read-only role per env.
- **Merge to `main`**: `terraform apply` to `dev`, then `prod`, each through a GitHub environment and a write role.

Nothing in the Terraform code names a profile or credentials, so the same config works in both places via the AWS credential chain.

## Layout

```
bootstrap/            run manually, once, with admin creds (local state)
  state.tf            S3 state bucket (versioned, SSE, TLS-only, no public access)
  iam.tf              GitHub OIDC provider + <prefix>-<env>-plan / -apply roles
  gh-setup.sh         GitHub repo variables + environments (main-only deploys)
infra/                the managed resources (one S3 bucket per env)
  envs/<env>.s3.tfbackend   backend config (bucket, key, region, use_lockfile)
  envs/<env>.tfvars         per-env variables
.github/workflows/
  terraform.yml       triggers: PR -> plan matrix, main -> apply dev -> apply prod
  _terraform.yml      reusable: one env, plan or apply
Makefile              local helpers: make plan ENV=dev
```

## How the roles are kept apart

GitHub's OIDC token carries a `sub` claim that depends on how the job runs. `<sub-prefix>` is the repo's immutable subject prefix, `repo:OWNER@OWNER_ID/REPO@REPO_ID`. It's the default for repos created after 2026-07-15. Because of the numeric IDs, a re-created or transferred repo with the same name won't match.

| Job | `sub` | Trusted by |
| --- | --- | --- |
| PR job, no `environment:` | `<sub-prefix>:pull_request` | `<prefix>-<env>-plan` |
| Job with `environment: dev` | `<sub-prefix>:environment:dev` | `<prefix>-dev-apply` |

Each GitHub environment only accepts deployments from `main` (set by `gh-setup.sh`). A PR that edits the workflow to ask for the apply role still fails: its job can't enter the environment, so it never gets a token with the environment `sub`.

Permissions, all scoped per env:

| | State bucket | Workload (`arn:aws:s3:::<prefix>-<env>-*`) |
| --- | --- | --- |
| plan | `ListBucket`; `GetObject` on `envs/<env>/terraform.tfstate`; Get/Put/Delete on its `.tflock` | `s3:Get*`, `s3:List*` on the bucket only (no object reads) |
| apply | the same, plus `PutObject` on the state key | `s3:*` on the bucket and its objects |

Notes:
- Locking uses S3-native lock files (`use_lockfile = true`, Terraform ≥ 1.10), so there's no DynamoDB table. The plan role can still write the `.tflock` object. To make plan strictly read-only, remove the `StateLock` statement from the plan policy and run `plan -lock=false`.
- The workload permissions follow a naming convention. Anything you add in `infra/` has to fit inside it, or you have to extend both role policies in `bootstrap/iam.tf`. That's deliberate: adding a new resource type means a bootstrap change.
- The plan role can only read its own env's state. The `dev` plan role can't read `prod` state.
- Fork PRs get no OIDC token, so their plan jobs fail to assume the plan role. That's expected: outside contributors never get AWS credentials.

## Prerequisites

- **This repo on GitHub, under your own account.** The trust policies are tied to its owner and repo IDs, so a fork or copy needs its own bootstrap.
  - **Public**, if you're on the Free plan. Deployment-branch policies need a public repo (or Pro/Team), and required reviewers need a public repo (or Enterprise).
  - **Immutable OIDC subject claims enabled** (Settings → Actions → OIDC). They're on by default for repos created or renamed after 2026-07-15, and older repos can opt in.
- **An AWS account and an admin profile** you can `aws sso login` with.
- **Tools:** Terraform ≥ 1.10, the AWS CLI, `gh` (authenticated, with admin on the repo) and `jq`.

## Setup

### 1. Bootstrap AWS (admin creds, local)

```sh
gh api repos/OWNER/REPO/actions/oidc/customization/sub -q .sub_claim_prefix   # value for github_oidc_sub_prefix

export AWS_PROFILE=my-admin && aws sso login
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set github_oidc_sub_prefix, region
terraform init
terraform apply
```

If the account already has the `token.actions.githubusercontent.com` OIDC provider, set `create_oidc_provider = false`.

Optionally move the bootstrap state into the new bucket (see the comment in `bootstrap/versions.tf`).

### 2. Point infra at the bucket

Make `infra/envs/dev.s3.tfbackend` and `prod.s3.tfbackend` match `terraform output -json backend_files`. The bucket name contains the account ID, so it differs per account.

### 3. Configure GitHub

```sh
bootstrap/gh-setup.sh OWNER/REPO               # add --prod-reviewer for an approval gate on prod
```

This sets the repo variables `AWS_ACCOUNT_ID`, `AWS_REGION` and `TF_NAME_PREFIX`, and creates the `dev`/`prod` environments with a `main`-only branch policy.

### 4. Use it

Locally:

```sh
export AWS_PROFILE=my-admin && aws sso login
make plan ENV=dev
make apply ENV=dev
```

In CI: open a PR that touches `infra/`. The job summary shows the dev and prod plans. Merge it, and dev is applied, then prod (after approval if you enabled it).

## Things to try next

- Make plan output a PR comment (needs `pull-requests: write`).
- Remove the skipped-check noise on PRs: each call to `_terraform.yml` brings both its `plan` and `apply` jobs, and one is always skipped. Fixed inner job names, or separate plan/apply workflows, would fix that.
- Set `role-session-name` (e.g. `gha-<run_id>-<attempt>`) so CloudTrail entries can be traced to a workflow run, instead of all showing `GitHubActions`.
- Move the bootstrap state from the local file into the state bucket.
- Customize the OIDC `sub` claim template (e.g. add `job_workflow_ref`) to pin roles to a specific workflow file.
- Harden the repo and codify all its settings in `gh-setup.sh`, instead of relying on manual GUI toggles:
  - a ruleset on `main`: require a PR and a passing plan check, block force pushes and deletion, no bypass;
  - the settings that are currently set by hand: collaborators-only PR creation, squash-only merges, delete branch on merge, auto-merge;
  - fork PR workflow approval for all external contributors.

  Required checks also need a single `plan-result` summary job (with `if: always()`), and the path filter on `pull_request` has to go. Otherwise PRs that don't touch `infra/` could never be merged.
- Prod: approve the actual plan. Today the reviewer approves before the apply job has planned anything, so they never see the plan that gets applied. Instead:
  - a plan job on `main` saves the plan as an artifact, and the reviewer approves that plan;
  - the gated apply job then does a fresh plan (with refresh), compares its `resource_changes` with the approved plan, fails on any difference, and otherwise applies the fresh plan.

  A completed apply then means state, code and real-world drift all matched what was approved. The remaining few-second window between that fresh plan and the apply is an accepted risk.
