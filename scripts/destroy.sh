#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tear the lab down safely.
#
# terraform destroy on its own fails here, by design: the RDS instance has
# deletion protection on and is configured to take a final snapshot. This
# script does the two things Terraform cannot decide for you --
#
#   1. clear deletion protection on the instance
#   2. decide what happens to the final snapshot and the automated backups
#
# -- and then hands back to Terraform.
#
#   ./scripts/destroy.sh                  keep a final snapshot (default)
#   ./scripts/destroy.sh --no-snapshot    skip it, delete everything
#   ./scripts/destroy.sh --auto-approve   no interactive confirmation
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib.sh disable=SC1091 # -x follows it; bare runs need not
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws jq

KEEP_SNAPSHOT=true
AUTO_APPROVE=false
for arg in "$@"; do
  case "${arg}" in
    --no-snapshot)  KEEP_SNAPSHOT=false ;;
    --auto-approve) AUTO_APPROVE=true ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              die "unknown flag '${arg}'" ;;
  esac
done

REGION="$(tf_output region)"
DB_ID="$(tf_output db_instance_id)"
NAME_PREFIX="$(tf_output name_prefix)"

printf '%sTearing down %s in %s%s\n\n' "${BOLD}" "${NAME_PREFIX}" "${REGION}" "${RESET}"
printf 'RDS instance:    %s\n' "${DB_ID}"
printf 'Final snapshot:  %s\n' "$( [[ "${KEEP_SNAPSHOT}" == true ]] && echo 'yes -- retained after destroy' || echo 'NO -- data is unrecoverable' )"
printf 'Automated backups are deleted with the instance either way.\n\n'

if [[ "${AUTO_APPROVE}" == false ]]; then
  printf 'Type the instance identifier to confirm: '
  read -r confirmation
  [[ "${confirmation}" == "${DB_ID}" ]] || die "confirmation did not match; nothing was destroyed"
fi

info "Clearing deletion protection on ${DB_ID}"
aws rds modify-db-instance --region "${REGION}" \
  --db-instance-identifier "${DB_ID}" \
  --no-deletion-protection \
  --apply-immediately >/dev/null

info "Waiting for the modification to settle"
aws rds wait db-instance-available --region "${REGION}" --db-instance-identifier "${DB_ID}"

DESTROY_ARGS=(-var "db_deletion_protection=false")
if [[ "${KEEP_SNAPSHOT}" == true ]]; then
  DESTROY_ARGS+=(-var "db_skip_final_snapshot=false")
  info "A final snapshot named ${NAME_PREFIX}-final-<timestamp> will be retained"
else
  DESTROY_ARGS+=(-var "db_skip_final_snapshot=true")
  warn "No final snapshot will be taken"
fi

[[ "${AUTO_APPROVE}" == true ]] && DESTROY_ARGS+=(-auto-approve)

info "Running terraform destroy"
terraform -chdir="${ENV_DIR}" destroy "${DESTROY_ARGS[@]}"

printf '\n'
info "Destroy complete. Resources that intentionally outlive it:"
printf '  * the KMS key enters a %s-day pending-deletion window (aws kms cancel-key-deletion to keep it)\n' "7"
printf '  * any final snapshot -- list with:\n'
printf '      aws rds describe-db-snapshots --region %s --snapshot-type manual \\\n' "${REGION}"
printf "        --query \"DBSnapshots[?starts_with(DBSnapshotIdentifier, '%s')].[DBSnapshotIdentifier,SnapshotCreateTime]\" --output table\n" "${NAME_PREFIX}"
printf '  * CloudWatch log groups are removed by Terraform, but check for orphans:\n'
printf '      aws logs describe-log-groups --region %s --log-group-name-prefix /aws/rds/instance/%s\n' "${REGION}" "${DB_ID}"
