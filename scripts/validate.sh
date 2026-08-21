#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Assert that the deployed Phase 1 environment matches its intent.
#
# This is not "did terraform apply exit 0" -- it re-reads the live AWS state
# and checks the properties Phase 1 promised: private database, encryption,
# Multi-AZ, backups, monitoring, alarms, and a security group with exactly one
# ingress source.
#
#   ./scripts/validate.sh          run every check
#   ./scripts/validate.sh --quick  skip the slower API sweeps
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib.sh disable=SC1091 # -x follows it; bare runs need not
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

require_tools terraform aws jq

REGION="$(tf_output region)"
DB_ID="$(tf_output db_instance_id)"
VPC_ID="$(tf_output vpc_id)"
DB_SG="$(tf_output db_security_group_id)"
KMS_ARN="$(tf_output kms_key_arn)"
SECRET_ARN="$(tf_output db_secret_arn)"

printf '%saws-db-lab -- Phase 1 validation%s\n' "${BOLD}" "${RESET}"
printf 'region: %s   instance: %s   vpc: %s\n' "${REGION}" "${DB_ID}" "${VPC_ID}"

# --------------------------------------------------------------------------
head2 "Networking"
# --------------------------------------------------------------------------

SUBNETS="$(aws ec2 describe-subnets --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" --output json)"

for tier in public private-app private-db; do
  count="$(jq --arg t "${tier}" \
    '[.Subnets[] | select(.Tags[]? | select(.Key=="Tier") | .Value == $t)] | length' \
    <<<"${SUBNETS}")"
  az_count="$(jq --arg t "${tier}" \
    '[.Subnets[] | select(.Tags[]? | select(.Key=="Tier") | .Value == $t) | .AvailabilityZone] | unique | length' \
    <<<"${SUBNETS}")"
  if [[ "${count}" -ge 2 && "${count}" == "${az_count}" ]]; then
    pass "${tier} subnets span ${az_count} AZs"
  else
    fail "${tier}: ${count} subnets across ${az_count} AZs (want >=2, one per AZ)"
  fi
done

# The database subnets must have no route to an internet or NAT gateway.
DB_SUBNET_IDS="$(tf_output_json private_db_subnet_ids | jq -r '.[]')"
db_route_leak=0
for subnet in ${DB_SUBNET_IDS}; do
  rt="$(aws ec2 describe-route-tables --region "${REGION}" \
    --filters "Name=association.subnet-id,Values=${subnet}" --output json)"

  # An unassociated subnet silently inherits the main route table, which may
  # well have an IGW route -- that is a leak, not a clean result.
  if [[ "$(jq '.RouteTables | length' <<<"${rt}")" -eq 0 ]]; then
    db_route_leak=1
    fail "database subnet ${subnet} has no explicit route table; it inherits the main one"
    continue
  fi

  if jq -e '[.RouteTables[].Routes[]] | any(.GatewayId? // "" | startswith("igw-")) or any(has("NatGatewayId"))' \
      <<<"${rt}" >/dev/null; then
    db_route_leak=1
    fail "database subnet ${subnet} has a route to the internet"
  fi
done
[[ ${db_route_leak} -eq 0 ]] && pass "database subnets have no internet or NAT route"

# --------------------------------------------------------------------------
head2 "Security"
# --------------------------------------------------------------------------

SG="$(aws ec2 describe-security-groups --region "${REGION}" \
  --group-ids "${DB_SG}" --output json)"

if jq -e '[.SecurityGroups[0].IpPermissions[].IpRanges[]?.CidrIp] | index("0.0.0.0/0")' \
    <<<"${SG}" >/dev/null; then
  fail "database security group allows ingress from 0.0.0.0/0"
else
  pass "database security group has no 0.0.0.0/0 ingress"
fi

cidr_rules="$(jq '[.SecurityGroups[0].IpPermissions[].IpRanges[]?] | length' <<<"${SG}")"
sg_rules="$(jq '[.SecurityGroups[0].IpPermissions[].UserIdGroupPairs[]?] | length' <<<"${SG}")"
if [[ "${cidr_rules}" -eq 0 && "${sg_rules}" -ge 1 ]]; then
  pass "database ingress is security-group referenced only (${sg_rules} rule(s), 0 CIDR rules)"
else
  fail "database ingress has ${cidr_rules} CIDR rule(s); expected 0"
fi

rotation="$(aws kms get-key-rotation-status --region "${REGION}" --key-id "${KMS_ARN}" \
  --query 'KeyRotationEnabled' --output text)"
check "KMS key rotation enabled" "True" "${rotation}"

secret_kms="$(aws secretsmanager describe-secret --region "${REGION}" --secret-id "${SECRET_ARN}" \
  --query 'KmsKeyId' --output text)"
if [[ "${secret_kms}" == "${KMS_ARN}" || "${secret_kms}" == alias/* ]]; then
  pass "credential secret encrypted with the customer-managed key"
else
  fail "credential secret uses '${secret_kms}', expected the project CMK"
fi

# The secret must be a complete connection descriptor, not just a password.
SECRET_JSON="$(aws secretsmanager get-secret-value --region "${REGION}" --secret-id "${SECRET_ARN}" \
  --query 'SecretString' --output text)"
for key in username password host port dbname engine; do
  if jq -e --arg k "${key}" 'has($k) and (.[$k] | tostring | length > 0)' <<<"${SECRET_JSON}" >/dev/null; then
    pass "secret contains '${key}'"
  else
    fail "secret is missing '${key}' -- the RDS module did not enrich it"
  fi
done
unset SECRET_JSON

# --------------------------------------------------------------------------
head2 "Database"
# --------------------------------------------------------------------------

DB="$(aws rds describe-db-instances --region "${REGION}" \
  --db-instance-identifier "${DB_ID}" --query 'DBInstances[0]' --output json)"

check "status available"          "available" "$(jq -r '.DBInstanceStatus' <<<"${DB}")"
check "Multi-AZ enabled"          "true"      "$(jq -r '.MultiAZ' <<<"${DB}")"
check "storage encrypted"         "true"      "$(jq -r '.StorageEncrypted' <<<"${DB}")"
check "not publicly accessible"   "false"     "$(jq -r '.PubliclyAccessible' <<<"${DB}")"
check "deletion protection"       "true"      "$(jq -r '.DeletionProtection' <<<"${DB}")"
check "Performance Insights on"   "true"      "$(jq -r '.PerformanceInsightsEnabled' <<<"${DB}")"
check "IAM auth enabled"          "true"      "$(jq -r '.IAMDatabaseAuthenticationEnabled' <<<"${DB}")"

check "storage encrypted with the project CMK" "${KMS_ARN}" "$(jq -r '.KmsKeyId' <<<"${DB}")"

retention="$(jq -r '.BackupRetentionPeriod' <<<"${DB}")"
if [[ "${retention}" -ge 7 ]]; then
  pass "backup retention ${retention} days (PITR window)"
else
  fail "backup retention ${retention} days; want >= 7"
fi

mon_interval="$(jq -r '.MonitoringInterval' <<<"${DB}")"
if [[ "${mon_interval}" -gt 0 ]]; then
  pass "Enhanced Monitoring every ${mon_interval}s"
else
  fail "Enhanced Monitoring disabled"
fi

pg_name="$(jq -r '.DBParameterGroups[0].DBParameterGroupName' <<<"${DB}")"
pg_status="$(jq -r '.DBParameterGroups[0].ParameterApplyStatus' <<<"${DB}")"
if [[ "${pg_name}" == default.* ]]; then
  fail "instance is on the default parameter group"
elif [[ "${pg_status}" == "in-sync" ]]; then
  pass "custom parameter group ${pg_name} in-sync"
else
  warn "parameter group ${pg_name} status '${pg_status}' -- a reboot is pending"
fi

logs="$(jq -r '(.EnabledCloudwatchLogsExports // []) | join(",")' <<<"${DB}")"
if [[ "${logs}" == *postgresql* ]]; then
  pass "PostgreSQL logs exported to CloudWatch (${logs})"
else
  fail "PostgreSQL log export is not enabled"
fi

# A PITR window only exists once the first automated backup lands.
latest="$(jq -r '.LatestRestorableTime // "none"' <<<"${DB}")"
if [[ "${latest}" == "none" ]]; then
  warn "no LatestRestorableTime yet -- the first automated backup has not completed"
else
  pass "point-in-time recovery available up to ${latest}"
fi

if [[ "${QUICK}" == false ]]; then
  # Fetch the parameter group ONCE as JSON and filter locally.
  #
  # Do not use --query here: the AWS CLI applies --query to each page
  # separately, so a paginated result (this group returns ~420 parameters
  # across 5 pages) yields one row per page rather than one row overall.
  # Plain --output json merges the pages into a single document.
  PARAMS_JSON="$(aws rds describe-db-parameters --region "${REGION}" \
    --db-parameter-group-name "${pg_name}" --output json)"

  param_value() {
    jq -r --arg n "$1" \
      '.Parameters[] | select(.ParameterName == $n) | .ParameterValue // ""' \
      <<<"${PARAMS_JSON}"
  }

  # rds.force_ssl is the control that makes unencrypted connections impossible.
  # RDS reports it with Source=system even when set by a user parameter group,
  # so filter on the name only, never on --source.
  check "rds.force_ssl enforced" "1" "$(param_value 'rds.force_ssl')"

  preload="$(param_value 'shared_preload_libraries')"
  if [[ "${preload}" == *pg_stat_statements* ]]; then
    pass "pg_stat_statements preloaded"
  else
    fail "pg_stat_statements not in shared_preload_libraries (got '${preload}')"
  fi

  track="$(param_value 'pg_stat_statements.track')"
  check "pg_stat_statements.track" "ALL" "${track}"

  unset PARAMS_JSON
fi

# --------------------------------------------------------------------------
head2 "Observability"
# --------------------------------------------------------------------------

# Read into an array rather than splitting a string: alarm names are passed
# as separate argv entries, and a bare ${VAR} would also glob.
EXPECTED_ALARMS=()
while IFS= read -r alarm_name; do
  [[ -n "${alarm_name}" ]] && EXPECTED_ALARMS+=("${alarm_name}")
done < <(tf_output_json alarm_names | jq -r '.[]')

[[ ${#EXPECTED_ALARMS[@]} -gt 0 ]] || die "the alarm_names output is empty"

ALARM_STATE="$(aws cloudwatch describe-alarms --region "${REGION}" \
  --alarm-names "${EXPECTED_ALARMS[@]}" --output json)"

for alarm in "${EXPECTED_ALARMS[@]}"; do
  state="$(jq -r --arg a "${alarm}" \
    '.MetricAlarms[] | select(.AlarmName == $a) | .StateValue' <<<"${ALARM_STATE}")"
  case "${state}" in
    OK)                pass "${alarm} -> OK" ;;
    INSUFFICIENT_DATA) warn "${alarm} -> INSUFFICIENT_DATA (normal for a few minutes after apply)" ;;
    ALARM)             fail "${alarm} -> ALARM" ;;
    "")                fail "${alarm} does not exist" ;;
    *)                 warn "${alarm} -> ${state}" ;;
  esac
done

# An alarm with no action is decoration.
actionless="$(jq -r '[.MetricAlarms[] | select((.AlarmActions | length) == 0) | .AlarmName] | join(", ")' \
  <<<"${ALARM_STATE}")"
if [[ -z "${actionless}" ]]; then
  pass "every alarm has an SNS action"
else
  fail "alarms without any action: ${actionless}"
fi

TOPIC_ARN="$(tf_output alarm_topic_arn)"
# shellcheck disable=SC2016  # backticks are JMESPath literal quoting, not shell
subs="$(aws sns list-subscriptions-by-topic --region "${REGION}" --topic-arn "${TOPIC_ARN}" \
  --query 'length(Subscriptions[?SubscriptionArn!=`PendingConfirmation`])' --output text)"
if [[ "${subs}" -gt 0 ]]; then
  pass "${subs} confirmed subscription(s) on the alarm topic"
else
  warn "alarm topic has no confirmed subscriber -- set alarm_email and confirm the email"
fi

summary
