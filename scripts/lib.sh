#!/usr/bin/env bash
# Shared helpers for the lab scripts. Source, do not execute.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${ENV_DIR:-${REPO_ROOT}/terraform/environments/dev}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

info()  { printf '%s==>%s %s\n' "${BLUE}" "${RESET}" "$*"; }
head2() { printf '\n%s%s%s\n' "${BOLD}" "$*" "${RESET}"; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  %sPASS%s  %s\n' "${GREEN}" "${RESET}" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  %sFAIL%s  %s\n' "${RED}" "${RESET}" "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '  %sWARN%s  %s\n' "${YELLOW}" "${RESET}" "$*"; }

die() { printf '%sError:%s %s\n' "${RED}" "${RESET}" "$*" >&2; exit 1; }

# check <description> <expected> <actual>
check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${desc} (${actual})"
  else
    fail "${desc}: expected '${expected}', got '${actual}'"
  fi
}

require_tools() {
  local missing=()
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required tools: ${missing[*]}"
}

# Read one Terraform output. Fails loudly rather than returning empty.
tf_output() {
  local key="$1" value
  value="$(terraform -chdir="${ENV_DIR}" output -raw "${key}" 2>/dev/null)" \
    || die "no Terraform output '${key}' -- has this environment been applied?"
  [[ -n "${value}" ]] || die "Terraform output '${key}' is empty"
  printf '%s' "${value}"
}

tf_output_json() {
  terraform -chdir="${ENV_DIR}" output -json "$1" 2>/dev/null || printf 'null'
}

summary() {
  head2 "Summary"
  printf '  %spassed: %d%s   ' "${GREEN}" "${PASS_COUNT}" "${RESET}"
  printf '%swarnings: %d%s   ' "${YELLOW}" "${WARN_COUNT}" "${RESET}"
  printf '%sfailed: %d%s\n\n' "${RED}" "${FAIL_COUNT}" "${RESET}"
  [[ ${FAIL_COUNT} -eq 0 ]]
}
