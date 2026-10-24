# Local runs use whatever the AWS credential chain gives you, e.g.:
#   export AWS_PROFILE=my-admin && aws sso login
ENV ?= dev
TF  := terraform -chdir=infra

.PHONY: init plan apply destroy fmt whoami

whoami:
	aws sts get-caller-identity

# -reconfigure because switching ENV points the same .terraform/ at a different state key
init:
	$(TF) init -reconfigure -backend-config=envs/$(ENV).s3.tfbackend

plan: init
	$(TF) plan -var-file=envs/$(ENV).tfvars

apply: init
	$(TF) apply -var-file=envs/$(ENV).tfvars

destroy: init
	$(TF) destroy -var-file=envs/$(ENV).tfvars

fmt:
	terraform fmt -recursive
