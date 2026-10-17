#!/usr/bin/env bash
# Requires Bash 4+, GNU date, curl, jq, sqlite3, flock and IANA tzdata.
set -Eeuo pipefail
umask 077

die() { printf 'jms-monitor: %s\n' "$*" >&2; exit 1; }
(($# == 0)) || die "Usage: $0 (reads config from the script directory)"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$script_dir"
config="$script_dir/config"
[[ -r $config ]] || die "Cannot read config: $config"
# Config is trusted shell code.
# shellcheck disable=SC1090
source "$config"
SERVICE_ID=${SERVICE_ID:-}
API_UUID=${API_UUID:-}
PERCENT_THRESHOLDS=${PERCENT_THRESHOLDS:-'25 50 65 80 90 95'}
WINDOW_SECONDS=${WINDOW_SECONDS:-900}
WINDOW_LIMIT_BYTES=${WINDOW_LIMIT_BYTES:-3000000000}
WINDOW_TOLERANCE_SECONDS=120
COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-1800}
RETENTION_SECONDS=604800
NOTIFY_BASE_URL=${NOTIFY_BASE_URL:-}
NOTIFY_TOKEN=${NOTIFY_TOKEN:-}
NOTIFY_USER_ID=${NOTIFY_USER_ID:-}
[[ $SERVICE_ID =~ ^[1-9][0-9]{0,14}$ ]] || die 'SERVICE_ID must be a positive integer (at most 15 digits)'
[[ $API_UUID =~ ^[a-zA-Z0-9-]+$ ]] || die 'API_UUID must contain only letters, digits and hyphens'
for name in WINDOW_SECONDS WINDOW_LIMIT_BYTES COOLDOWN_SECONDS; do
  value=${!name}
  [[ $value =~ ^[1-9][0-9]{0,14}$ ]] || die "$name must be a positive decimal integer (at most 15 digits)"
done
(( RETENTION_SECONDS > WINDOW_SECONDS + WINDOW_TOLERANCE_SECONDS )) || die 'Retention must exceed window plus tolerance'
(( WINDOW_TOLERANCE_SECONDS < WINDOW_SECONDS )) || die 'Tolerance must be smaller than window'
read -r -a thresholds <<< "$PERCENT_THRESHOLDS"
((${#thresholds[@]})) || die 'No percentage thresholds configured'
for threshold in "${thresholds[@]}"; do
  [[ $threshold =~ ^([1-9]|[1-9][0-9]|100)$ ]] || die 'Thresholds must be integers from 1 to 100'
done
for dep in curl jq sqlite3 flock date; do command -v "$dep" >/dev/null || die "Missing dependency: $dep"; done
[[ -f /usr/share/zoneinfo/America/Los_Angeles ]] || die 'Install IANA tzdata'
[[ $NOTIFY_BASE_URL == http://* || $NOTIFY_BASE_URL == https://* ]] || die 'Set NOTIFY_BASE_URL to an HTTP(S) base URL'
[[ -n $NOTIFY_TOKEN && $NOTIFY_TOKEN != *$'\n'* && $NOTIFY_TOKEN != *$'\r'* ]] || die 'Set NOTIFY_TOKEN (no line breaks)'
[[ $NOTIFY_USER_ID =~ ^[0-9]+$ ]] || die 'Set NOTIFY_USER_ID to the recipient ID'
exec 9>"$script_dir/$SERVICE_ID.lock"
flock -n 9 || exit 0
db="$script_dir/$SERVICE_ID.sqlite3"
sql() { sqlite3 -batch -bail -cmd '.timeout 5000' "$db" "$1"; }
sql 'PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS samples(ts INTEGER PRIMARY KEY, used INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY CHECK(id=1), cycle TEXT, last_used INTEGER);
INSERT OR IGNORE INTO state(id) VALUES(1);
CREATE TABLE IF NOT EXISTS alerts(scope TEXT, rule TEXT, sent INTEGER NOT NULL, PRIMARY KEY(scope,rule));' >/dev/null
now=$(date +%s)
notify() {
  local kind=$1 message=$2 payload status body error_file response_file error
  response_file="$script_dir/.notify-response.$$"
  error_file="$script_dir/.notify-error.$$"
  if ! payload=$(jq -cn --arg user "$NOTIFY_USER_ID" --arg text "$message" \
    '{user_id:$user,message:[{type:"text",data:{text:$text}}]}'); then
    printf 'jms-monitor: %s notification: failed to build JSON request body\n' "$kind" >&2
    return 1
  fi
  if ! status=$(printf '%s' "$payload" | curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --request POST --header "Authorization: Bearer $NOTIFY_TOKEN" \
    --header 'Content-Type: application/json' --data-binary @- \
    --output "$response_file" --write-out '%{http_code}' "${NOTIFY_BASE_URL%/}/send_private_msg" 2>"$error_file"); then
    error=$(<"$error_file")
    printf 'jms-monitor: %s notification: curl failed: %s\n' "$kind" "${error:-unknown curl error}" >&2
    rm -f -- "$response_file" "$error_file"
    return 1
  fi
  if [[ $status != 2[0-9][0-9] ]]; then
    body=$(head -c 1000 "$response_file" 2>/dev/null || true)
    printf 'jms-monitor: %s notification: HTTP %s; response: %s\n' "$kind" "$status" "${body:-<empty>}" >&2
    rm -f -- "$response_file" "$error_file"
    return 1
  fi
  rm -f -- "$response_file" "$error_file"
}
# Send query through curl config on stdin, keeping UUID out of curl process arguments.
if ! response=$(printf 'url = "https://justmysocks6.net/members/getbwcounter.php?service=%s&id=%s"\n' "$SERVICE_ID" "$API_UUID" |
  curl --config - --silent --show-error --fail --connect-timeout 10 --max-time 30 --max-filesize 1048576); then die 'Usage API request failed (see curl error above)'; fi
if ! fields=$(printf '%s' "$response" | jq -er '
  def uint: type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
  select(type == "object") |
  select((.monthly_bw_limit_b | uint) and .monthly_bw_limit_b > 0) |
  select(.bw_counter_b | uint) |
  select((.bw_reset_day_of_month | uint) and .bw_reset_day_of_month >= 1 and .bw_reset_day_of_month <= 31) |
  [.monthly_bw_limit_b,.bw_counter_b,.bw_reset_day_of_month] | @tsv'); then die 'Invalid usage API response'; fi
read -r limit used reset_day <<< "$fields"
# Calendar date is a cycle hint, not proof that the upstream counter reset at midnight.
la_date=$(TZ=America/Los_Angeles date -d "@$now" +%Y-%m-%d)
month=${la_date:0:7}
day=${la_date:8:2}
if (( 10#$day < reset_day )); then month=$(date -u -d "$month-01 -1 month" +%Y-%m); fi
cycle="$month-$reset_day"
old_cycle=$(sql 'SELECT cycle FROM state WHERE id=1;')
old_used=$(sql 'SELECT last_used FROM state WHERE id=1;')
reset=false
[[ -n $old_used ]] && (( used < old_used )) && reset=true
# A detected drop starts a new short-window baseline even outside the expected reset day.
if [[ $cycle != "$old_cycle" || $reset == true ]]; then
  sql 'DELETE FROM samples;'
fi
sql "BEGIN IMMEDIATE;
UPDATE state SET cycle='$cycle',last_used=$used WHERE id=1;
INSERT OR REPLACE INTO samples VALUES($now,$used);
DELETE FROM samples WHERE ts < $((now-RETENTION_SECONDS));
COMMIT;"
exit_status=0
# Avoid treating the previous cycle's still-visible high counter as a new-cycle alert.
# Keep a pending flag until a counter drop is observed; first-ever execution has no such evidence.
sql 'CREATE TABLE IF NOT EXISTS flags(name TEXT PRIMARY KEY, value INTEGER NOT NULL);'
if [[ -n $old_cycle && $cycle != "$old_cycle" && $reset == false ]]; then
  sql "INSERT OR REPLACE INTO flags VALUES('await_reset',1);"
fi
if [[ $reset == true ]]; then sql "DELETE FROM flags WHERE name='await_reset';"; fi
pending=$(sql "SELECT COALESCE(MAX(value),0) FROM flags WHERE name='await_reset';")
crossed=()
if (( pending == 0 )); then
  for threshold in "${thresholds[@]}"; do
    # Floating comparison in SQLite avoids signed integer overflow in used*100.
    reached=$(sql "SELECT $used * 100.0 >= $limit * $threshold;")
    sent=$(sql "SELECT COUNT(*) FROM alerts WHERE scope='$cycle' AND rule='pct-$threshold';")
    if (( reached && !sent )); then crossed+=("$threshold"); fi
  done
fi
if ((${#crossed[@]})); then
  percent=$(sql "SELECT printf('%.2f',$used*100.0/$limit);")
  if notify percentage "流量提醒：服务 $SERVICE_ID 已用 $used / $limit 字节（$percent%），达到阈值：${crossed[*]}%。周期：$cycle（洛杉矶时间）。"; then
    statements='BEGIN IMMEDIATE;'
    for threshold in "${crossed[@]}"; do statements+="INSERT OR REPLACE INTO alerts VALUES('$cycle','pct-$threshold',$now);"; done
    sql "$statements COMMIT;"
  else exit_status=1; printf 'jms-monitor: percentage notification failed; will retry on a later run\n' >&2; fi
fi
# Only use a sample at/before the window boundary, within a bounded tolerance.
baseline=$(sql "SELECT ts || '|' || used FROM samples WHERE ts <= $((now-WINDOW_SECONDS)) AND ts >= $((now-WINDOW_SECONDS-WINDOW_TOLERANCE_SECONDS)) ORDER BY ts DESC LIMIT 1;")
if [[ -n $baseline ]]; then
  IFS='|' read -r previous_time previous_used <<< "$baseline"
  delta=$((used-previous_used))
  last=$(sql "SELECT COALESCE(MAX(sent),0) FROM alerts WHERE scope='monitor' AND rule='burst';")
  if (( delta >= WINDOW_LIMIT_BYTES && now-last >= COOLDOWN_SECONDS )); then
    if notify burst "流量异常：服务 $SERVICE_ID 最近 $((now-previous_time)) 秒使用 $delta 字节，达到短时阈值 $WINDOW_LIMIT_BYTES 字节（配置窗口 $WINDOW_SECONDS 秒）。"; then
      sql "INSERT OR REPLACE INTO alerts VALUES('monitor','burst',$now);"
    else exit_status=1; printf 'jms-monitor: burst notification failed; will retry on a later run\n' >&2; fi
  fi
fi
if (( pending )); then printf 'jms-monitor: waiting for usage counter reset before percentage alerts\n' >&2; fi
exit "$exit_status"
