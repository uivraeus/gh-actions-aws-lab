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

GitHub's OIDC token carries a `sub` claim that depends on how the job runs:

| Job | `sub` | Trusted by |
| --- | --- | --- |
| PR job, no `environment:` | `repo:OWNER/REPO:pull_request` | `<prefix>-<env>-plan` |
| Job with `environment: dev` | `repo:OWNER/REPO:environment:dev` | `<prefix>-dev-apply` |

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

## Setup

### 1. Bootstrap AWS (admin creds, local)

```sh
export AWS_PROFILE=my-admin && aws sso login
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set github_repository, region
terraform init
terraform apply
```

If the account already has the `token.actions.githubusercontent.com` OIDC provider, set `create_oidc_provider = false`.

Optionally move the bootstrap state into the new bucket (see the comment in `bootstrap/versions.tf`).

### 2. Point infra at the bucket

Copy `terraform output -json backend_files` into `infra/envs/dev.s3.tfbackend` and `prod.s3.tfbackend`. The only values to replace are the bucket name (it contains the account ID) and the region.

### 3. Configure GitHub

```sh
git remote add origin git@github.com:OWNER/REPO.git && git push -u origin main
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
- Use separate AWS accounts per env: run bootstrap per account, use a separate state bucket per env, and set `AWS_ACCOUNT_ID` as an environment variable instead of a repo variable.
- Add a permissions boundary to the apply roles.
- Customize the OIDC `sub` claim template (e.g. add `job_workflow_ref`) to pin roles to a specific workflow file.
- Fork PRs get no OIDC token, so plan won't run for them. That's expected.
