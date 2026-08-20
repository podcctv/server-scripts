#!/usr/bin/env bash
set -Eeuo pipefail

# Abuse Guard V3.6
# Scope:
#   - Incus containers: Debian / Alpine only
#   - root Podman containers: Debian / Alpine only
#   - Docker: intentionally ignored
# Policy:
#   - Direct-clean airport/node panels, Nezha, known miners/malware
#   - Kill active packet/scan tools when running or persisted, but do not remove distro package binaries
#   - Explicitly do NOT target x-ui / 3x-ui / sing-box
#   - No generic systemd runtime-diff tracking; notifications contain only confirmed risk evidence

VERSION="3.6"
AGENT="/usr/local/sbin/abuse-guard-v36"
CURRENT_LINK="/usr/local/sbin/abuse-guard"
CONF="/etc/abuse-guard-v36.conf"
STATE_DIR="/var/lib/abuse-guard-v36"
LOG_DIR="/var/log/abuse-guard-v36"
SERVICE="/etc/systemd/system/abuse-guard-v36.service"
TIMER="/etc/systemd/system/abuse-guard-v36.timer"

# Automatic installer update
UPDATE_SOURCE_URL="https://raw.githubusercontent.com/podcctv/server-scripts/refs/heads/main/install-abuse-guard.sh"
UPDATER="/usr/local/sbin/abuse-guard-auto-update"
UPDATE_SERVICE="/etc/systemd/system/abuse-guard-auto-update.service"
UPDATE_TIMER="/etc/systemd/system/abuse-guard-auto-update.timer"
UPDATE_STATE_DIR="/var/lib/abuse-guard-updater"
UPDATE_HASH_FILE="$UPDATE_STATE_DIR/installer.sha256"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERR] run as root" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Upgrade / legacy cleanup
# -----------------------------------------------------------------------------
# Upgrade order is intentional:
#   1) read Telegram settings from current/legacy files
#   2) stop and remove legacy Abuse Guard units/files
#   3) preserve the current V3.6 config if it already exists
#   4) install/overwrite the current V3.6 agent + units
# This makes repeated GitHub installs idempotent while preventing old timers
# from continuing to scan and generate duplicate alerts.

extract_old_value() {
  local names="$1" file line val
  for file in \
    "$CONF" \
    /etc/abuse-guard.conf \
    /etc/abuse-guard-v3.conf \
    /etc/abuse-guard-v30.conf \
    /etc/abuse-guard-v31.conf \
    /etc/abuse-guard-v32.conf \
    /etc/abuse-guard-v33.conf \
    /etc/abuse-guard-v34.conf \
    /etc/abuse-guard-v35.conf \
    /etc/default/abuse-guard \
    /usr/local/sbin/abuse-guard-v3 \
    /usr/local/sbin/abuse-guard-v30 \
    /usr/local/sbin/abuse-guard-v31 \
    /usr/local/sbin/abuse-guard-v32 \
    /usr/local/sbin/abuse-guard-v33 \
    /usr/local/sbin/abuse-guard-v34 \
    /usr/local/sbin/abuse-guard-v35 \
    /usr/local/sbin/incus-podman-abuse-guard-v3 \
    /usr/local/sbin/incus-podman-abuse-guard-v30 \
    /usr/local/sbin/incus-podman-abuse-guard-v31 \
    /usr/local/sbin/incus-podman-abuse-guard-v32 \
    /usr/local/sbin/incus-podman-abuse-guard-v33 \
    /usr/local/sbin/incus-podman-abuse-guard-v34 \
    /usr/local/sbin/incus-podman-abuse-guard-v35; do
    [[ -f "$file" ]] || continue
    line=$(grep -E -m1 "^(${names})=" "$file" 2>/dev/null || true)
    [[ -n "$line" ]] || continue
    val=${line#*=}
    val=${val%$'\r'}
    val=${val#\"}; val=${val%\"}
    val=${val#\'}; val=${val%\'}
    [[ -n "$val" ]] && { printf '%s' "$val"; return 0; }
  done
  return 1
}

MIGRATED_TOKEN=$(extract_old_value 'TELEGRAM_BOT_TOKEN|TG_BOT_TOKEN|BOT_TOKEN' || true)
MIGRATED_CHAT=$(extract_old_value 'TELEGRAM_CHAT_ID|TG_CHAT_ID|CHAT_ID' || true)
MIGRATED_COOLDOWN=$(extract_old_value 'NOTIFY_COOLDOWN' || true)

legacy_removed=()
record_removed() {
  legacy_removed+=("$1")
}

is_current_unit() {
  case "$1" in
    abuse-guard-v36.service|abuse-guard-v36.timer|abuse-guard-auto-update.service|abuse-guard-auto-update.timer) return 0 ;;
    *) return 1 ;;
  esac
}

is_legacy_unit_name() {
  local l
  l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$l" in
    *abuse*guard*.service|*abuse*guard*.timer|*incus*podman*guard*.service|*incus*podman*guard*.timer)
      return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_legacy_units() {
  local unit path

  # First stop/disable every legacy unit known to systemd.
  while read -r unit _; do
    [[ -n "$unit" ]] || continue
    is_current_unit "$unit" && continue
    is_legacy_unit_name "$unit" || continue
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done < <(systemctl list-unit-files --no-legend 2>/dev/null || true)

  # Remove custom legacy unit files/symlinks under /etc/systemd/system only.
  # Do not touch distribution units under /usr/lib or /lib.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    unit=${path##*/}
    is_current_unit "$unit" && continue
    is_legacy_unit_name "$unit" || continue
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f -- "$path"
    record_removed "$path"
  done < <(find /etc/systemd/system -maxdepth 3 \( -type f -o -type l \) \
      \( -iname '*abuse*guard*.service' -o -iname '*abuse*guard*.timer' \
         -o -iname '*incus*podman*guard*.service' -o -iname '*incus*podman*guard*.timer' \) \
      -print 2>/dev/null || true)

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
}

cleanup_legacy_files() {
  local path base

  # Old agents/scripts in /usr/local/sbin. Preserve the current V3.6 agent.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$AGENT" ]] && continue
    [[ "$path" == "$UPDATER" ]] && continue
    rm -f -- "$path"
    record_removed "$path"
  done < <(find /usr/local/sbin -maxdepth 1 -type f \
      \( -iname '*abuse*guard*' -o -iname '*incus*podman*guard*' \) \
      -print 2>/dev/null || true)

  # Old configuration files. Preserve the current V3.6 configuration.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$CONF" ]] && continue
    rm -f -- "$path"
    record_removed "$path"
  done < <(find /etc -maxdepth 1 -type f \
      \( -iname 'abuse-guard*.conf' -o -iname 'incus-podman-abuse-guard*.conf' \) \
      -print 2>/dev/null || true)

  if [[ -f /etc/default/abuse-guard ]]; then
    rm -f -- /etc/default/abuse-guard
    record_removed "/etc/default/abuse-guard"
  fi

  # Old cron launchers, if an earlier build used cron instead of a systemd timer.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    rm -f -- "$path"
    record_removed "$path"
  done < <(find /etc/cron.d -maxdepth 1 -type f \
      \( -iname '*abuse*guard*' -o -iname '*incus*podman*guard*' \) \
      -print 2>/dev/null || true)

  # Old state/log directories. Preserve only the current V3.6 directories.
  for path in /var/lib/abuse-guard* /var/lib/incus-podman-abuse-guard*; do
    [[ -e "$path" ]] || continue
    [[ "$path" == "$STATE_DIR" ]] && continue
    [[ "$path" == "$UPDATE_STATE_DIR" ]] && continue
    rm -rf -- "$path"
    record_removed "$path"
  done
  for path in /var/log/abuse-guard* /var/log/incus-podman-abuse-guard*; do
    [[ -e "$path" ]] || continue
    [[ "$path" == "$LOG_DIR" ]] && continue
    rm -rf -- "$path"
    record_removed "$path"
  done
}

cleanup_legacy_units
cleanup_legacy_files

mkdir -p "$STATE_DIR" "$LOG_DIR" "$UPDATE_STATE_DIR"
chmod 700 "$STATE_DIR" "$UPDATE_STATE_DIR"

# Preserve an existing V3.6 config on repeated installs. If absent, create it
# with Telegram values migrated before the legacy files were removed.
if [[ ! -f "$CONF" ]]; then
  cat > "$CONF" <<CFG
# Abuse Guard V3.6 configuration
# Leave Telegram values empty to disable Telegram alerts.
TELEGRAM_BOT_TOKEN=${MIGRATED_TOKEN:-}
TELEGRAM_CHAT_ID=${MIGRATED_CHAT:-}

# Suppress identical unresolved-risk alerts for this many seconds.
NOTIFY_COOLDOWN=${MIGRATED_COOLDOWN:-21600}

# Scanner schedule. The scanner is NOT resident; it runs once, exits, then waits one hour.
SCAN_INTERVAL=1h

# Hard timeout for one container exec/snapshot operation, in seconds.
CONTAINER_EXEC_TIMEOUT=120

# Automatic installer update.
AUTO_UPDATE=true
UPDATE_CHECK_INTERVAL=24h
UPDATE_SOURCE_URL=${UPDATE_SOURCE_URL}
CFG
fi
# Keep an existing V3.6 config aligned with the current schedules/settings.
upsert_conf() {
  local key=$1 value=$2
  if grep -q "^${key}=" "$CONF" 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$CONF"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONF"
  fi
}

upsert_conf SCAN_INTERVAL "1h"
upsert_conf CONTAINER_EXEC_TIMEOUT "120"
upsert_conf AUTO_UPDATE "true"
upsert_conf UPDATE_CHECK_INTERVAL "24h"
upsert_conf UPDATE_SOURCE_URL "$UPDATE_SOURCE_URL"
chmod 600 "$CONF"

cat > "$AGENT" <<'AGENT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.6"
CONF="/etc/abuse-guard-v36.conf"
STATE_DIR="/var/lib/abuse-guard-v36"
STATE_FILE="$STATE_DIR/notify-state.tsv"
LOCK_FILE="/run/abuse-guard-v36.lock"

# Version query must work without touching system state.
case "${1:-}" in
  --version|-V|version)
    printf 'Abuse Guard V%s\n' "$VERSION"
    exit 0
    ;;
esac

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
chmod 700 "$STATE_DIR"
chmod 600 "$STATE_FILE"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
NOTIFY_COOLDOWN=${NOTIFY_COOLDOWN:-21600}
CONTAINER_EXEC_TIMEOUT=${CONTAINER_EXEC_TIMEOUT:-120}
HOST_NAME=$(hostname 2>/dev/null || printf unknown)

# One scanner at a time. There is no resident monitoring loop in this program.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

# Explicit high-risk families. x-ui / 3x-ui / sing-box are intentionally absent.
family_of() {
  local s l n
  s=${1:-}
  l=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')

  if [[ $l =~ (^|[[:space:]/_.:@-])nezha-dashboard([[:space:]/_.:@-]|$) ]]; then echo nezha-dashboard; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])nezha-agent([[:space:]/_.:@-]|$) ]]; then echo nezha-agent; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])marzban-node([[:space:]/_.:@-]|$) ]]; then echo marzban-node; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])hiddify-panel([[:space:]/_.:@-]|$) ]]; then echo hiddify-panel; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])hiddify-manager([[:space:]/_.:@-]|$) ]]; then echo hiddify-manager; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])sspanel-uim([[:space:]/_.:@-]|$) ]]; then echo sspanel-uim; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])shadowsocks-manager([[:space:]/_.:@-]|$) ]]; then echo shadowsocks-manager; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])trojan-panel([[:space:]/_.:@-]|$) ]]; then echo trojan-panel; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])xmrig-proxy([[:space:]/_.:@-]|$) ]]; then echo xmrig-proxy; return 0; fi
  if [[ $l =~ (^|[[:space:]/_.:@-])cpuminer-multi([[:space:]/_.:@-]|$) ]]; then echo cpuminer-multi; return 0; fi

  for n in \
    v2bx xrayr marzban hiddify v2board xboard ss-panel sspanel ssmgr \
    xmrig cpuminer minerd ethminer nbminer lolminer t-rex kdevtmpfsi kinsing watchbog skidmap \
    xorddos muhstik mirai tsunami gafgyt mozi; do
    if [[ $l =~ (^|[[:space:]/_.:@-])${n}([[:space:]/_.:@-]|$) ]]; then
      echo "$n"; return 0
    fi
  done

  # Strict generic "board" matching only.
  if [[ $l =~ (^|[[:space:]/_.:@])board([[:space:]/_.:@]|$) ]]; then
    echo board; return 0
  fi

  return 1
}

packet_family_of() {
  local s l n
  s=${1:-}
  l=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  for n in hping3 masscan zmap nping; do
    if [[ $l =~ (^|[[:space:]/_.:@-])${n}([[:space:]/_.:@-]|$) ]]; then
      echo "$n"; return 0
    fi
  done
  return 1
}

risk_class() {
  case "$1" in
    v2bx|xrayr|marzban|marzban-node|hiddify|hiddify-panel|hiddify-manager|v2board|xboard|ss-panel|sspanel|sspanel-uim|trojan-panel|shadowsocks-manager|ssmgr|board)
      echo AIRPORT ;;
    nezha-agent|nezha-dashboard)
      echo NEZHA ;;
    xmrig|xmrig-proxy|cpuminer|cpuminer-multi|minerd|ethminer|nbminer|lolminer|t-rex)
      echo MINER ;;
    kdevtmpfsi|kinsing|watchbog|skidmap|xorddos|muhstik|mirai|tsunami|gafgyt|mozi)
      echo MALWARE ;;
    hping3|masscan|zmap|nping)
      echo PACKET ;;
    *) echo RISK ;;
  esac
}

add_finding() {
  local file=$1 class=$2 family=$3 kind=$4 detail=$5
  detail=${detail//$'\n'/ }
  detail=${detail//|/¦}
  printf '%s|%s|%s|%s\n' "$class" "$family" "$kind" "$detail" >> "$file"
}

plan_add() {
  local file=$1 record=$2
  [[ "$record" != *$'\n'* ]] || return 0
  printf '%s\n' "$record" >> "$file"
}

# One exec call per payload, with a hard timeout.
container_sh() {
  local runtime=$1 container=$2 code=$3
  shift 3

  case "$runtime" in
    incus)
      if command -v timeout >/dev/null 2>&1; then
        timeout --foreground "${CONTAINER_EXEC_TIMEOUT}s" \
          incus exec "$container" -- sh -c "$code" sh "$@"
      else
        incus exec "$container" -- sh -c "$code" sh "$@"
      fi
      ;;
    podman)
      if command -v timeout >/dev/null 2>&1; then
        timeout --foreground "${CONTAINER_EXEC_TIMEOUT}s" \
          podman exec "$container" sh -c "$code" sh "$@"
      else
        podman exec "$container" sh -c "$code" sh "$@"
      fi
      ;;
    *)
      return 127
      ;;
  esac
}

snapshot_code() {
  cat <<'SNAPSHOT_EOF'
set +e

. /etc/os-release 2>/dev/null
os=${ID:-unknown}
printf 'META|OS|%s\n' "$os"

case "$os" in
  debian|alpine) ;;
  *) exit 0 ;;
esac

RISK_RE='nezha-agent|nezha-dashboard|v2bx|xrayr|marzban-node|marzban|hiddify-panel|hiddify-manager|hiddify|v2board|xboard|ss-panel|sspanel-uim|sspanel|trojan-panel|shadowsocks-manager|ssmgr|xmrig-proxy|xmrig|cpuminer-multi|cpuminer|minerd|ethminer|nbminer|lolminer|t-rex|kdevtmpfsi|kinsing|watchbog|skidmap|xorddos|muhstik|mirai|tsunami|gafgyt|mozi|hping3|masscan|zmap|nping'
TOKEN_RE="(^|[[:space:]/_.:@-])(${RISK_RE})([[:space:]/_.:@-]|$)"

is_risk_text() {
  text=$1
  printf '%s\n' "$text" | grep -Eiq "$TOKEN_RE" && return 0
  printf '%s\n' "$text" | grep -Eiq '(^|[[:space:]/_.:@])board([[:space:]/_.:@]|$)'
}

first_risk_hint() {
  text=$1
  if printf '%s\n' "$text" | grep -Eiq "$TOKEN_RE"; then
    # The host performs final family classification with the stricter matcher.
    printf '%s' "$text" | tr '|' '/'
    return 0
  fi
  if printf '%s\n' "$text" | grep -Eiq '(^|[[:space:]/_.:@])board([[:space:]/_.:@]|$)'; then
    printf 'board'
    return 0
  fi
  return 1
}

# 1) Process snapshot.
if ps -eo pid=,args= >/dev/null 2>&1; then
  ps -eo pid=,args= 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] && printf 'PROC|%s\n' "$line"
  done
else
  ps w 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] && printf 'PROC|%s\n' "$line"
  done
fi

# 2) systemd: suspicious unit names + suspicious service file contents.
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        if is_risk_text "$unit"; then
          hint=$(first_risk_hint "$unit")
          printf 'SYSTEMD|%s||%s\n' "$unit" "$hint"
        fi
      done

  {
    for root in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
      [ -d "$root" ] || continue
      find "$root" -maxdepth 3 -type f -name '*.service' -print 2>/dev/null
    done
  } | sort -u | while IFS= read -r file; do
    [ -n "$file" ] || continue
    unit=${file##*/}
    hint=
    if is_risk_text "$unit"; then
      hint=$(first_risk_hint "$unit")
    else
      line=$(grep -Ei -m1 "$TOKEN_RE" "$file" 2>/dev/null)
      if [ -n "$line" ]; then
        hint=$(printf '%s' "$line" | tr '|' '/')
      elif grep -Eiq '(^|[[:space:]/_.:@])board([[:space:]/_.:@]|$)' "$file" 2>/dev/null; then
        hint=board
      fi
    fi
    [ -n "$hint" ] && printf 'SYSTEMD|%s|%s|%s\n' "$unit" "$file" "$hint"
  done
fi

# 3) OpenRC service definitions.
if [ -d /etc/init.d ]; then
  find /etc/init.d -maxdepth 1 \( -type f -o -type l \) -print 2>/dev/null \
    | while IFS= read -r file; do
        [ -n "$file" ] || continue
        svc=${file##*/}
        hint=
        if is_risk_text "$svc"; then
          hint=$(first_risk_hint "$svc")
        else
          line=$(grep -Ei -m1 "$TOKEN_RE" "$file" 2>/dev/null)
          if [ -n "$line" ]; then
            hint=$(printf '%s' "$line" | tr '|' '/')
          elif grep -Eiq '(^|[[:space:]/_.:@])board([[:space:]/_.:@]|$)' "$file" 2>/dev/null; then
            hint=board
          fi
        fi
        [ -n "$hint" ] && printf 'OPENRC|%s|%s|%s\n' "$svc" "$file" "$hint"
      done
fi

# 4) Persistence files, filtered inside this one exec.
{
  [ -f /etc/crontab ] && printf '%s\n' /etc/crontab
  find /etc/cron.d /var/spool/cron /var/spool/cron/crontabs -maxdepth 2 -type f -print 2>/dev/null
  [ -f /etc/rc.local ] && printf '%s\n' /etc/rc.local
  find /etc/local.d /etc/profile.d -maxdepth 1 -type f -print 2>/dev/null
} | sort -u | while IFS= read -r file; do
  [ -f "$file" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    if is_risk_text "$line"; then
      clean=$(printf '%s' "$line" | tr '|' '/')
      printf 'PERSIST|%s|%s\n' "$file" "$clean"
    fi
  done < "$file"
done

# 5) Known exact application/malware paths, all checked in the same exec.
while IFS='|' read -r fam path; do
  [ -n "$fam" ] && [ -n "$path" ] || continue
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf 'KPATH|%s|%s\n' "$fam" "$path"
  fi
done <<'KNOWN_PATHS'
v2bx|/etc/V2bX
v2bx|/usr/local/V2bX
v2bx|/usr/bin/V2bX
v2bx|/usr/local/bin/V2bX
xrayr|/etc/XrayR
xrayr|/usr/local/XrayR
xrayr|/usr/bin/XrayR
xrayr|/usr/local/bin/XrayR
nezha-agent|/opt/nezha/agent
nezha-agent|/etc/nezha/agent
nezha-agent|/usr/local/bin/nezha-agent
nezha-agent|/usr/bin/nezha-agent
nezha-dashboard|/opt/nezha/dashboard
nezha-dashboard|/etc/nezha/dashboard
marzban|/opt/marzban
marzban|/etc/marzban
marzban|/var/lib/marzban
marzban-node|/opt/marzban-node
hiddify|/opt/hiddify
hiddify-manager|/opt/hiddify-manager
hiddify-panel|/opt/hiddify-panel
v2board|/opt/v2board
v2board|/var/www/v2board
v2board|/www/wwwroot/v2board
xboard|/opt/xboard
xboard|/var/www/xboard
xboard|/www/wwwroot/xboard
sspanel|/opt/sspanel
sspanel|/var/www/sspanel
sspanel|/www/wwwroot/sspanel
sspanel-uim|/opt/sspanel-uim
sspanel-uim|/var/www/sspanel-uim
sspanel-uim|/www/wwwroot/sspanel-uim
trojan-panel|/opt/trojan-panel
shadowsocks-manager|/opt/shadowsocks-manager
ssmgr|/opt/ssmgr
board|/opt/board
board|/etc/board
board|/usr/local/board
board|/var/lib/board
board|/var/www/board
board|/www/wwwroot/board
xmrig|/tmp/xmrig
xmrig|/var/tmp/xmrig
xmrig|/dev/shm/xmrig
xmrig|/opt/xmrig
xmrig|/usr/local/bin/xmrig
xmrig-proxy|/opt/xmrig-proxy
kdevtmpfsi|/tmp/kdevtmpfsi
kdevtmpfsi|/var/tmp/kdevtmpfsi
kdevtmpfsi|/dev/shm/kdevtmpfsi
kdevtmpfsi|/usr/local/bin/kdevtmpfsi
kinsing|/tmp/kinsing
kinsing|/var/tmp/kinsing
kinsing|/dev/shm/kinsing
kinsing|/usr/local/bin/kinsing
watchbog|/tmp/watchbog
watchbog|/var/tmp/watchbog
xorddos|/tmp/xorddos
xorddos|/var/tmp/xorddos
KNOWN_PATHS

# 6) Lightweight exact-basename discovery in common drop/application roots.
# The old V3.5 maxdepth=4 walk across /etc, /usr/local and /var/lib is removed.
scan_root() {
  root=$1
  depth=$2
  [ -e "$root" ] || return 0

  find "$root" -xdev -maxdepth "$depth" \( -type f -o -type d -o -type l \) -print 2>/dev/null \
    | while IFS= read -r path; do
        base=${path##*/}
        low=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
        case "$low" in
          nezha-dashboard|nezha-agent|v2bx|xrayr|marzban-node|marzban|hiddify-panel|hiddify-manager|hiddify|v2board|xboard|ss-panel|sspanel-uim|sspanel|trojan-panel|shadowsocks-manager|ssmgr|xmrig-proxy|xmrig|cpuminer-multi|cpuminer|minerd|ethminer|nbminer|lolminer|t-rex|kdevtmpfsi|kinsing|watchbog|skidmap|xorddos|muhstik|mirai|tsunami|gafgyt|mozi|board)
            printf 'DPATH|%s\n' "$path"
            ;;
        esac
      done
}

scan_root /tmp 3
scan_root /var/tmp 3
scan_root /dev/shm 3
scan_root /opt 3
scan_root /var/www 3
scan_root /www/wwwroot 3
scan_root /root 2
scan_root /usr/local/bin 1
scan_root /etc 1
scan_root /var/lib 1
SNAPSHOT_EOF
}

cleanup_code() {
  cat <<'CLEANUP_EOF'
set +e
plan=$1

RISK_RE='nezha-agent|nezha-dashboard|v2bx|xrayr|marzban-node|marzban|hiddify-panel|hiddify-manager|hiddify|v2board|xboard|ss-panel|sspanel-uim|sspanel|trojan-panel|shadowsocks-manager|ssmgr|xmrig-proxy|xmrig|cpuminer-multi|cpuminer|minerd|ethminer|nbminer|lolminer|t-rex|kdevtmpfsi|kinsing|watchbog|skidmap|xorddos|muhstik|mirai|tsunami|gafgyt|mozi|hping3|masscan|zmap|nping'
TOKEN_RE="(^|[[:space:]/_.:@-])(${RISK_RE})([[:space:]/_.:@-]|$)"

safe_rm() {
  p=$1
  case "$p" in
    ''|/|/etc|/usr|/usr/local|/var|/var/lib|/opt|/root|/tmp|/var/tmp|/dev/shm|/www|/var/www)
      return 1 ;;
  esac
  rm -rf -- "$p" >/dev/null 2>&1 || true
}

systemd_changed=0
kill_pids=

while IFS='|' read -r kind a b; do
  [ -n "$kind" ] || continue
  case "$kind" in
    PID)
      case "$a" in
        ''|*[!0-9]*) ;;
        *)
          kill -TERM "$a" >/dev/null 2>&1 || true
          kill_pids="${kill_pids} ${a}"
          ;;
      esac
      ;;
    SYSTEMD)
      unit=$a
      frag=$b
      [ -n "$unit" ] || continue
      systemctl disable --now "$unit" >/dev/null 2>&1 || systemctl stop "$unit" >/dev/null 2>&1 || true
      systemctl reset-failed "$unit" >/dev/null 2>&1 || true
      case "$frag" in
        /etc/systemd/system/*|/usr/lib/systemd/system/*|/lib/systemd/system/*)
          safe_rm "$frag"
          ;;
      esac
      find /etc/systemd/system -type l -lname "*$unit" -delete 2>/dev/null || true
      systemd_changed=1
      ;;
    OPENRC)
      svc=$a
      frag=$b
      [ -n "$svc" ] || continue
      rc-service "$svc" stop >/dev/null 2>&1 || true
      rc-update del "$svc" >/dev/null 2>&1 || true
      case "$frag" in
        /etc/init.d/*) rm -f -- "$frag" >/dev/null 2>&1 || true ;;
      esac
      ;;
    PATH)
      safe_rm "$a"
      ;;
    PERSIST)
      src=$a
      [ -f "$src" ] || continue
      tmp="${src}.abuseguard.$$"
      : > "$tmp" || continue
      while IFS= read -r line || [ -n "$line" ]; do
        low=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
        if printf '%s\n' "$low" | grep -Eq "$TOKEN_RE"; then
          continue
        fi
        if printf '%s\n' "$low" | grep -Eq '(^|[[:space:]/_.:@])board([[:space:]/_.:@]|$)'; then
          continue
        fi
        printf '%s\n' "$line" >> "$tmp"
      done < "$src"
      cat "$tmp" > "$src"
      rm -f "$tmp"
      ;;
  esac
done <<PLAN_EOF
$plan
PLAN_EOF

if [ -n "$kill_pids" ]; then
  sleep 1
  for p in $kill_pids; do
    kill -KILL "$p" >/dev/null 2>&1 || true
  done
fi

if [ "$systemd_changed" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
CLEANUP_EOF
}

SNAPSHOT_CODE=$(snapshot_code)
CLEANUP_CODE=$(cleanup_code)

snapshot_container() {
  local runtime=$1 container=$2 out=$3 err=$4 rc
  : > "$out"
  : > "$err"
  if container_sh "$runtime" "$container" "$SNAPSHOT_CODE" >"$out" 2>"$err"; then
    return 0
  else
    rc=$?
    return "$rc"
  fi
}

parse_snapshot() {
  local input=$1 findings=$2 plan=$3 mode=${4:-audit}
  local line kind rest pid args fam class unit frag hint svc file content path base

  : > "$findings"
  [[ "$mode" == cleanup ]] && : > "$plan"

  SNAPSHOT_OS=unknown

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    kind=${line%%|*}
    rest=${line#*|}

    case "$kind" in
      META)
        if [[ "$rest" == OS\|* ]]; then
          SNAPSHOT_OS=${rest#OS|}
        fi
        ;;

      PROC)
        if [[ $rest =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]]; then
          pid=${BASH_REMATCH[1]}
          args=${BASH_REMATCH[2]}
          [[ "$pid" != 1 ]] || continue
          case "$args" in
            *abuse-guard-v36*|*"ps -eo pid"*) continue ;;
          esac
          fam=$(family_of "$args" || true)
          [[ -z "$fam" ]] && fam=$(packet_family_of "$args" || true)
          [[ -n "$fam" ]] || continue
          class=$(risk_class "$fam")
          add_finding "$findings" "$class" "$fam" "process" "pid=$pid $args"
          [[ "$mode" == cleanup ]] && plan_add "$plan" "PID|$pid|"
        fi
        ;;

      SYSTEMD)
        IFS='|' read -r unit frag hint <<< "$rest"
        fam=$(family_of "$hint" || true)
        [[ -z "$fam" ]] && fam=$(packet_family_of "$hint" || true)
        [[ -z "$fam" ]] && fam=$(family_of "$unit" || true)
        [[ -z "$fam" ]] && fam=$(packet_family_of "$unit" || true)
        [[ -n "$fam" ]] || continue
        class=$(risk_class "$fam")
        add_finding "$findings" "$class" "$fam" "systemd-service" "$unit"
        [[ "$mode" == cleanup ]] && plan_add "$plan" "SYSTEMD|$unit|$frag"
        ;;

      OPENRC)
        IFS='|' read -r svc frag hint <<< "$rest"
        fam=$(family_of "$hint" || true)
        [[ -z "$fam" ]] && fam=$(packet_family_of "$hint" || true)
        [[ -z "$fam" ]] && fam=$(family_of "$svc" || true)
        [[ -z "$fam" ]] && fam=$(packet_family_of "$svc" || true)
        [[ -n "$fam" ]] || continue
        class=$(risk_class "$fam")
        add_finding "$findings" "$class" "$fam" "openrc-service" "$svc"
        [[ "$mode" == cleanup ]] && plan_add "$plan" "OPENRC|$svc|$frag"
        ;;

      PERSIST)
        file=${rest%%|*}
        content=${rest#*|}
        fam=$(family_of "$content" || true)
        [[ -z "$fam" ]] && fam=$(packet_family_of "$content" || true)
        [[ -n "$fam" ]] || continue
        class=$(risk_class "$fam")
        add_finding "$findings" "$class" "$fam" "persistence" "$file: $content"
        [[ "$mode" == cleanup ]] && plan_add "$plan" "PERSIST|$file|"
        ;;

      KPATH)
        fam=${rest%%|*}
        path=${rest#*|}
        [[ -n "$fam" && -n "$path" ]] || continue
        class=$(risk_class "$fam")
        add_finding "$findings" "$class" "$fam" "path" "$path"
        [[ "$mode" == cleanup ]] && plan_add "$plan" "PATH|$path|"
        ;;

      DPATH)
        path=$rest
        [[ -n "$path" ]] || continue
        base=${path##*/}
        fam=$(family_of "$base" || true)
        [[ -n "$fam" ]] || continue

        if [[ "$fam" == board ]]; then
          case "$path" in
            /opt/board|/etc/board|/usr/local/board|/var/lib/board|/var/www/board|/www/wwwroot/board|/root/board) ;;
            *) continue ;;
          esac
        fi

        case "$path" in
          /usr/local/share/*|/usr/local/lib/*|/etc/alternatives/*) continue ;;
        esac

        class=$(risk_class "$fam")
        add_finding "$findings" "$class" "$fam" "discovered-path" "$path"
        [[ "$mode" == cleanup ]] && plan_add "$plan" "PATH|$path|"
        ;;
    esac
  done < "$input"

  sort -u -o "$findings" "$findings" 2>/dev/null || true
  if [[ "$mode" == cleanup ]]; then
    sort -u -o "$plan" "$plan" 2>/dev/null || true
  fi
}

apply_cleanup_plan() {
  local runtime=$1 container=$2 plan_file=$3 err=$4 plan rc
  [[ -s "$plan_file" ]] || return 0

  # An unexpectedly huge plan remains visible in verification instead of being
  # allowed to create an unbounded command argument.
  plan=$(head -n 250 "$plan_file")

  : > "$err"
  if container_sh "$runtime" "$container" "$CLEANUP_CODE" "$plan" >/dev/null 2>"$err"; then
    return 0
  else
    rc=$?
    return "$rc"
  fi
}

state_key() {
  printf '%s/%s' "$1" "$2"
}

state_get() {
  local key=$1
  awk -F'|' -v k="$key" '$1==k {print $2"|"$3; exit}' "$STATE_FILE" 2>/dev/null || true
}

state_set() {
  local key=$1 hash=$2 epoch=$3 tmp
  tmp=$(mktemp)
  awk -F'|' -v k="$key" '$1!=k' "$STATE_FILE" > "$tmp" 2>/dev/null || true
  printf '%s|%s|%s\n' "$key" "$hash" "$epoch" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

state_clear() {
  local key=$1 tmp
  tmp=$(mktemp)
  awk -F'|' -v k="$key" '$1!=k' "$STATE_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

telegram_send() {
  local text=$1
  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS --max-time 12 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" \
    >/dev/null 2>&1 || true
}

notify_if_needed() {
  local runtime=$1 container=$2 display=$3 os=$4 before=$5 after=$6
  [[ -s "$before" ]] || { state_clear "$(state_key "$runtime" "$container")"; return 0; }

  local key hash now old old_hash old_epoch remaining status lines msg
  key=$(state_key "$runtime" "$container")
  hash=$(sha256sum "$before" | awk '{print $1}')
  now=$(date +%s)
  old=$(state_get "$key")
  old_hash=${old%%|*}
  old_epoch=${old#*|}
  [[ "$old" == *"|"* ]] || old_epoch=0

  if [[ "$hash" == "$old_hash" && $((now - old_epoch)) -lt "$NOTIFY_COOLDOWN" ]]; then
    return 0
  fi

  if [[ -s "$after" ]]; then
    status="处理后仍有风险项，已抑制相同告警 ${NOTIFY_COOLDOWN}s"
    remaining=$(wc -l < "$after" | tr -d ' ')
  else
    status="已清理；复检未发现同类风险项"
    remaining=0
  fi

  lines=$(awk -F'|' '{printf "- [%s] %s / %s: %s\n", $1,$2,$3,$4}' "$before" | head -n 25)
  msg="Abuse Guard V${VERSION}：发现并处理高风险项

Host: ${HOST_NAME}
Runtime: ${runtime}
Container: ${display}
OS: ${os}

Risk:
${lines}
Status: ${status}
Remaining: ${remaining}
Time: $(date '+%F %T')"

  telegram_send "$msg"
  state_set "$key" "$hash" "$now"
}

handle_one() {
  local runtime=$1 container=$2 display=$3
  local snap before plan after err cleanup_err verify_err rc start elapsed os

  snap=$(mktemp)
  before=$(mktemp)
  plan=$(mktemp)
  after=$(mktemp)
  err=$(mktemp)
  cleanup_err=$(mktemp)
  verify_err=$(mktemp)
  trap 'rm -f "${snap:-}" "${before:-}" "${plan:-}" "${after:-}" "${err:-}" "${cleanup_err:-}" "${verify_err:-}"' RETURN

  start=$(date +%s)

  if snapshot_container "$runtime" "$container" "$snap" "$err"; then
    :
  else
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    if [[ "$rc" -eq 124 ]]; then
      log "TIMEOUT runtime=$runtime container=$display stage=snapshot limit=${CONTAINER_EXEC_TIMEOUT}s elapsed=${elapsed}s"
    else
      log "ERROR runtime=$runtime container=$display stage=snapshot rc=$rc elapsed=${elapsed}s err=$(tail -n 1 "$err" 2>/dev/null || true)"
    fi
    return 0
  fi

  parse_snapshot "$snap" "$before" "$plan" cleanup
  os=$SNAPSHOT_OS

  case "$os" in
    debian|alpine) ;;
    *)
      elapsed=$(( $(date +%s) - start ))
      log "SKIP runtime=$runtime container=$display reason=os-not-debian-or-alpine os=$os elapsed=${elapsed}s"
      return 0
      ;;
  esac

  if [[ ! -s "$before" ]]; then
    state_clear "$(state_key "$runtime" "$container")"
    elapsed=$(( $(date +%s) - start ))
    log "OK runtime=$runtime container=$display os=$os elapsed=${elapsed}s"
    return 0
  fi

  if apply_cleanup_plan "$runtime" "$container" "$plan" "$cleanup_err"; then
    :
  else
    rc=$?
    if [[ "$rc" -eq 124 ]]; then
      log "TIMEOUT runtime=$runtime container=$display stage=cleanup limit=${CONTAINER_EXEC_TIMEOUT}s"
    else
      log "ERROR runtime=$runtime container=$display stage=cleanup rc=$rc err=$(tail -n 1 "$cleanup_err" 2>/dev/null || true)"
    fi
  fi

  sleep 1

  if snapshot_container "$runtime" "$container" "$snap" "$verify_err"; then
    parse_snapshot "$snap" "$after" /dev/null audit
  else
    rc=$?
    : > "$after"
    # Do not claim "clean" when post-clean verification itself failed.
    add_finding "$after" "RISK" "verification" "scan-error" "post-clean verification failed rc=$rc"
  fi

  elapsed=$(( $(date +%s) - start ))
  log "RISK runtime=$runtime container=$display os=$os found=$(wc -l < "$before" | tr -d ' ') remaining=$(wc -l < "$after" | tr -d ' ') elapsed=${elapsed}s"
  notify_if_needed "$runtime" "$container" "$display" "$os" "$before" "$after"
}

scan_incus() {
  command -v incus >/dev/null 2>&1 || return 0
  local rows name state type
  rows=$(incus list --format csv -c nst 2>/dev/null || true)
  while IFS=',' read -r name state type; do
    [[ -n "$name" ]] || continue
    [[ "${state^^}" == RUNNING ]] || continue
    [[ "${type,,}" == container ]] || continue
    handle_one incus "$name" "$name"
  done <<< "$rows"
}

scan_podman() {
  command -v podman >/dev/null 2>&1 || return 0
  local rows id name
  rows=$(podman ps --format '{{.ID}}|{{.Names}}' 2>/dev/null || true)
  while IFS='|' read -r id name; do
    [[ -n "$id" ]] || continue
    handle_one podman "$id" "${name:-$id}"
  done <<< "$rows"
}

main() {
  local start elapsed
  start=$(date +%s)
  log "START version=$VERSION mode=one-shot"
  scan_incus
  scan_podman
  elapsed=$(( $(date +%s) - start ))
  log "DONE version=$VERSION elapsed=${elapsed}s"
  # Docker intentionally not scanned.
}

main "$@"
AGENT_EOF

chmod 750 "$AGENT"
ln -sfn "$AGENT" "$CURRENT_LINK"

cat > "$UPDATER" <<'UPDATER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/abuse-guard-v36.conf"
STATE_DIR="/var/lib/abuse-guard-updater"
HASH_FILE="$STATE_DIR/installer.sha256"
LOCK_FILE="/run/abuse-guard-auto-update.lock"
CACHE_FILE="$STATE_DIR/install-abuse-guard.latest.sh"

DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/podcctv/server-scripts/refs/heads/main/install-abuse-guard.sh"
CURRENT_VERSION="3.6"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
AUTO_UPDATE=${AUTO_UPDATE:-true}
UPDATE_SOURCE_URL=${UPDATE_SOURCE_URL:-$DEFAULT_SOURCE_URL}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

case "${AUTO_UPDATE,,}" in
  1|yes|true|on) ;;
  *)
    log "auto-update disabled in $CONF"
    exit 0
    ;;
esac

# Never allow overlapping update checks.
exec 9>"$LOCK_FILE"
flock -n 9 || {
  log "another update check is already running; exit"
  exit 0
}

tmp=$(mktemp)
SELF_RUN=${BASH_SOURCE[0]:-}
cleanup_tmp() {
  rm -f "$tmp"
  case "$SELF_RUN" in
    /run/abuse-guard-updater.*) rm -f -- "$SELF_RUN" ;;
  esac
}
trap cleanup_tmp EXIT

download() {
  local url=$1 out=$2
  case "$url" in
    https://raw.githubusercontent.com/*) ;;
    *)
      log "refuse non-approved update source: $url"
      return 1
      ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    curl -fL --proto '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 120 \
      --retry 2 --retry-delay 3 \
      -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only --timeout=120 --tries=3 -O "$out" "$url"
  else
    log "curl/wget not found; cannot check updates"
    return 1
  fi
}

log "checking installer source: $UPDATE_SOURCE_URL"
download "$UPDATE_SOURCE_URL" "$tmp"

# Basic safety/integrity checks before execution.
[[ -s "$tmp" ]] || {
  log "downloaded installer is empty"
  exit 1
}

bash -n "$tmp" || {
  log "remote installer failed bash syntax check"
  exit 1
}

grep -qE 'Abuse Guard|abuse-guard' "$tmp" || {
  log "remote file does not look like an Abuse Guard installer"
  exit 1
}

# Never automatically downgrade to an older installer version.
# Same-version hash changes are allowed so hotfixes can be deployed without a version bump.
remote_version=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n 1)
[[ -n "$remote_version" ]] || {
  log "remote installer has no readable VERSION; refuse auto-update"
  exit 1
}

version_lt() {
  local a=$1 b=$2 first
  [[ "$a" == "$b" ]] && return 1
  first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)
  [[ "$first" == "$a" ]]
}

if version_lt "$remote_version" "$CURRENT_VERSION"; then
  log "remote version $remote_version is older than installed $CURRENT_VERSION; refuse downgrade"
  exit 0
fi

new_hash=$(sha256sum "$tmp" | awk '{print $1}')
old_hash=$(cat "$HASH_FILE" 2>/dev/null || true)

if [[ -n "$old_hash" && "$new_hash" == "$old_hash" ]]; then
  log "installer unchanged sha256=$new_hash"
  exit 0
fi

log "installer update detected old=${old_hash:-none} new=$new_hash"

# Keep a local copy of the exact installer being applied.
install -m 0750 "$tmp" "$CACHE_FILE"

# Run the downloaded installer only after all checks pass.
# The installer itself stops/replaces the old scanner timer safely.
if bash "$CACHE_FILE"; then
  printf '%s\n' "$new_hash" > "$HASH_FILE"
  chmod 600 "$HASH_FILE"
  log "automatic update applied successfully sha256=$new_hash"
else
  rc=$?
  log "automatic update failed rc=$rc; hash not advanced, will retry later"
  exit "$rc"
fi
UPDATER_EOF

chmod 750 "$UPDATER"

# Stop the old schedule before replacing the unit files.
# This is important when upgrading from the old 2-minute timer: otherwise the
# existing timer can retrigger the scanner while the installer is updating it.
systemctl disable --now abuse-guard-v36.timer >/dev/null 2>&1 || true
systemctl stop abuse-guard-v36.service >/dev/null 2>&1 || true
systemctl reset-failed abuse-guard-v36.service >/dev/null 2>&1 || true

cat > "$SERVICE" <<EOF
[Unit]
Description=Abuse Guard V3.6 - Incus/Podman Debian/Alpine scanner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT
User=root

# Low-impact maintenance task. V3.6 batches container inspection instead of
# spawning dozens of podman/incus exec processes per container.
Nice=10
CPUWeight=10
CPUQuota=50%
IOWeight=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

# A broken/slow scan must not remain active forever.
TimeoutStartSec=30min
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

cat > "$TIMER" <<'EOF'
[Unit]
Description=Run Abuse Guard V3.6 once per hour

[Timer]
# First scan five minutes after this timer is activated.
OnActiveSec=5min

# IMPORTANT:
# Schedule from the END of the previous scan, not from its start.
# Therefore a slow scan can never turn into back-to-back continuous scanning.
OnUnitInactiveSec=1h

# Exact-to-the-second execution is unnecessary for this maintenance task.
AccuracySec=1min

Unit=abuse-guard-v36.service

[Install]
WantedBy=timers.target
EOF

cat > "$UPDATE_SERVICE" <<'EOF'
[Unit]
Description=Abuse Guard - check installer source and auto-update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Run a /run copy so the installer may safely replace the installed updater.
ExecStart=/bin/bash -c 'tmp=$(mktemp /run/abuse-guard-updater.XXXXXX); cp /usr/local/sbin/abuse-guard-auto-update "$tmp"; chmod 700 "$tmp"; exec "$tmp"'
User=root
Nice=15
CPUWeight=10
IOWeight=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=15min
KillMode=control-group
EOF

cat > "$UPDATE_TIMER" <<'EOF'
[Unit]
Description=Check Abuse Guard installer source every 24 hours

[Timer]
# First update check 15 minutes after this timer is activated.
OnActiveSec=15min

# Check again 24 hours after the previous check finishes.
OnUnitInactiveSec=24h
AccuracySec=10min

Unit=abuse-guard-auto-update.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now abuse-guard-v36.timer
systemctl enable --now abuse-guard-auto-update.timer

# Syntax-check installed scripts.
bash -n "$AGENT"
bash -n "$UPDATER"

# Seed the updater hash with this installer when it is a normal readable file.
# If installed through a pipe/process substitution, the first scheduled updater
# run will safely establish/apply the remote source instead.
if [[ -f "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
  mkdir -p "$UPDATE_STATE_DIR"
  chmod 700 "$UPDATE_STATE_DIR"
  SELF_HASH=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
  printf '%s\n' "$SELF_HASH" > "$UPDATE_HASH_FILE"
  chmod 600 "$UPDATE_HASH_FILE"
fi

echo "[OK] Abuse Guard V3.6 installed / updated"
if (( ${#legacy_removed[@]} > 0 )); then
  echo "     Legacy: removed ${#legacy_removed[@]} old file(s)/state item(s)"
else
  echo "     Legacy: no old Abuse Guard files found"
fi
echo "     Agent : $AGENT"
echo "     Link  : $CURRENT_LINK  ($("$CURRENT_LINK" --version 2>/dev/null || true))"
echo "     Config: $CONF"
echo "     Scan  : abuse-guard-v36.timer (1 hour after the previous scan finishes; batched scanner)"
echo "     Update: abuse-guard-auto-update.timer (24 hours after the previous check finishes)"
echo "     Source: $UPDATE_SOURCE_URL"
echo ""
echo "Scope: Incus + root Podman, running Debian/Alpine containers only; Docker ignored."
echo "Allow: x-ui / 3x-ui / sing-box are not cleanup targets."
echo "Clean: airport/node panels, Nezha agent/dashboard, exact board, known miners/malware."
echo "Packet: active hping3/masscan/zmap/nping processes or persistence are stopped/removed; package binaries are not deleted."
echo "Perf: clean containers use one snapshot exec; risky containers use one batch cleanup plus one verification snapshot."
echo ""
echo "Version    : abuse-guard --version"
echo "Test scan  : systemctl start abuse-guard-v36.service"
echo "Test update: systemctl start abuse-guard-auto-update.service"
echo "Scan logs  : journalctl -u abuse-guard-v36.service -n 100 --no-pager"
echo "Update logs: journalctl -u abuse-guard-auto-update.service -n 100 --no-pager"
