#!/usr/bin/env bash
# Status line for Claude Code: context window used and plan budget left.
#
# Usage: statusline.sh [minimal|full] [usage-api]
#   minimal (default)  model | ctx | 5h left | spend left
#   full               model | dir | ctx | 5h left | 7d left | spend left | cost
#   usage-api          also show the per-model weekly windows (Fable, Opus,
#                      Sonnet) that the status line payload does not carry
#
# Mode can also be set with CC_STATUSLINE_MODE, the API fetch with
# CC_STATUSLINE_USAGE_API=1. Arguments win over the variables. The fetch caches
# for CC_STATUSLINE_USAGE_TTL seconds (default 300), backs off for
# CC_STATUSLINE_USAGE_FAIL_TTL seconds (default 1800) after a failure, and stops
# fetching once the session has been quiet for CC_STATUSLINE_USAGE_IDLE seconds
# (default 900).
#
# Session cost in USD is shown only when the account reports no plan rate
# limits, since the dollar figure means nothing on a subscription. Force it with
# CC_STATUSLINE_COST=1, hide it with CC_STATUSLINE_COST=0.
#
# Optional extras: if ~/.claude/statusline-extra.sh exists it is run with the
# same JSON on stdin and its output appended.
set -u

MODE="${CC_STATUSLINE_MODE:-minimal}"
USAGE_API="${CC_STATUSLINE_USAGE_API:-0}"
for arg in "$@"; do
  case "$arg" in
    minimal|full) MODE="$arg" ;;
    usage-api) USAGE_API=1 ;;
  esac
done
COST="${CC_STATUSLINE_COST:-auto}"
IN=$(cat)

command -v jq >/dev/null || { printf 'statusline: jq not installed'; exit 0; }

# The model of the last main loop reply. Claude Code can switch models mid
# session, for example when a weekly window runs out, and the payload names the
# session model, so the transcript is what says who actually answered.
LAST_MODEL=""
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$IN")
if [ -z "$TRANSCRIPT" ]; then
  SESSION=$(jq -r '.session_id // empty' <<<"$IN")
  [ -n "$SESSION" ] && TRANSCRIPT=$(ls -t "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$SESSION".jsonl 2>/dev/null | head -1)
fi
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  LAST_MODEL=$(tail -c 262144 "$TRANSCRIPT" 2>/dev/null \
    | grep '"type":"assistant"' | grep -v '"isSidechain":true' \
    | grep -o '"model":"[^"]*"' | tail -1 | cut -d'"' -f4)
fi

# The Fable weekly window comes from the endpoint /usage reads, not from the
# status line payload. Request budget is kept small on purpose: one fetch per
# TTL per machine, a single fetch in flight at a time no matter how many
# sessions are open, no fetch at all while a failure is backing off, and the
# cached copy drawn right away so no redraw ever waits on the network.
EXTRA_WINDOWS='[]'
if [ "$USAGE_API" = "1" ]; then
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/statusline"
  CACHE="$CACHE_DIR/usage.json"
  LOCK="$CACHE_DIR/refresh.lock"
  BACKOFF="$CACHE_DIR/failed-at"
  CREDS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  TTL="${CC_STATUSLINE_USAGE_TTL:-300}"
  FAIL_TTL="${CC_STATUSLINE_USAGE_FAIL_TTL:-1800}"
  URL="${CC_STATUSLINE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
  IDLE="${CC_STATUSLINE_USAGE_IDLE:-900}"

  age() { echo "$(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))"; }

  # an idle session asks for nothing: no reply has landed in a while, so the
  # windows are not moving either
  busy=1
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    [ "$(( $(date +%s) - $(stat -c %Y "$TRANSCRIPT" 2>/dev/null || echo 0) ))" -gt "$IDLE" ] && busy=0
  fi

  if [ "$busy" = "1" ] && [ -f "$CREDS" ] && command -v curl >/dev/null; then
    mkdir -p "$CACHE_DIR"
    stale=1
    [ -f "$CACHE" ] && [ "$(age "$CACHE")" -le "$TTL" ] && stale=0
    # a failed fetch backs off, so a revoked token or a 429 is not retried on
    # every redraw
    [ -f "$BACKOFF" ] && [ "$(age "$BACKOFF")" -le "$FAIL_TTL" ] && stale=0
    # mkdir is the lock: one fetch in flight per machine, and a lock left
    # behind by a killed process expires
    [ -d "$LOCK" ] && [ "$(age "$LOCK")" -gt 60 ] && rmdir "$LOCK" 2>/dev/null

    if [ "$stale" = "1" ] && mkdir "$LOCK" 2>/dev/null; then
      (
        trap 'rmdir "$LOCK" 2>/dev/null' EXIT
        TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
        [ -n "$TOKEN" ] || exit 0
        if curl -sS --fail --max-time 5 --no-progress-meter \
             -H "Authorization: Bearer $TOKEN" \
             -H "Content-Type: application/json" \
             -H "anthropic-beta: oauth-2025-04-20" \
             "$URL" -o "$CACHE.tmp" \
           && jq -e . "$CACHE.tmp" >/dev/null 2>&1; then
          mv "$CACHE.tmp" "$CACHE"
          rm -f "$BACKOFF" "$CACHE.tmp"
        else
          rm -f "$CACHE.tmp"
          : > "$BACKOFF"
        fi
      ) >/dev/null 2>&1 &
      disown 2>/dev/null
    fi
  fi

  if [ -f "$CACHE" ]; then
    EXTRA_WINDOWS=$(jq -c '
      def iso: if . == null then null
               else (sub("\\.[0-9]+"; "") | sub("([+-][0-9]{2}:[0-9]{2})$"; "Z") | fromdateiso8601) end;
      [ ((.limits // [])[]
          | select(.kind == "weekly_scoped" and (.scope | type == "string"))
          | {name: .scope, used: .percent, resets_at: (.resets_at | iso)}),
        (if (.seven_day_overage_included | type) == "object" and .seven_day_overage_included.utilization != null
         then {name: "fable", used: .seven_day_overage_included.utilization,
               resets_at: (.seven_day_overage_included.resets_at | iso)}
         else empty end) ]' "$CACHE" 2>/dev/null) || EXTRA_WINDOWS='[]'
    [ -n "$EXTRA_WINDOWS" ] || EXTRA_WINDOWS='[]'
  fi
fi

printf '%s' "$(jq -r --arg mode "$MODE" --arg cost "$COST" --arg last "$LAST_MODEL" --argjson extra "$EXTRA_WINDOWS" '
  def c(n;s): "\u001b[38;5;" + (n|tostring) + "m" + s + "\u001b[0m";
  def dim(s): c(240; s);
  def k(t): if t >= 1000000 then ((t/1000000*10|floor)/10|tostring) + "M"
            elif t >= 1000 then ((t/1000*10|floor)/10|tostring) + "k"
            else (t|tostring) end;
  def pct(p): (p|floor|tostring) + "%";
  # green below 70% used, orange to 90%, red above
  def hue(p): if p >= 90 then 196 elif p >= 70 then 214 else 108 end;
  def clock($s): if $s >= 172800 then (($s/86400)|floor|tostring) + "d"
                 elif $s >= 3600 then (($s/3600)|floor|tostring) + "h" + ((($s%3600)/60)|floor|tostring) + "m"
                 else ((($s%3600)/60)|floor|tostring) + "m" end;
  def resets($at): if $at == null then ""
    else ($at - now) as $s | if $s <= 0 then "" else " " + dim("(" + clock($s) + ")") end end;
  def budget(txt; used; at): dim(txt + " ") + c(hue(used); pct(100 - used) + " left") + resets(at);
  # "Opus 5 (1M context)" -> "Opus 5", the window is already in the ctx field
  def plain($n): $n | sub(" *\\([^)]*\\)$"; "");
  def pretty($id):
    ($id | ascii_downcase | sub("[\\[(].*$"; "") | sub("-v[0-9]+:[0-9]+$"; "")) as $l
    | (["opus", "sonnet", "haiku", "fable", "gemini"] | map(. as $f | select($l | contains($f))) | first) as $fam
    | if $fam == null then $id
      else ([$l | scan("[0-9]+")] | map(select(length <= 2))[0:2] | join(".")) as $ver
        | ($fam[0:1] | ascii_upcase) + $fam[1:] + (if $ver == "" then "" else " " + $ver end)
      end;
  # the session model, unless the transcript shows another family answering
  def model: plain(.model.display_name) as $n
    | if $last == "" then $n
      else pretty($last) as $p
        | if ($p | ascii_downcase | split(" ")[0]) == ($n | ascii_downcase | split(" ")[0])
          then $n else $p end
      end;
  def usd(v): (v * 100 | round) as $c
    | "$" + (($c / 100) | floor | tostring) + "."
          + (($c % 100) | tostring | if length == 1 then "0" + . else . end);

  ($mode == "full") as $full |
  # on a subscription the plan windows are the real budget, the USD figure is not
  (if $cost == "1" then true elif $cost == "0" then false
   else (.rate_limits.five_hour == null and .quota == null) end) as $showcost |

  [ c(75; model),

    (if $full then c(244; (.workspace.current_dir | sub("^" + env.HOME; "~"))) else empty end),

    (.context_window as $w
      | dim("ctx ") + c(hue($w.used_percentage);
          k($w.total_input_tokens) + "/" + k($w.context_window_size) + " " + pct($w.used_percentage))),

    (if .rate_limits.five_hour
     then budget("5h"; .rate_limits.five_hour.used_percentage; .rate_limits.five_hour.resets_at)
     elif .quota."gemini-5h" and (model | ascii_downcase | contains("gemini"))
     then budget("5h"; ((1 - .quota."gemini-5h".remaining_fraction) * 100); (now + .quota."gemini-5h".reset_in_seconds))
     elif .quota."3p-5h"
     then budget("5h"; ((1 - .quota."3p-5h".remaining_fraction) * 100); (now + .quota."3p-5h".reset_in_seconds))
     else empty end),

    (if $full and .rate_limits.seven_day
     then budget("7d"; .rate_limits.seven_day.used_percentage; .rate_limits.seven_day.resets_at)
     elif $full and .quota."gemini-weekly" and (model | ascii_downcase | contains("gemini"))
     then budget("7d"; ((1 - .quota."gemini-weekly".remaining_fraction) * 100); (now + .quota."gemini-weekly".reset_in_seconds))
     elif $full and .quota."3p-weekly"
     then budget("7d"; ((1 - .quota."3p-weekly".remaining_fraction) * 100); (now + .quota."3p-weekly".reset_in_seconds))
     else empty end),

    ($extra[] | budget(.name; .used; .resets_at)),

    (if .rate_limits.spend_limit
     then budget("spend"; .rate_limits.spend_limit.used_percentage; .rate_limits.spend_limit.resets_at)
     else empty end),

    (if $showcost then dim(usd(.cost.total_cost_usd // 0)) else empty end)
  ] | join(c(238; " | "))
' <<<"$IN")"

EXTRA="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-extra.sh"
if [ -f "$EXTRA" ]; then
  OUT=$(bash "$EXTRA" <<<"$IN" 2>/dev/null)
  [ -z "$OUT" ] || printf ' %s' "$OUT"
fi
