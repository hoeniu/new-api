#!/usr/bin/env bash
# 一键联调三个用量聚合接口：
#   1. GET /api/usage/by_key          — 指定 Key 时间窗内用量与次数
#   2. GET /api/usage/trend/daily     — 日期范围内每日用量与次数
#   3. GET /api/usage/by_model        — 时间窗内按模型统计
#
# 依赖: bash、curl、python3
#
# 必填:
#   TEST_ACCESS_TOKEN    — 控制台 Web access_token（Bearer）
#
# 可选:
#   BASE                 — 默认 http://127.0.0.1:3000
#   NEW_API_USER         — 默认自动从 /api/user/self 解析 id
#   TOKEN_NAME           — 默认自动取 /api/token/ 列表第一项 name
#   START_DATE           — 默认近 RANGE_DAYS 天起始日 YYYY-MM-DD
#   END_DATE             — 默认今天 YYYY-MM-DD
#   RANGE_DAYS           — 未设 START_DATE/END_DATE 时，默认 14
#   TIMEZONE_OFFSET      — 切日偏移秒，默认 28800（东八区）
#   SCOPE                — key（默认，daily/by_model 也带 token_name）| tenant（租户级）
#
# 示例:
#   export BASE='http://10.199.117.168:3000'
#   export TEST_ACCESS_TOKEN='你的access_token'
#   bash scripts/usage-three-api-smoke.sh
set -uo pipefail

die() { echo "错误: $*" >&2; exit 1; }

BASE="${BASE:-http://127.0.0.1:3000}"
while [[ "${BASE}" == */ ]]; do BASE="${BASE%/}"; done

SCOPE="${SCOPE:-key}"
RANGE_DAYS="${RANGE_DAYS:-14}"
TIMEZONE_OFFSET="${TIMEZONE_OFFSET:-28800}"
USAGE_SLEEP_SEC="${USAGE_SLEEP_SEC:-0.5}"

[[ -n "${TEST_ACCESS_TOKEN:-}" ]] || die "请设置 TEST_ACCESS_TOKEN（控制台 Web access_token）"

print_json_resp_body() {
  local tmp="$1" code="${2:-}"
  python3 -c "
import json, sys, pathlib
path, code = sys.argv[1], sys.argv[2]
raw = pathlib.Path(path).read_text(encoding='utf-8', errors='replace').strip()
if not raw:
    if code in ('401', '403'):
        print('(响应体为空：鉴权失败，请检查 TEST_ACCESS_TOKEN / New-Api-User)')
    elif code == '429':
        print('(响应体为空：HTTP 429 限流，稍后再试)')
    else:
        print('(响应体为空)')
    sys.exit(0)
try:
    print(json.dumps(json.loads(raw), ensure_ascii=False, indent=2))
except json.JSONDecodeError as e:
    print('非 JSON:', e, file=sys.stderr)
    print(raw[:2000])
" "$tmp" "$code"
}

curl_json() {
  local label="$1"
  shift
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w "%{http_code}" "$@")" || {
    echo "curl 失败: $label" >&2
    rm -f "$tmp"
    return 1
  }
  echo "======== ${label} ========"
  echo "HTTP ${code}"
  print_json_resp_body "$tmp" "$code"
  rm -f "$tmp"
  echo ""
  sleep "${USAGE_SLEEP_SEC}" 2>/dev/null || true
}

resolve_dates() {
  python3 -c "
import os, datetime
off = int(os.environ.get('TIMEZONE_OFFSET', '28800'))
tz = datetime.timezone(datetime.timedelta(seconds=off))
today = datetime.datetime.now(tz).date()
start = os.environ.get('START_DATE', '').strip()
end = os.environ.get('END_DATE', '').strip()
if not start or not end:
    days = int(os.environ.get('RANGE_DAYS', '14'))
    start_d = today - datetime.timedelta(days=max(days - 1, 0))
    end_d = today
else:
    start_d = datetime.date.fromisoformat(start)
    end_d = datetime.date.fromisoformat(end)
print(start_d.isoformat())
print(end_d.isoformat())
"
}

# 先带占位 User 调 self，解析真实 id
TMP_SELF="$(mktemp)"
CODE_SELF="$(curl -sS -o "$TMP_SELF" -w "%{http_code}" \
  -H "Authorization: Bearer ${TEST_ACCESS_TOKEN}" \
  -H "New-Api-User: ${NEW_API_USER:-1}" \
  "${BASE}/api/user/self")" || CODE_SELF="000"

RESOLVED_USER="$(python3 -c "
import json, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace').strip()
try:
    d = json.loads(raw)
    uid = (d.get('data') or {}).get('id')
    print(uid if uid is not None else '', end='')
except Exception:
    pass
" "$TMP_SELF")"

rm -f "$TMP_SELF"

[[ -n "$RESOLVED_USER" ]] || die "/api/user/self 失败 (HTTP ${CODE_SELF})，请检查 BASE 与 TEST_ACCESS_TOKEN"
NEW_API_USER="${NEW_API_USER:-$RESOLVED_USER}"

AUTH=( -H "Authorization: Bearer ${TEST_ACCESS_TOKEN}" -H "New-Api-User: ${NEW_API_USER}" )

mapfile -t DATE_PAIR < <(resolve_dates)
START_DATE="${DATE_PAIR[0]}"
END_DATE="${DATE_PAIR[1]}"

echo ">>> BASE=${BASE}"
echo ">>> NEW_API_USER=${NEW_API_USER}"
echo ">>> 日期范围: ${START_DATE} ~ ${END_DATE} (timezone_offset=${TIMEZONE_OFFSET})"
echo ">>> SCOPE=${SCOPE}"
echo ""

curl_json "GET /api/user/self" "${AUTH[@]}" "${BASE}/api/user/self"

if [[ -z "${TOKEN_NAME:-}" ]]; then
  TMP_TOK="$(mktemp)"
  CODE_TOK="$(curl -sS -o "$TMP_TOK" -w "%{http_code}" "${AUTH[@]}" "${BASE}/api/token/?p=1&size=1")" || CODE_TOK="000"
  TOKEN_NAME="$(python3 -c "
import json, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace').strip()
try:
    d = json.loads(raw)
    items = (d.get('data') or {}).get('items') or []
    if items:
        print(items[0].get('name') or '', end='')
except Exception:
    pass
" "$TMP_TOK")"
  rm -f "$TMP_TOK"
  TOKEN_NAME="${TOKEN_NAME//[[:space:]]/}"
  if [[ -n "$TOKEN_NAME" ]]; then
    echo ">>> 自动选用 TOKEN_NAME=${TOKEN_NAME} (HTTP ${CODE_TOK})"
  else
    echo ">>> 未能从 /api/token/ 推断 TOKEN_NAME (HTTP ${CODE_TOK})"
  fi
  echo ""
fi

[[ -n "${TOKEN_NAME:-}" ]] || die "by_key 需要 TOKEN_NAME，请 export TOKEN_NAME=令牌名称"

# 1. 按 Key 统计
curl_json "1/3 GET /api/usage/by_key (token_name=${TOKEN_NAME})" \
  -G "${BASE}/api/usage/by_key" \
  "${AUTH[@]}" \
  --data-urlencode "token_name=${TOKEN_NAME}" \
  --data-urlencode "start_date=${START_DATE}" \
  --data-urlencode "end_date=${END_DATE}" \
  --data-urlencode "timezone_offset=${TIMEZONE_OFFSET}"

# 2. 按日趋势
DAILY_LABEL="2/3 GET /api/usage/trend/daily (${START_DATE}~${END_DATE})"
DAILY_ARGS=(
  -G "${BASE}/api/usage/trend/daily"
  "${AUTH[@]}"
  --data-urlencode "start_date=${START_DATE}"
  --data-urlencode "end_date=${END_DATE}"
  --data-urlencode "timezone_offset=${TIMEZONE_OFFSET}"
)
if [[ "$SCOPE" == "key" ]]; then
  DAILY_LABEL+=" [token_name=${TOKEN_NAME}]"
  DAILY_ARGS+=( --data-urlencode "token_name=${TOKEN_NAME}" )
fi
curl_json "$DAILY_LABEL" "${DAILY_ARGS[@]}"

# 3. 按模型统计
MODEL_LABEL="3/3 GET /api/usage/by_model (${START_DATE}~${END_DATE})"
MODEL_ARGS=(
  -G "${BASE}/api/usage/by_model"
  "${AUTH[@]}"
  --data-urlencode "start_date=${START_DATE}"
  --data-urlencode "end_date=${END_DATE}"
  --data-urlencode "timezone_offset=${TIMEZONE_OFFSET}"
)
if [[ "$SCOPE" == "key" ]]; then
  MODEL_LABEL+=" [token_name=${TOKEN_NAME}]"
  MODEL_ARGS+=( --data-urlencode "token_name=${TOKEN_NAME}" )
fi
curl_json "$MODEL_LABEL" "${MODEL_ARGS[@]}"

echo "完成。SCOPE=tenant 可测租户级 daily/by_model（quota_data）；勿将 TEST_ACCESS_TOKEN 提交到 Git。"
