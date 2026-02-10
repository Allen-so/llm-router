# Bash library: HTTP POST JSON with retry/backoff + diagnosis
# Intended to be sourced by scripts/ask.sh (do NOT run as a standalone command).

# ---- Defaults (env overridable) ----
_http_retry_defaults() {
  : "${ASK_RETRY_MAX:=3}"                 # retries count; total attempts = 1 + ASK_RETRY_MAX
  : "${ASK_RETRY_BASE_SLEEP:=0.6}"        # seconds
  : "${ASK_RETRY_MAX_SLEEP:=6}"           # seconds
  : "${ASK_RETRY_JITTER:=0.2}"            # seconds
  : "${ASK_CURL_TIMEOUT:=60}"             # curl --max-time
  : "${ASK_CONNECT_TIMEOUT:=5}"           # curl --connect-timeout
  : "${ASK_RETRY_ON_200_EMPTY:=1}"        # retry if HTTP 200 but response looks empty/invalid
  : "${ASK_DEBUG:=0}"                     # 1 => stderr debug logs
}

# ---- Outputs (globals) ----
# ASK_LAST_HTTP, ASK_LAST_CURL_RC, ASK_LAST_TIME_MS, ASK_RETRIES, ASK_DIAG

_http_dbg() { [[ "${ASK_DEBUG:-0}" == "1" ]] && echo "[ask][retry] $*" >&2 || true; }

_http_is_retryable_http() {
  local code="${1:-}"
  [[ "$code" == "408" || "$code" == "429" ]] && return 0
  [[ "$code" =~ ^5[0-9][0-9]$ ]] && return 0
  return 1
}

_http_is_retryable_curl_rc() {
  local rc="${1:-}"
  case "$rc" in
    6|7|18|28|35|52|56) return 0 ;; # resolve/connect/partial/timeout/ssl/empty/recvfail
    *) return 1 ;;
  esac
}

_http_parse_retry_after_seconds() {
  local hdr_file="$1"
  local ra=""
  ra="$(grep -i '^Retry-After:' "$hdr_file" 2>/dev/null | tail -n 1 | awk -F: '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')"
  [[ "$ra" =~ ^[0-9]+$ ]] && echo "$ra" || echo ""
}

_http_calc_backoff_seconds() {
  local attempt="$1"      # 1-based attempt index
  local retry_after="$2"  # numeric seconds or empty

  if [[ -n "$retry_after" ]]; then
    echo "$retry_after"
    return
  fi

  local pow=$((attempt-1))
  local raw clamped jitter
  raw="$(awk -v b="$ASK_RETRY_BASE_SLEEP" -v p="$pow" 'BEGIN{printf "%.3f", b*(2^p)}')"
  clamped="$(awk -v x="$raw" -v m="$ASK_RETRY_MAX_SLEEP" 'BEGIN{if(x>m)x=m; printf "%.3f", x}')"
  jitter="$(awk -v j="$ASK_RETRY_JITTER" -v r="$RANDOM" 'BEGIN{printf "%.3f", (r/32767)*j}')"
  awk -v a="$clamped" -v j="$jitter" 'BEGIN{printf "%.3f", a+j}'
}

_http_looks_empty_or_bad_json() {
  local f="$1"
  [[ ! -s "$f" ]] && return 0

  # If it's an error payload, don't treat as empty
  if grep -q '"error"' "$f" 2>/dev/null; then
    return 1
  fi

  # OpenAI-compatible chat completion should contain "choices"
  if grep -q '"choices"' "$f" 2>/dev/null; then
    return 1
  fi

  # Very small payload is suspicious
  local sz
  sz="$(wc -c <"$f" | tr -d ' ')"
  [[ "$sz" -lt 80 ]] && return 0

  return 0
}

_http_diagnose_failure() {
  local http="${1:-}" curl_rc="${2:-}" err_snip="${3:-}"
  local msg=""

  if [[ "${curl_rc:-}" != "0" && -n "${curl_rc:-}" ]]; then
    case "$curl_rc" in
      7) msg="Router not reachable (curl rc=7). Check: docker compose ps / port 127.0.0.1:4000 / wait_ready." ;;
      28) msg="Request timeout (curl rc=28). Try increasing ASK_CURL_TIMEOUT; check upstream latency." ;;
      6) msg="DNS/resolve failure (curl rc=6). If using a gateway (e.g., elbnt.ai), check DNS/network." ;;
      52) msg="Empty reply (curl rc=52). Often transient; retry or inspect router logs." ;;
      56) msg="Recv failure (curl rc=56). Often transient reset; retry or inspect router logs." ;;
      *) msg="Network/client error (curl rc=$curl_rc). Check router/network; see stderr." ;;
    esac
  else
    case "$http" in
      401|403) msg="Auth failed (HTTP $http). Check Bearer keys (LITELLM_MASTER_KEY / provider keys)." ;;
      404) msg="Endpoint not found (HTTP 404). Check BASE_URL ends with /v1 and path is /chat/completions." ;;
      408) msg="Upstream timeout (HTTP 408). Retry or check provider status." ;;
      429) msg="Rate limited (HTTP 429). Reduce frequency/concurrency; Retry-After respected if provided." ;;
      5??) msg="Upstream/provider/server error (HTTP $http). Retry later or switch model/mode." ;;
      200) msg="HTTP 200 but response looks empty/invalid. Likely transient proxy/router glitch; retry or inspect router logs." ;;
      *) msg="Request failed (HTTP ${http:-NA}). Check response body for details." ;;
    esac
  fi

  [[ -n "$err_snip" ]] && msg="$msg | stderr: ${err_snip}"
  echo "$msg"
}

# Public API:
# http_post_json_retry URL PAYLOAD_FILE RESP_OUT [curl args...]
# - curl args should include headers like: -H "Content-Type: application/json" -H "Authorization: Bearer xxx"
http_post_json_retry() {
  _http_retry_defaults

  local url="$1"
  local payload_file="$2"
  local resp_out="$3"
  shift 3
  local -a extra_args=( "$@" )

  # globals
  ASK_LAST_HTTP=""
  ASK_LAST_CURL_RC=""
  ASK_LAST_TIME_MS=""
  ASK_RETRIES=0
  ASK_DIAG=""

  local attempt=1
  local max_attempts=$((ASK_RETRY_MAX + 1))

  while (( attempt <= max_attempts )); do
    local hdr_tmp err_tmp resp_tmp meta curl_rc http_code time_total time_ms err_snip retry_after delay

    hdr_tmp="$(mktemp)"
    err_tmp="$(mktemp)"
    resp_tmp="$(mktemp)"

    # Run curl
    set +e
    meta="$(
      curl --silent --show-error \
        --connect-timeout "$ASK_CONNECT_TIMEOUT" \
        --max-time "$ASK_CURL_TIMEOUT" \
        -D "$hdr_tmp" \
        -o "$resp_tmp" \
        -w "HTTP=%{http_code} TIME=%{time_total}" \
        "${extra_args[@]}" \
        -X POST "$url" \
        --data-binary "@$payload_file" \
        2>"$err_tmp"
    )"
    curl_rc=$?
    set -e

    http_code="$(echo "$meta" | sed -n 's/.*HTTP=\([0-9][0-9][0-9]\).*/\1/p')"
    time_total="$(echo "$meta" | sed -n 's/.*TIME=\([0-9.]\+\).*/\1/p')"
    time_ms="$(awk -v t="${time_total:-0}" 'BEGIN{printf "%d", t*1000}')"

    ASK_LAST_HTTP="${http_code:-}"
    ASK_LAST_CURL_RC="$curl_rc"
    ASK_LAST_TIME_MS="$time_ms"

    # Keep response (even on failure, might contain useful error json)
    mv "$resp_tmp" "$resp_out" 2>/dev/null || true

    # stderr snippet (single line)
    err_snip="$(tr '\n' ' ' <"$err_tmp" | sed 's/[[:space:]]\+/ /g' | cut -c1-180)"

    # Success
    if [[ "$curl_rc" == "0" && "${http_code:-}" =~ ^2[0-9][0-9]$ ]]; then
      if [[ "$http_code" == "200" && "$ASK_RETRY_ON_200_EMPTY" == "1" ]] && _http_looks_empty_or_bad_json "$resp_out"; then
        _http_dbg "attempt=$attempt http=200 but suspicious/empty response -> retry"
      else
        ASK_RETRIES=$((attempt-1))
        ASK_DIAG=""
        rm -f "$err_tmp" "$hdr_tmp" 2>/dev/null || true
        return 0
      fi
    fi

    # Retry decision
    local retryable=1
    if _http_is_retryable_curl_rc "$curl_rc"; then
      retryable=0
    elif [[ -n "${http_code:-}" ]] && _http_is_retryable_http "$http_code"; then
      retryable=0
    elif [[ "${http_code:-}" == "200" && "$ASK_RETRY_ON_200_EMPTY" == "1" ]] && _http_looks_empty_or_bad_json "$resp_out"; then
      retryable=0
    fi

    if (( attempt >= max_attempts )) || (( retryable != 0 )); then
      ASK_RETRIES=$((attempt-1))
      ASK_DIAG="$(_http_diagnose_failure "${http_code:-}" "$curl_rc" "$err_snip")"
      rm -f "$err_tmp" "$hdr_tmp" 2>/dev/null || true
      return 1
    fi

    retry_after="$(_http_parse_retry_after_seconds "$hdr_tmp")"
    delay="$(_http_calc_backoff_seconds "$attempt" "$retry_after")"
    _http_dbg "retrying: attempt=$attempt/$max_attempts http=${http_code:-NA} curl_rc=$curl_rc sleep=${delay}s stderr='${err_snip}'"

    rm -f "$err_tmp" "$hdr_tmp" 2>/dev/null || true
    sleep "$delay"
    attempt=$((attempt+1))
  done

  ASK_DIAG="$(_http_diagnose_failure "${ASK_LAST_HTTP:-}" "${ASK_LAST_CURL_RC:-}" "")"
  return 1
}
