#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Open a psql session against the private RDS instance.
#
# The database has no public endpoint and its subnets have no internet route,
# so a direct connection from a laptop cannot work -- the hostname resolves to
# a private address (and many home routers drop that answer entirely as DNS
# rebinding protection). This tunnels through the SSM maintenance host
# instead: no SSH key, no open port, IAM-authenticated and CloudTrail-audited.
#
#   ./scripts/db-connect.sh                     master user, password from Secrets Manager
#   ./scripts/db-connect.sh --iam               app_iam user, short-lived IAM token
#   ./scripts/db-connect.sh -c 'SELECT 1;'      run one statement and exit
#   ./scripts/db-connect.sh -f sql/001-*.sql    run a file
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib.sh disable=SC1091 # -x follows it; bare runs need not
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws jq psql session-manager-plugin

USE_IAM=false
LOCAL_PORT="${LOCAL_PORT:-15432}"
PSQL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iam)   USE_IAM=true; shift ;;
    --port)  LOCAL_PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *)       PSQL_ARGS+=("$1"); shift ;;
  esac
done

REGION="$(tf_output region)"
RDSHOST="$(tf_output db_instance_address)"
DBPORT="$(tf_output db_instance_port)"
DBNAME="$(tf_output db_name)"

BASTION="$(terraform -chdir="${ENV_DIR}" output -raw bastion_instance_id 2>/dev/null || true)"
if [[ -z "${BASTION}" || "${BASTION}" == "null" ]]; then
  die "no maintenance host. Set enable_bastion = true and apply, or run this from inside the VPC."
fi

# The AWS root CA bundle, so the server certificate can actually be verified.
CA_BUNDLE="${REPO_ROOT}/global-bundle.pem"
if [[ ! -s "${CA_BUNDLE}" ]]; then
  info "Fetching the RDS CA bundle"
  curl -fsSL -o "${CA_BUNDLE}" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
fi

info "Opening a tunnel: localhost:${LOCAL_PORT} -> ${RDSHOST}:${DBPORT} via ${BASTION}"
TUNNEL_LOG="$(mktemp)"
aws ssm start-session \
  --region "${REGION}" \
  --target "${BASTION}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${RDSHOST}\"],\"portNumber\":[\"${DBPORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
  >"${TUNNEL_LOG}" 2>&1 &
TUNNEL_PID=$!

cleanup() {
  kill "${TUNNEL_PID}" 2>/dev/null || true
  wait "${TUNNEL_PID}" 2>/dev/null || true
  rm -f "${TUNNEL_LOG}"
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null && break
  kill -0 "${TUNNEL_PID}" 2>/dev/null || { cat "${TUNNEL_LOG}"; die "the tunnel exited before it opened"; }
  sleep 1
done
nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null || { cat "${TUNNEL_LOG}"; die "the tunnel never opened on port ${LOCAL_PORT}"; }

if [[ "${USE_IAM}" == true ]]; then
  DBUSER="app_iam"
  # Signed against the real endpoint, not the tunnel. Valid for 15 minutes.
  PGPASSWORD="$(aws rds generate-db-auth-token \
    --hostname "${RDSHOST}" --port "${DBPORT}" --username "${DBUSER}" --region "${REGION}")"
  info "Authenticating as ${DBUSER} with an IAM token (expires in 15 minutes)"
else
  SECRET_JSON="$(aws secretsmanager get-secret-value --region "${REGION}" \
    --secret-id "$(tf_output db_secret_name)" --query SecretString --output text)"
  DBUSER="$(jq -r .username <<<"${SECRET_JSON}")"
  PGPASSWORD="$(jq -r .password <<<"${SECRET_JSON}")"
  unset SECRET_JSON
  info "Authenticating as ${DBUSER} with the Secrets Manager credential"
fi
export PGPASSWORD

# verify-ca, not verify-full: the server certificate is issued for the RDS
# hostname, but through the tunnel psql connects to 127.0.0.1, so hostname
# verification cannot match. verify-ca still validates the chain against the
# AWS bundle, so the connection is authenticated and encrypted.
psql "host=127.0.0.1 port=${LOCAL_PORT} dbname=${DBNAME} user=${DBUSER} \
      sslmode=verify-ca sslrootcert=${CA_BUNDLE}" "${PSQL_ARGS[@]+"${PSQL_ARGS[@]}"}"
