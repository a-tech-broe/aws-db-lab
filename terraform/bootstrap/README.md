# Bootstrap

The chicken-and-egg layer. Creates the S3 bucket that every environment stores
its Terraform state in, plus the GitHub OIDC provider and IAM role that let
Actions run Terraform without a long-lived access key.

Applied **once, by hand**, with local state -- it cannot store its state in the
bucket it is creating.

## Why this has to exist before CI can apply anything

With local state, `terraform apply` in a GitHub runner starts from an empty
state file. It does not know the 74 resources already exist, so it tries to
create all of them again and fails on every name collision -- or worse,
succeeds in creating duplicates. Remote state is what makes the pipeline and
the operator agree on what is already deployed.

State locking prevents the other half of the problem: two applies running at
once. This uses S3 native locking (`use_lockfile = true`, Terraform 1.10+),
so there is no DynamoDB table to maintain.

## One-time setup

```bash
cd terraform/bootstrap
terraform init
terraform apply -var github_repository=a-tech-broe/aws-db-lab
```

Then wire the repository up:

```bash
terraform output -raw github_setup   # prints the exact gh commands
```

- `AWS_DEPLOY_ROLE_ARN` and `AWS_REGION` are repository **variables** (not
  secrets -- a role ARN is not sensitive, and it is useless without the OIDC
  trust condition).
- `TF_VAR_alarm_email` is a repository **secret**, because it is a personal
  address and `terraform.tfvars` is gitignored.

Finally, copy the backend block into the dev environment and migrate:

```bash
terraform -chdir=terraform/bootstrap output -raw backend_block
# paste into terraform/environments/dev/versions.tf, then:
cd terraform/environments/dev
terraform init -migrate-state
```

## What the deploy role can and cannot do

The trust policy pins `sub` to this repository and to two contexts only:
pushes to `main`, and `pull_request` runs. Without that condition any GitHub
repository in the world could assume the role.

The permission policy grants the services the project uses, then explicitly
denies two things:

- **`DenySelfEscalation`** -- the role cannot modify its own trust policy or
  attach itself new permissions.
- **`DenyStateBucketAdmin`** -- the role cannot delete the state bucket,
  rewrite its policy, or turn off versioning. It can read and write state
  objects; it cannot destroy the audit trail.

IAM write actions are scoped to `arn:aws:iam::<account>:role/awsdblab-*`, so
the pipeline can manage the roles this project creates and nothing else.

## Destroying it

The state bucket has `prevent_destroy = true`. That is deliberate: deleting it
orphans every resource in every environment, and there is no recovery. To
remove it you must first delete that lifecycle block, which forces the decision
to be a code change someone reviews.
