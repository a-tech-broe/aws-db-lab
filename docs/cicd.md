# CI/CD

```
  pull request                          push to main
       |                                     |
       v                                     v
   [ static ]  fmt, validate, shellcheck  [ static ]
       |         no AWS credentials          |
       v                                     v
   [ plan ]    OIDC -> deploy role        [ plan ]
       |       comment on the PR             |
       v                                     v
   (stop)                                [ apply ]  <- environment gate
                                             |          requires approval
                                             v
                                     scripts/validate.sh
```

## The apply step

`apply` runs only when all three are true:

- the event is a `push` (not a pull request),
- the ref is `refs/heads/main`,
- the plan job reported `exitcode == 2`, meaning it actually found changes.

That last condition matters more than it looks. `terraform plan` exits `0` for
"no changes" and `2` for "changes present" only when given
`-detailed-exitcode`; without it, a *failed* plan and an *empty* plan are
indistinguishable, and a pipeline will happily apply nothing while reporting
success.

### It applies a saved plan, not a fresh one

The `plan` job uploads its `tfplan` binary as an artifact. The `apply` job
downloads that exact file and applies it. It does not re-plan.

This is what makes the approval gate meaningful. If someone else's apply lands
between the plan and your approval, the state serial has moved and Terraform
**refuses the stale plan** rather than applying something no one reviewed. A
re-plan-then-apply pipeline would silently apply the new, unreviewed changes.

### The environment gate

The job declares `environment: dev`. Create that environment in
**Settings -> Environments -> New environment -> `dev`** and add yourself as a
required reviewer. Until you do, the gate is declared but not enforced --
GitHub runs the job immediately.

For a database with `deletion_protection` and a 7-day PITR window, that manual
approval is the last thing standing between a merge and a change to real data.

## Authentication: OIDC, not access keys

There is no `AWS_ACCESS_KEY_ID` anywhere in this repository. The workflow mints
a short-lived OIDC token and exchanges it for the deploy role created in
`terraform/bootstrap`.

The trust policy pins the token's `sub` claim to this repository and to two
contexts: `ref:refs/heads/main` and `pull_request`. Omitting that condition is
the classic OIDC misconfiguration -- it would let any repository on GitHub
assume the role.

The role also carries two explicit denies: it cannot edit its own trust policy
or permissions (`DenySelfEscalation`), and it cannot delete the state bucket or
disable its versioning (`DenyStateBucketAdmin`).

## Remote state is a prerequisite, not a nicety

With local state a CI apply starts from an empty state file. It does not know
the 74 deployed resources exist, so it tries to create them all again and
collides on every name. The state must live somewhere both the pipeline and
the operator can read.

Locking uses S3 native lockfiles (`use_lockfile = true`, Terraform 1.10+), so
there is no DynamoDB table to run. The `concurrency` group in the workflow is a
second layer: it serializes runs before they ever reach the lock.

## Variables: what lives where

Terraform reads variables in this precedence order (later wins):

```
  TF_VAR_*  <  terraform.tfvars  <  *.auto.tfvars  <  -var / -var-file
```

| Setting | Where it lives | Why |
| --- | --- | --- |
| region, CIDRs, instance class, AZ count, bastion toggle | `dev.auto.tfvars`, committed | CI and your laptop must plan identically, or every pipeline run shows phantom drift |
| `alarm_email` | `terraform.tfvars` locally (gitignored); `TF_VAR_ALARM_EMAIL` secret in CI | a personal address does not belong in git |

`TF_VAR_*` sits at the *lowest* precedence, which is exactly what makes this
work: the committed `dev.auto.tfvars` deliberately omits `alarm_email`, so
nothing shadows the value coming from the secret.

## One-time setup

```bash
# 1. State bucket, OIDC provider, deploy role
cd terraform/bootstrap
terraform init
terraform apply -var github_repository=a-tech-broe/aws-db-lab

# 2. Move the dev environment onto remote state
terraform -chdir=terraform/bootstrap output -raw backend_block
#    paste into terraform/environments/dev/versions.tf, then:
cd ../environments/dev
terraform init -migrate-state

# 3. Tell GitHub about the role
terraform -chdir=../../bootstrap output -raw github_setup   # prints the gh commands
```

Then create the `dev` environment with a required reviewer, as above.

## What the pipeline deliberately does not do

- **No `terraform destroy`.** Teardown stays a manual, local act via
  `scripts/destroy.sh`, which clears deletion protection and makes you type the
  instance identifier. A pipeline that can destroy a database on merge is a
  pipeline that eventually will.
- **No auto-merge or auto-approve.** `-auto-approve` never appears; the saved
  plan plus the environment gate replace it.
- **No apply from a pull request.** PR runs get read access to plan, and stop.
