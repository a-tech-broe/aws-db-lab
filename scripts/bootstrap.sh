#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Preflight for a first apply. Checks the local toolchain, the AWS identity,
# and the account-level things that make a Phase 1 apply fail 15 minutes in
# rather than immediately.
#
#   ./scripts/bootstrap.sh
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGION="${AWS_REGION:-us-east-1}"

printf '%saws-db-lab -- preflight%s\n' "${BOLD}" "${RESET}"

head2 "Toolchain"
for tool in terraform aws jq; do
  if command -v "${tool}" >/dev/null 2>&1; then
    pass "${tool} $("${tool}" --version 2>&1 | head -1)"
  else
    fail "${tool} not installed"
  fi
done

head2 "AWS identity"
if IDENTITY="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
  ACCOUNT="$(jq -r '.Account' <<<"${IDENTITY}")"
  pass "authenticated as $(jq -r '.Arn' <<<"${IDENTITY}")"
  pass "account ${ACCOUNT}, region ${REGION}"
else
  fail "no valid AWS credentials -- run 'aws configure' or export AWS_PROFILE"
  summary || exit 1
fi

head2 "Account readiness"

az_count="$(aws ec2 describe-availability-zones --region "${REGION}" \
  --query 'length(AvailabilityZones[?ZoneType==`availability-zone` && State==`available`])' --output text)"
if [[ "${az_count}" -ge 3 ]]; then
  pass "${az_count} availability zones in ${REGION}"
else
  fail "${REGION} exposes ${az_count} AZs; Phase 1 wants at least 3"
fi

if aws rds describe-db-engine-versions --region "${REGION}" --engine postgres \
    --query 'DBEngineVersions[?starts_with(EngineVersion, `16.`)] | [0].EngineVersion' \
    --output text | grep -q '^16\.'; then
  pass "PostgreSQL 16 available in ${REGION}"
else
  fail "PostgreSQL 16 not offered in ${REGION}"
fi

vpc_used="$(aws ec2 describe-vpcs --region "${REGION}" --query 'length(Vpcs)' --output text)"
if [[ "${vpc_used}" -lt 5 ]]; then
  pass "${vpc_used} VPC(s) in use (default quota is 5)"
else
  warn "${vpc_used} VPCs already exist -- the default quota is 5 per region"
fi

eip_used="$(aws ec2 describe-addresses --region "${REGION}" --query 'length(Addresses)' --output text)"
if [[ "${eip_used}" -lt 5 ]]; then
  pass "${eip_used} Elastic IP(s) in use (default quota is 5, NAT needs 1-3)"
else
  warn "${eip_used} Elastic IPs already allocated -- the default quota is 5"
fi

# A leftover secret in its recovery window blocks recreating it by name.
if aws secretsmanager list-secrets --region "${REGION}" \
    --include-planned-deletion \
    --filters Key=name,Values=awsdblab \
    --query 'SecretList[?DeletedDate!=null].Name' --output text | grep -q .; then
  warn "a previously deleted awsdblab secret is still in its recovery window; apply will fail on the name collision"
  printf '        force-delete it with: aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery\n'
else
  pass "no soft-deleted secrets blocking the name"
fi

head2 "Next steps"
printf '  cd terraform/environments/dev\n'
printf '  cp terraform.tfvars.example terraform.tfvars   # then edit\n'
printf '  terraform init\n'
printf '  terraform plan\n'
printf '  terraform apply                                 # 15-25 minutes for Multi-AZ\n'
printf '  ../../../scripts/validate.sh\n'

summary
