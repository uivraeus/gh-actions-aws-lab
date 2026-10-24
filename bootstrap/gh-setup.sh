#!/usr/bin/env bash
# Configure the GitHub side after `terraform apply` in bootstrap/:
#   - repo variables used by the workflow to build role ARNs
#   - one GitHub environment per env, deployable from `main` only
#   - optional required reviewer on prod (needs a public repo or a paid plan)
#
# Usage: bootstrap/gh-setup.sh OWNER/REPO [--prod-reviewer]
# Requires: gh (authenticated, repo admin), terraform, jq
set -euo pipefail

repo="${1:?usage: $0 OWNER/REPO [--prod-reviewer]}"
prod_reviewer="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"

out() { terraform -chdir="$here" output -raw "$1"; }
account_id="$(out account_id)"
region="$(out region)"
prefix="$(out name_prefix)"
envs="$(terraform -chdir="$here" output -json plan_role_arns | jq -r 'keys[]')"

echo "Repo variables on $repo"
gh variable set AWS_ACCOUNT_ID --repo "$repo" --body "$account_id"
gh variable set AWS_REGION     --repo "$repo" --body "$region"
gh variable set TF_NAME_PREFIX --repo "$repo" --body "$prefix"

for env in $envs; do
  echo "Environment: $env"
  body='{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  if [[ "$env" == "prod" && "$prod_reviewer" == "--prod-reviewer" ]]; then
    uid="$(gh api user -q .id)"
    body="$(jq -c --argjson id "$uid" '. + {reviewers:[{type:"User",id:$id}], prevent_self_review:false}' <<<"$body")"
  fi
  gh api -X PUT "repos/$repo/environments/$env" --input - <<<"$body" >/dev/null

  # Only `main` may deploy to this environment (idempotent: ignore "already exists").
  gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null 2>&1 || true
done

echo
echo "Backend files (paste into infra/envs/<env>.s3.tfbackend if not done yet):"
terraform -chdir="$here" output -json backend_files | jq -r 'to_entries[] | "--- \(.key)\n\(.value)"'
