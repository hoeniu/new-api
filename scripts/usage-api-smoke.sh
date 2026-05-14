#!/usr/bin/env bash
# 联调站内用量相关 HTTP 接口（不读 logs 的 /api/usage/* + 仅 sk 的 /api/usage/token/）。
# 依赖: bash、curl、python3
# 文档: scripts/usage-prd-smoke.md
#
# 必填（至少其一）:
#   TEST_SK              — 中继 API Key（sk-...），测 GET /api/usage/token/
#   TEST_ACCESS_TOKEN    — 用户 access_token，测 GET /api/user/self 与 GET /api/usage/*
# 常用:
#   BASE                 — 默认 http://127.0.0.1:3000
#   NEW_API_USER         — 与 Bearer 用户一致，默认 1
#   RANGE_DAYS           — 时间窗天数，默认 14
#   TOKEN_NAME           — 测 /api/usage/by_key 时传入；若未设且同时提供 TEST_SK，则从 /api/usage/token/ 的 data.name 推断
#   COMPARE_PREV         — 设为 1 时 overview 带 compare_prev=1
#   RANK_BY              — keys/ranking 的 rank_by，默认 used_quota；可 accessed_in_range
#   USAGE_SLEEP_SEC      — 两次命中 /api/usage/* 的请求之间的间隔秒数，默认 1.5（减轻 CriticalRateLimit 429）
#   USAGE_429_RETRY_SEC  — 遇 HTTP 429 后重试前等待秒数，默认 12
#   USAGE_START_DELAY_SEC— 脚本开始前的初始等待，默认 0
#
# 示例:
#   export TEST_SK='sk-xxxxx'
#   export TEST_ACCESS_TOKEN='你的access_token'
#   export NEW_API_USER=1
#   bash scripts/usage-api-smoke.sh
set -uo pipefail

die() { echo "错误: $*" >&2; exit 1; }

BASE="${BASE:-http://127.0.0.1:3000}"
while [[ "${BASE}" == */ ]]; do BASE="${BASE%/}"; done

NEW_API_USER="${NEW_API_USER:-1}"
RANGE_DAYS="${RANGE_DAYS:-14}"
COMPARE_PREV="${COMPARE_PREV:-0}"
RANK_BY="${RANK_BY:-used_quota}"
USAGE_SLEEP_SEC="${USAGE_SLEEP_SEC:-1.5}"
USAGE_429_RETRY_SEC="${USAGE_429_RETRY_SEC:-12}"
USAGE_START_DELAY_SEC="${USAGE_START_DELAY_SEC:-0}"

[[ -n "${TEST_SK:-}" || -n "${TEST_ACCESS_TOKEN:-}" ]] || die "请至少设置 TEST_SK 或 TEST_ACCESS_TOKEN"

usage_pause() {
  sleep "${USAGE_SLEEP_SEC}" 2>/dev/null || sleep 1
}

# 将响应体按 HTTP 码友好打印（空体 + 429 时提示限流）
print_json_resp_body() {
  local tmp="$1" code="${2:-}"
  python3 -c "
import json, sys, pathlib
path, code = sys.argv[1], sys.argv[2]
raw = pathlib.Path(path).read_text(encoding='utf-8', errors='replace').strip()
if not raw:
    if code == '429':
        print('(响应体为空：HTTP 429 — /api/usage 路由组可能命中 CriticalRateLimit；增大 USAGE_SLEEP_SEC / USAGE_429_RETRY_SEC，或稍后再试)')
    elif code == '401' or code == '403':
        print('(响应体为空：鉴权失败或无权访问，请检查 TEST_SK / TEST_ACCESS_TOKEN / New-Api-User)')
    else:
        print('(响应体为空：请检查 BASE 是否可达、路径是否正确、是否被代理截断)')
    sys.exit(0)
try:
    print(json.dumps(json.loads(raw), ensure_ascii=False, indent=2))
except json.JSONDecodeError as e:
    print('非 JSON 或解析失败:', e, file=sys.stderr)
    print('---- 原始响应前 2000 字符 ----')
    print(raw[:2000])
" "$tmp" "$code"
}

# 将响应落盘再解析；遇 429 等待后重试一次。
curl_json() {
  local label="$1"
  shift
  local tmp code attempt=1
  tmp="$(mktemp)"
  while true; do
    code="$(curl -sS -o "$tmp" -w "%{http_code}" "$@")" || {
      echo "curl 请求失败: $label" >&2
      rm -f "$tmp"
      return 1
    }
    if [[ "$code" != "429" ]] || [[ "$attempt" -ge 2 ]]; then
      break
    fi
    echo ">>> ${label}: HTTP 429，${USAGE_429_RETRY_SEC}s 后重试一次..." >&2
    sleep "${USAGE_429_RETRY_SEC}"
    attempt=$((attempt + 1))
  done
  echo "======== ${label} ========"
  echo "HTTP ${code}"
  print_json_resp_body "$tmp" "$code"
  rm -f "$tmp"
  echo ""
}

# 从文件解析 JSON 中的 data.name（失败返回空）
json_token_name() {
  python3 -c "
import json, pathlib, sys
try:
    raw = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace').strip()
    if not raw:
        print('', end='')
        sys.exit(0)
    d = json.loads(raw)
    name = (d.get('data') or {}).get('name') or ''
    print(name, end='')
except Exception:
    print('', end='')
" "$1"
}

if python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if v>0 else 1)" "${USAGE_START_DELAY_SEC:-0}" 2>/dev/null; then
  echo ">>> 初始等待 ${USAGE_START_DELAY_SEC}s（USAGE_START_DELAY_SEC）..." >&2
  sleep "${USAGE_START_DELAY_SEC}" 2>/dev/null || true
fi

NOW="$(date +%s)"
START_TS=$((NOW - RANGE_DAYS * 86400))
END_TS="$NOW"
QS="start_timestamp=${START_TS}&end_timestamp=${END_TS}"

if [[ -n "${TEST_SK:-}" ]]; then
  tmp="$(mktemp)"
  attempt=1
  code=""
  while true; do
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -H "Authorization: Bearer ${TEST_SK}" "${BASE}/api/usage/token/")" || code="000"
    if [[ "$code" != "429" ]] || [[ "$attempt" -ge 2 ]]; then
      break
    fi
    echo ">>> GET /api/usage/token/: HTTP 429，${USAGE_429_RETRY_SEC}s 后重试..." >&2
    sleep "${USAGE_429_RETRY_SEC}"
    attempt=$((attempt + 1))
  done
  echo "======== GET /api/usage/token/ (TEST_SK) ========"
  echo "HTTP ${code}"
  print_json_resp_body "$tmp" "$code"

  if [[ -z "${TOKEN_NAME:-}" && "$code" == "200" ]]; then
    TOKEN_NAME="$(json_token_name "$tmp")"
    TOKEN_NAME="${TOKEN_NAME//[[:space:]]/}"
  fi
  rm -f "$tmp"
  echo ""
  usage_pause
else
  echo ">>> 未设置 TEST_SK，跳过 /api/usage/token/"
  echo ""
fi

if [[ -z "${TEST_ACCESS_TOKEN:-}" ]]; then
  echo ">>> 未设置 TEST_ACCESS_TOKEN，跳过 /api/user/self 与 /api/usage/*（需 UserAuth）"
  echo ""
  echo "======== GET /api/status ========"
  curl -sS "${BASE}/api/status" | python3 -c "import json,sys; d=json.load(sys.stdin); print('success:', d.get('success'))" 2>/dev/null || echo "status 请求失败"
  echo ""
  echo "完成。勿将 TEST_SK / TEST_ACCESS_TOKEN 提交到 Git。"
  exit 0
fi

AUTH=( -H "Authorization: Bearer ${TEST_ACCESS_TOKEN}" -H "New-Api-User: ${NEW_API_USER}" )

curl_json "GET /api/user/self" "${AUTH[@]}" "${BASE}/api/user/self"

usage_pause
OVER_URL="${BASE}/api/usage/overview?${QS}"
[[ "${COMPARE_PREV}" == "1" ]] && OVER_URL+="&compare_prev=1"
curl_json "GET /api/usage/overview" "${AUTH[@]}" "${OVER_URL}"

usage_pause
curl_json "GET /api/usage/trend/daily" "${AUTH[@]}" "${BASE}/api/usage/trend/daily?${QS}&timezone_offset=${TIMEZONE_OFFSET:-28800}"

usage_pause
curl_json "GET /api/usage/by_model" "${AUTH[@]}" "${BASE}/api/usage/by_model?${QS}"

usage_pause
RANK_ENC="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${RANK_BY}")"
curl_json "GET /api/usage/keys/ranking" "${AUTH[@]}" "${BASE}/api/usage/keys/ranking?${QS}&p=1&page_size=20&rank_by=${RANK_ENC}"

if [[ -n "${TOKEN_NAME:-}" ]]; then
  usage_pause
  ENC="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${TOKEN_NAME}")"
  curl_json "GET /api/usage/by_key (token_name=${TOKEN_NAME})" "${AUTH[@]}" "${BASE}/api/usage/by_key?token_name=${ENC}&${QS}"
else
  echo ">>> 未得到 TOKEN_NAME，跳过 /api/usage/by_key（可 export TOKEN_NAME=令牌名称，或确保 TEST_SK 有效且 /api/usage/token/ 返回 200 以自动推断）"
  echo ""
fi

echo "======== GET /api/status ========"
curl -sS "${BASE}/api/status" | python3 -c "import json,sys; d=json.load(sys.stdin); print('success:', d.get('success'))" 2>/dev/null || echo "status 非 JSON 或请求失败"

echo ""
echo "完成。勿将 TEST_SK / TEST_ACCESS_TOKEN 提交到 Git。"
