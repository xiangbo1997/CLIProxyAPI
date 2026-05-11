#!/usr/bin/env bash
set -euo pipefail

MODE="apply"
DRY_RUN=false
HOST="${CLOUDFLARE_HOST:-proxy.feixingqi.shop}"
PATH_PREFIX="${CLOUDFLARE_PATH_PREFIX:-/v1}"
UA_PREFIX="${CLOUDFLARE_UA_PREFIX:-OpenAI/Python}"
ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-}"
API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
API_BASE="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
RULE_REF="${CLOUDFLARE_RULE_REF:-allow_openai_python_sdk_proxy_v1}"
RULE_DESCRIPTION="${CLOUDFLARE_RULE_DESCRIPTION:-Allow OpenAI Python SDK traffic for ${HOST}${PATH_PREFIX}}"
RULE_DESCRIPTION_EXPLICIT=false
if [[ -n "${CLOUDFLARE_RULE_DESCRIPTION+x}" ]]; then
  RULE_DESCRIPTION_EXPLICIT=true
fi
LOG_MATCHING="${CLOUDFLARE_LOG_MATCHING:-true}"
SKIP_PRODUCTS="${CLOUDFLARE_SKIP_PRODUCTS:-uaBlock,bic,securityLevel,waf,rateLimit}"
SKIP_PHASES="${CLOUDFLARE_SKIP_PHASES:-http_request_firewall_managed,http_ratelimit,http_request_sbfm}"
SKIP_CURRENT_RULESET="${CLOUDFLARE_SKIP_CURRENT_RULESET:-true}"
ENTRYPOINT_NAME="${CLOUDFLARE_ENTRYPOINT_NAME:-Zone-level phase entry point}"
ENTRYPOINT_DESCRIPTION="${CLOUDFLARE_ENTRYPOINT_DESCRIPTION:-Created by CLIProxyAPI Cloudflare helper}"

HTTP_STATUS=""
RESPONSE_BODY=""

usage() {
  cat <<'USAGE'
Usage:
  cloudflare-allow-openai-python-ua.sh [options]

Apply or remove a narrow Cloudflare skip rule for requests matching:
  host == proxy.feixingqi.shop
  path starts with /v1
  user-agent starts with OpenAI/Python

Authentication:
  --api-token <token>               Cloudflare API token (or CLOUDFLARE_API_TOKEN)
  --zone-id <id>                    Cloudflare zone ID (or CLOUDFLARE_ZONE_ID)
  --zone-name <name>                Cloudflare zone name used to resolve zone ID

Matcher overrides:
  --host <host>                     Host to match (default: proxy.feixingqi.shop)
  --path-prefix <prefix>            Path prefix to match (default: /v1)
  --ua-prefix <prefix>              User-Agent prefix to match (default: OpenAI/Python)
  --description <text>              Rule description
  --rule-ref <ref>                  Stable rule ref for idempotent updates

Skip target overrides:
  --skip-products <csv>             CSV list of legacy products to skip
  --skip-phases <csv>               CSV list of downstream phases to skip
  --skip-current-ruleset            Skip the remainder of the current custom-rules ruleset
  --no-skip-current-ruleset         Do not skip the remainder of the current custom-rules ruleset
  --enable-logging                  Enable Cloudflare logging for matching requests
  --disable-logging                 Disable Cloudflare logging for matching requests

Mode:
  --apply                           Create or update the rule (default)
  --delete                          Delete the rule identified by --rule-ref or --description
  --dry-run                         Print the planned API call without mutating Cloudflare
  -h, --help                        Show this help

Examples:
  ./scripts/cloudflare-allow-openai-python-ua.sh \
    --api-token "$CLOUDFLARE_API_TOKEN" \
    --zone-name feixingqi.shop

  ./scripts/cloudflare-allow-openai-python-ua.sh \
    --api-token "$CLOUDFLARE_API_TOKEN" \
    --zone-id <zone-id> \
    --delete
USAGE
}

log() {
  printf '[cloudflare-rule] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-token)
        API_TOKEN="${2:-}"
        shift 2
        ;;
      --zone-id)
        ZONE_ID="${2:-}"
        shift 2
        ;;
      --zone-name)
        ZONE_NAME="${2:-}"
        shift 2
        ;;
      --host)
        HOST="${2:-}"
        shift 2
        ;;
      --path-prefix)
        PATH_PREFIX="${2:-}"
        shift 2
        ;;
      --ua-prefix)
        UA_PREFIX="${2:-}"
        shift 2
        ;;
      --description)
        RULE_DESCRIPTION="${2:-}"
        RULE_DESCRIPTION_EXPLICIT=true
        shift 2
        ;;
      --rule-ref)
        RULE_REF="${2:-}"
        shift 2
        ;;
      --skip-products)
        SKIP_PRODUCTS="${2:-}"
        shift 2
        ;;
      --skip-phases)
        SKIP_PHASES="${2:-}"
        shift 2
        ;;
      --skip-current-ruleset|--skip-current-phase)
        SKIP_CURRENT_RULESET=true
        shift
        ;;
      --no-skip-current-ruleset|--no-skip-current-phase)
        SKIP_CURRENT_RULESET=false
        shift
        ;;
      --enable-logging)
        LOG_MATCHING=true
        shift
        ;;
      --disable-logging)
        LOG_MATCHING=false
        shift
        ;;
      --apply)
        MODE="apply"
        shift
        ;;
      --delete)
        MODE="delete"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

trim_csv() {
  python3 - "$1" <<'PY'
import sys
parts = [p.strip() for p in sys.argv[1].split(',') if p.strip()]
print(','.join(parts))
PY
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

build_expression() {
  python3 - "$HOST" "$PATH_PREFIX" "$UA_PREFIX" <<'PY'
import json
import sys
host, path_prefix, ua_prefix = sys.argv[1:4]
print(
    f'http.host eq {json.dumps(host)} and '
    f'starts_with(http.request.uri.path, {json.dumps(path_prefix)}) and '
    f'starts_with(http.user_agent, {json.dumps(ua_prefix)})'
)
PY
}

build_rule_payload() {
  python3 - "$RULE_DESCRIPTION" "$1" "$RULE_REF" "$LOG_MATCHING" "$SKIP_PRODUCTS" "$SKIP_PHASES" "$SKIP_CURRENT_RULESET" <<'PY'
import json
import sys

description, expression, ref, logging_enabled, products_csv, phases_csv, skip_current_ruleset = sys.argv[1:8]
products = [p.strip() for p in products_csv.split(',') if p.strip()]
phases = [p.strip() for p in phases_csv.split(',') if p.strip()]
payload = {
    'action': 'skip',
    'description': description,
    'enabled': True,
    'expression': expression,
    'ref': ref,
    'logging': {'enabled': logging_enabled.lower() == 'true'},
}
action_parameters = {}
if skip_current_ruleset.lower() == 'true':
    action_parameters['ruleset'] = 'current'
if phases:
    action_parameters['phases'] = phases
if products:
    action_parameters['products'] = products
if not action_parameters:
    raise SystemExit('at least one skip target must be configured')
payload['action_parameters'] = action_parameters
print(json.dumps(payload, separators=(',', ':')))
PY
}

build_positioned_rule_payload() {
  python3 - "$1" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload['position'] = {'before': ''}
print(json.dumps(payload, separators=(',', ':')))
PY
}

build_entrypoint_payload() {
  python3 - "$ENTRYPOINT_NAME" "$ENTRYPOINT_DESCRIPTION" "$1" <<'PY'
import json
import sys
name, description, rule_payload = sys.argv[1:4]
payload = {
    'name': name,
    'description': description,
    'kind': 'zone',
    'phase': 'http_request_firewall_custom',
    'rules': [json.loads(rule_payload)],
}
print(json.dumps(payload, separators=(',', ':')))
PY
}

cf_api_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local response_file
  response_file="$(mktemp)"
  local status
  local curl_args=(
    -sS
    -X "$method"
    "$url"
    -H "Authorization: Bearer $API_TOKEN"
  )
  if [[ -n "$body" ]]; then
    curl_args+=(
      -H 'Content-Type: application/json'
      --data "$body"
    )
  fi
  if ! status="$(curl "${curl_args[@]}" -o "$response_file" -w '%{http_code}')"; then
    cat "$response_file" >&2 || true
    rm -f "$response_file"
    die "Cloudflare API request failed for $method $url"
  fi
  HTTP_STATUS="$status"
  RESPONSE_BODY="$(cat "$response_file")"
  rm -f "$response_file"
}

cf_assert_success() {
  local context="$1"
  [[ "$HTTP_STATUS" == 2* ]] || {
    printf '%s\n' "$RESPONSE_BODY" >&2
    die "$context failed with HTTP $HTTP_STATUS"
  }
  if [[ -z "$RESPONSE_BODY" ]]; then
    return 0
  fi
  RESPONSE_BODY="$RESPONSE_BODY" python3 - "$context" <<'PY'
import json
import os
import sys

context = sys.argv[1]
body = os.environ.get('RESPONSE_BODY', '')
if not body:
    raise SystemExit(0)
try:
    data = json.loads(body)
except json.JSONDecodeError:
    raise SystemExit(0)
if data.get('success', True):
    raise SystemExit(0)
messages = []
for item in data.get('errors', []):
    code = item.get('code')
    message = item.get('message')
    if code is not None:
        messages.append(f'[{code}] {message}')
    else:
        messages.append(str(item))
print(f'{context} reported success=false: ' + '; '.join(messages), file=sys.stderr)
raise SystemExit(1)
PY
}

extract_entrypoint_metadata() {
  RESPONSE_BODY="$RESPONSE_BODY" python3 - "$RULE_REF" "$RULE_DESCRIPTION" <<'PY'
import json
import os
import sys

rule_ref, description = sys.argv[1:3]
data = json.loads(os.environ['RESPONSE_BODY'])
result = data.get('result') or {}
rules = result.get('rules') or []
match = None
for rule in rules:
    if rule.get('ref') == rule_ref:
        match = rule
        break
if match is None:
    for rule in rules:
        if rule.get('description') == description:
            match = rule
            break
print(result.get('id', ''))
print(match.get('id', '') if match else '')
print(len(rules))
PY
}

extract_zone_id() {
  RESPONSE_BODY="$RESPONSE_BODY" python3 - <<'PY'
import json
import os

data = json.loads(os.environ['RESPONSE_BODY'])
result = data.get('result') or []
if not result:
    raise SystemExit(1)
print(result[0]['id'])
PY
}

resolve_zone_id() {
  if [[ -n "$ZONE_ID" ]]; then
    return 0
  fi
  [[ -n "$ZONE_NAME" ]] || die "set --zone-id or --zone-name"
  local encoded_zone_name
  encoded_zone_name="$(urlencode "$ZONE_NAME")"
  cf_api_request GET "$API_BASE/zones?name=$encoded_zone_name&status=active&per_page=1"
  cf_assert_success "resolve zone id"
  if ! ZONE_ID="$(extract_zone_id)"; then
    die "unable to resolve zone id for zone name: $ZONE_NAME"
  fi
}

print_plan() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  printf 'Mode: %s\n' "$MODE"
  printf 'Zone ID: %s\n' "$ZONE_ID"
  printf 'Host: %s\n' "$HOST"
  printf 'Path prefix: %s\n' "$PATH_PREFIX"
  printf 'User-Agent prefix: %s\n' "$UA_PREFIX"
  printf 'Request: %s %s\n' "$method" "$url"
  if [[ -n "$body" ]]; then
    printf 'Payload:\n%s\n' "$body"
  fi
}

main() {
  require_command curl
  require_command python3
  parse_args "$@"

  if [[ "$RULE_DESCRIPTION_EXPLICIT" != "true" ]]; then
    RULE_DESCRIPTION="Allow OpenAI Python SDK traffic for ${HOST}${PATH_PREFIX}"
  fi

  SKIP_PRODUCTS="$(trim_csv "$SKIP_PRODUCTS")"
  SKIP_PHASES="$(trim_csv "$SKIP_PHASES")"

  [[ -n "$API_TOKEN" ]] || die "set --api-token or CLOUDFLARE_API_TOKEN"
  resolve_zone_id

  local entrypoint_url="$API_BASE/zones/$ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint"
  cf_api_request GET "$entrypoint_url"

  local ruleset_id=""
  local rule_id=""
  local rule_count="0"

  if [[ "$HTTP_STATUS" == "404" ]]; then
    if [[ "$MODE" == "delete" ]]; then
      log "no custom-rules entrypoint ruleset found; nothing to delete"
      return 0
    fi
    local expression
    expression="$(build_expression)"
    local rule_payload
    rule_payload="$(build_rule_payload "$expression")"
    local create_payload
    create_payload="$(build_entrypoint_payload "$rule_payload")"
    if [[ "$DRY_RUN" == "true" ]]; then
      print_plan POST "$API_BASE/zones/$ZONE_ID/rulesets" "$create_payload"
      return 0
    fi
    cf_api_request POST "$API_BASE/zones/$ZONE_ID/rulesets" "$create_payload"
    cf_assert_success "create custom-rules entrypoint"
    log "created custom-rules entrypoint ruleset with skip rule ref=$RULE_REF"
    return 0
  fi

  cf_assert_success "fetch custom-rules entrypoint"
  mapfile -t entrypoint_meta < <(extract_entrypoint_metadata)
  ruleset_id="${entrypoint_meta[0]:-}"
  rule_id="${entrypoint_meta[1]:-}"
  rule_count="${entrypoint_meta[2]:-0}"

  if [[ "$MODE" == "delete" ]]; then
    if [[ -z "$rule_id" ]]; then
      log "no matching rule found in ruleset $ruleset_id; nothing to delete"
      return 0
    fi
    local delete_url="$API_BASE/zones/$ZONE_ID/rulesets/$ruleset_id/rules/$rule_id"
    if [[ "$DRY_RUN" == "true" ]]; then
      print_plan DELETE "$delete_url"
      return 0
    fi
    cf_api_request DELETE "$delete_url"
    cf_assert_success "delete rule"
    log "deleted rule ref=$RULE_REF from ruleset $ruleset_id"
    return 0
  fi

  local expression
  expression="$(build_expression)"
  local base_rule_payload
  base_rule_payload="$(build_rule_payload "$expression")"
  local positioned_rule_payload
  positioned_rule_payload="$(build_positioned_rule_payload "$base_rule_payload")"

  if [[ -n "$rule_id" ]]; then
    local update_url="$API_BASE/zones/$ZONE_ID/rulesets/$ruleset_id/rules/$rule_id"
    if [[ "$DRY_RUN" == "true" ]]; then
      print_plan PATCH "$update_url" "$positioned_rule_payload"
      return 0
    fi
    cf_api_request PATCH "$update_url" "$positioned_rule_payload"
    cf_assert_success "update rule"
    log "updated existing rule ref=$RULE_REF in ruleset $ruleset_id"
    return 0
  fi

  local create_url="$API_BASE/zones/$ZONE_ID/rulesets/$ruleset_id/rules"
  if [[ "$DRY_RUN" == "true" ]]; then
    print_plan POST "$create_url" "$positioned_rule_payload"
    return 0
  fi
  cf_api_request POST "$create_url" "$positioned_rule_payload"
  cf_assert_success "create rule"
  log "created rule ref=$RULE_REF in ruleset $ruleset_id (existing rules: $rule_count)"
}

main "$@"
