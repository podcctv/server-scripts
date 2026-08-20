#!/usr/bin/env bash
set -Eeuo pipefail

# Abuse Guard V3.4
# Scope:
#   - Incus containers: Debian / Alpine only
#   - root Podman containers: Debian / Alpine only
#   - Docker: intentionally ignored
# Policy:
#   - Direct-clean airport/node panels, Nezha, known miners/malware
#   - Kill active packet/scan tools when running or persisted, but do not remove distro package binaries
#   - Explicitly do NOT target x-ui / 3x-ui / sing-box
#   - No generic systemd runtime-diff tracking; notifications contain only confirmed risk evidence

VERSION="3.4"
AGENT="/usr/local/sbin/abuse-guard-v34"
CONF="/etc/abuse-guard-v34.conf"
STATE_DIR="/var/lib/abuse-guard-v34"
LOG_DIR="/var/log/abuse-guard-v34"
SERVICE="/etc/systemd/system/abuse-guard-v34.service"
TIMER="/etc/systemd/system/abuse-guard-v34.timer"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERR] run as root" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Upgrade / legacy cleanup
# -----------------------------------------------------------------------------
# Upgrade order is intentional:
#   1) read Telegram settings from current/legacy files
#   2) stop and remove legacy Abuse Guard units/files
#   3) preserve the current V3.4 config if it already exists
#   4) install/overwrite the current V3.4 agent + units
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
    /etc/default/abuse-guard \
    /usr/local/sbin/abuse-guard-v3 \
    /usr/local/sbin/abuse-guard-v30 \
    /usr/local/sbin/abuse-guard-v31 \
    /usr/local/sbin/abuse-guard-v32 \
    /usr/local/sbin/abuse-guard-v33 \
    /usr/local/sbin/incus-podman-abuse-guard-v3 \
    /usr/local/sbin/incus-podman-abuse-guard-v30 \
    /usr/local/sbin/incus-podman-abuse-guard-v31 \
    /usr/local/sbin/incus-podman-abuse-guard-v32 \
    /usr/local/sbin/incus-podman-abuse-guard-v33; do
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

legacy_removed=()
record_removed() {
  legacy_removed+=("$1")
}

is_current_unit() {
  case "$1" in
    abuse-guard-v34.service|abuse-guard-v34.timer) return 0 ;;
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

  # Old agents/scripts in /usr/local/sbin. Preserve the current V3.4 agent.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$AGENT" ]] && continue
    rm -f -- "$path"
    record_removed "$path"
  done < <(find /usr/local/sbin -maxdepth 1 -type f \
      \( -iname '*abuse*guard*' -o -iname '*incus*podman*guard*' \) \
      -print 2>/dev/null || true)

  # Old configuration files. Preserve the current V3.4 configuration.
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

  # Old state/log directories. Preserve only the current V3.4 directories.
  for path in /var/lib/abuse-guard* /var/lib/incus-podman-abuse-guard*; do
    [[ -e "$path" ]] || continue
    [[ "$path" == "$STATE_DIR" ]] && continue
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

mkdir -p "$STATE_DIR" "$LOG_DIR"
chmod 700 "$STATE_DIR"

# Preserve an existing V3.4 config on repeated installs. If absent, create it
# with Telegram values migrated before the legacy files were removed.
if [[ ! -f "$CONF" ]]; then
  cat > "$CONF" <<CFG
# Abuse Guard V3.4 configuration
# Leave Telegram values empty to disable Telegram alerts.
TELEGRAM_BOT_TOKEN=${MIGRATED_TOKEN:-}
TELEGRAM_CHAT_ID=${MIGRATED_CHAT:-}

# Suppress identical unresolved-risk alerts for this many seconds.
NOTIFY_COOLDOWN=21600

# Timer interval. Installer writes the systemd timer separately; this is informational.
SCAN_INTERVAL=1h
CFG
fi
# Keep an existing V3.4 config aligned with the new hourly schedule.
if grep -q '^SCAN_INTERVAL=' "$CONF" 2>/dev/null; then
  sed -i 's/^SCAN_INTERVAL=.*/SCAN_INTERVAL=1h/' "$CONF"
else
  printf '\nSCAN_INTERVAL=1h\n' >> "$CONF"
fi
chmod 600 "$CONF"

cat > "$AGENT" <<'AGENT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.4"
CONF="/etc/abuse-guard-v34.conf"
STATE_DIR="/var/lib/abuse-guard-v34"
STATE_FILE="$STATE_DIR/notify-state.tsv"
LOCK_FILE="/run/abuse-guard-v34.lock"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
chmod 700 "$STATE_DIR"
chmod 600 "$STATE_FILE"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
NOTIFY_COOLDOWN=${NOTIFY_COOLDOWN:-21600}
HOST_NAME=$(hostname 2>/dev/null || printf unknown)

# One scanner at a time.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

# Explicit high-risk families. x-ui / 3x-ui / sing-box are intentionally absent.
# 'board' is intentionally supported, but with stricter matching than the other names.
family_of() {
  local s l
  s=${1:-}
  l=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')

  # Most specific first.
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

  local n
  for n in \
    v2bx xrayr marzban hiddify v2board xboard ss-panel sspanel ssmgr \
    xmrig cpuminer minerd ethminer nbminer lolminer t-rex kdevtmpfsi kinsing watchbog skidmap \
    xorddos muhsTik mirai tsunami gafgyt mozi; do
    n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')
    if [[ $l =~ (^|[[:space:]/_.:@-])${n}([[:space:]/_.:@-]|$) ]]; then
      echo "$n"; return 0
    fi
  done

  # 'board' is deliberately strict: do not match dashboard, keyboard, board-api, etc.
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

# container_sh runtime container command [args...]
container_sh() {
  local runtime=$1 container=$2 code=$3
  shift 3
  case "$runtime" in
    incus)
      incus exec "$container" -- sh -c "$code" sh "$@"
      ;;
    podman)
      podman exec "$container" sh -c "$code" sh "$@"
      ;;
    *)
      return 127
      ;;
  esac
}

container_os() {
  local runtime=$1 container=$2 id
  id=$(container_sh "$runtime" "$container" '. /etc/os-release 2>/dev/null || exit 1; printf "%s" "${ID:-}"' 2>/dev/null || true)
  case "$id" in
    debian|alpine) printf '%s' "$id" ;;
    *) return 1 ;;
  esac
}

add_finding() {
  local file=$1 class=$2 family=$3 kind=$4 detail=$5
  # Newlines and pipes make alert/state parsing noisy; normalize them.
  detail=${detail//$'\n'/ }
  detail=${detail//|/¦}
  printf '%s|%s|%s|%s\n' "$class" "$family" "$kind" "$detail" >> "$file"
}

safe_remove_path() {
  local runtime=$1 container=$2 path=$3
  # Never permit empty/root-like deletion, even if a detection bug occurs.
  case "$path" in
    ''|/|/etc|/usr|/usr/local|/var|/var/lib|/opt|/root|/tmp|/var/tmp|/dev/shm|/www|/var/www)
      return 1 ;;
  esac
  container_sh "$runtime" "$container" 'rm -rf -- "$1"' "$path" >/dev/null 2>&1 || true
}

scan_systemd_services() {
  local runtime=$1 container=$2 findings=$3 mode=$4
  local units unit fam class content frag
  units=$(container_sh "$runtime" "$container" '
    if command -v systemctl >/dev/null 2>&1; then
      { systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null || true; \
        systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null || true; } \
      | awk "{print \$1}" | sed "/^$/d" | sort -u
    fi
  ' 2>/dev/null || true)

  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    fam=$(family_of "$unit" || true)
    if [[ -z "$fam" ]]; then
      content=$(container_sh "$runtime" "$container" 'systemctl cat "$1" 2>/dev/null || true' "$unit" 2>/dev/null || true)
      fam=$(family_of "$content" || true)
      [[ -z "$fam" ]] && fam=$(packet_family_of "$content" || true)
    fi
    [[ -n "$fam" ]] || continue
    class=$(risk_class "$fam")
    add_finding "$findings" "$class" "$fam" "systemd-service" "$unit"

    if [[ "$mode" == cleanup ]]; then
      frag=$(container_sh "$runtime" "$container" 'systemctl show -p FragmentPath --value "$1" 2>/dev/null || true' "$unit" 2>/dev/null || true)
      container_sh "$runtime" "$container" '
        systemctl disable --now "$1" >/dev/null 2>&1 || systemctl stop "$1" >/dev/null 2>&1 || true
        systemctl reset-failed "$1" >/dev/null 2>&1 || true
      ' "$unit" >/dev/null 2>&1 || true

      case "$frag" in
        /etc/systemd/system/*|/usr/lib/systemd/system/*|/lib/systemd/system/*)
          safe_remove_path "$runtime" "$container" "$frag"
          ;;
      esac
      container_sh "$runtime" "$container" '
        find /etc/systemd/system -type l -lname "*$1" -delete 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
      ' "$unit" >/dev/null 2>&1 || true
    fi
  done <<< "$units"
}

scan_openrc_services() {
  local runtime=$1 container=$2 findings=$3 mode=$4
  local list svc fam class content
  list=$(container_sh "$runtime" "$container" 'find /etc/init.d -maxdepth 1 -type f -o -type l 2>/dev/null | sed "s#^/etc/init.d/##"' 2>/dev/null || true)
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    fam=$(family_of "$svc" || true)
    if [[ -z "$fam" ]]; then
      content=$(container_sh "$runtime" "$container" 'cat "/etc/init.d/$1" 2>/dev/null || true' "$svc" 2>/dev/null || true)
      fam=$(family_of "$content" || true)
      [[ -z "$fam" ]] && fam=$(packet_family_of "$content" || true)
    fi
    [[ -n "$fam" ]] || continue
    class=$(risk_class "$fam")
    add_finding "$findings" "$class" "$fam" "openrc-service" "$svc"
    if [[ "$mode" == cleanup ]]; then
      container_sh "$runtime" "$container" '
        rc-service "$1" stop >/dev/null 2>&1 || true
        rc-update del "$1" >/dev/null 2>&1 || true
        rm -f -- "/etc/init.d/$1"
      ' "$svc" >/dev/null 2>&1 || true
    fi
  done <<< "$list"
}

scan_processes() {
  local runtime=$1 container=$2 findings=$3 mode=$4
  local out line pid args fam class
  out=$(container_sh "$runtime" "$container" 'ps -eo pid=,args= 2>/dev/null || ps w 2>/dev/null || true' 2>/dev/null || true)
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]] || continue
    pid=${BASH_REMATCH[1]}
    args=${BASH_REMATCH[2]}
    [[ "$pid" != 1 ]] || continue

    fam=$(family_of "$args" || true)
    [[ -z "$fam" ]] && fam=$(packet_family_of "$args" || true)
    [[ -n "$fam" ]] || continue

    # Scanner plumbing itself is never a target.
    case "$args" in
      *abuse-guard-v34*|*"ps -eo pid"*) continue ;;
    esac

    class=$(risk_class "$fam")
    add_finding "$findings" "$class" "$fam" "process" "pid=$pid $args"
    if [[ "$mode" == cleanup ]]; then
      container_sh "$runtime" "$container" '
        kill -TERM "$1" >/dev/null 2>&1 || true
        sleep 1
        kill -KILL "$1" >/dev/null 2>&1 || true
      ' "$pid" >/dev/null 2>&1 || true
    fi
  done <<< "$out"
}

# Known application paths. Packet-tool distro binaries are intentionally NOT here.
scan_known_paths() {
  local runtime=$1 container=$2 findings=$3 mode=$4
  local fam class path exists
  while IFS='|' read -r fam path; do
    [[ -n "$fam" && -n "$path" ]] || continue
    exists=$(container_sh "$runtime" "$container" '[ -e "$1" ] || [ -L "$1" ]' "$path" >/dev/null 2>&1 && echo yes || true)
    [[ "$exists" == yes ]] || continue
    class=$(risk_class "$fam")
    add_finding "$findings" "$class" "$fam" "path" "$path"
    [[ "$mode" == cleanup ]] && safe_remove_path "$runtime" "$container" "$path"
  done <<'PATHS'
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
xmrig-proxy|/opt/xmrig-proxy
kdevtmpfsi|/tmp/kdevtmpfsi
kdevtmpfsi|/var/tmp/kdevtmpfsi
kdevtmpfsi|/dev/shm/kdevtmpfsi
kinsing|/tmp/kinsing
kinsing|/var/tmp/kinsing
kinsing|/dev/shm/kinsing
watchbog|/tmp/watchbog
watchbog|/var/tmp/watchbog
xorddos|/tmp/xorddos
xorddos|/var/tmp/xorddos
PATHS
}

# Discover exact suspicious basenames in common abuse locations.
# This does not use substring matching, so x-ui / 3x-ui / sing-box are untouched.
scan_discovered_paths() {
  local runtime=$1 container=$2 findings=$3 mode=$4
  local list path base fam class
  list=$(container_sh "$runtime" "$container" '
    for r in /tmp /var/tmp /dev/shm /opt /etc /usr/local /var/lib /var/www /www/wwwroot /root; do
      [ -e "$r" ] || continue
      find "$r" -xdev -maxdepth 4 \( -type f -o -type d -o -type l \) -print 2>/dev/null || true
    done
  ' 2>/dev/null || true)

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    base=${path##*/}
    fam=$(family_of "$base" || true)
    [[ -n "$fam" ]] || continue

    # Generic 'board' is only auto-removed when it is an exact top-level app directory/file
    # under selected application roots. This avoids dashboard/board-api false positives.
    if [[ "$fam" == board ]]; then
      case "$path" in
        /opt/board|/etc/board|/usr/local/board|/var/lib/board|/var/www/board|/www/wwwroot/board|/root/board) ;;
        *) continue ;;
      esac
    fi

    # Avoid deleting system package documentation/cache merely because of a matching basename.
    case "$path" in
      /usr/local/share/*|/usr/local/lib/*|/etc/alternatives/*) continue ;;
    esac

    class=$(risk_class "$fam")
    add_finding "$findings" "$class" "$fam" "discovered-path" "$path"
    [[ "$mode" == cleanup ]] && safe_remove_path "$runtime" "$container" "$path"
  done <<< "$list"
}

scan_persistence_files() {
  local runtime=$1 container=$2 findings=$3 mode=$4
  local files f content line fam class
  files=$(container_sh "$runtime" "$container" '
    {
      [ -f /etc/crontab ] && echo /etc/crontab
      find /etc/cron.d /var/spool/cron /var/spool/cron/crontabs -maxdepth 2 -type f 2>/dev/null || true
      [ -f /etc/rc.local ] && echo /etc/rc.local
      find /etc/local.d /etc/profile.d -maxdepth 1 -type f 2>/dev/null || true
    } | sort -u
  ' 2>/dev/null || true)

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    content=$(container_sh "$runtime" "$container" 'cat "$1" 2>/dev/null || true' "$f" 2>/dev/null || true)
    [[ -n "$content" ]] || continue

    local hit=0
    while IFS= read -r line; do
      fam=$(family_of "$line" || true)
      [[ -z "$fam" ]] && fam=$(packet_family_of "$line" || true)
      [[ -n "$fam" ]] || continue
      class=$(risk_class "$fam")
      add_finding "$findings" "$class" "$fam" "persistence" "$f: $line"
      hit=1
    done <<< "$content"

    if [[ "$mode" == cleanup && "$hit" -eq 1 ]]; then
      # Remove only confirmed-risk lines. Do not rewrite unrelated service/runtime entries.
      container_sh "$runtime" "$container" '
        src=$1; tmp="${src}.abuseguard.$$"
        : > "$tmp"
        while IFS= read -r line || [ -n "$line" ]; do
          low=$(printf "%s" "$line" | tr "[:upper:]" "[:lower:]")
          if printf "%s\n" "$low" | grep -Eq \
             "(^|[[:space:]/_.:@-])(nezha-agent|nezha-dashboard|v2bx|xrayr|marzban-node|marzban|hiddify-panel|hiddify-manager|hiddify|v2board|xboard|ss-panel|sspanel-uim|sspanel|trojan-panel|shadowsocks-manager|ssmgr|xmrig-proxy|xmrig|cpuminer-multi|cpuminer|minerd|ethminer|nbminer|lolminer|t-rex|kdevtmpfsi|kinsing|watchbog|skidmap|xorddos|muhstik|mirai|tsunami|gafgyt|mozi|hping3|masscan|zmap|nping)([[:space:]/_.:@-]|$)"; then
            continue
          fi
          if printf "%s\n" "$low" | grep -Eq "(^|[[:space:]/_.:@])board([[:space:]/_.:@]|$)"; then
            continue
          fi
          printf "%s\n" "$line" >> "$tmp"
        done < "$src"
        cat "$tmp" > "$src"
        rm -f "$tmp"
      ' "$f" >/dev/null 2>&1 || true
    fi
  done <<< "$files"
}

scan_container() {
  local runtime=$1 container=$2 display=$3 os=$4 mode=$5 out=$6
  : > "$out"
  if [[ "$os" == debian ]]; then
    scan_systemd_services "$runtime" "$container" "$out" "$mode"
  elif [[ "$os" == alpine ]]; then
    scan_openrc_services "$runtime" "$container" "$out" "$mode"
  fi
  scan_processes "$runtime" "$container" "$out" "$mode"
  scan_persistence_files "$runtime" "$container" "$out" "$mode"
  scan_known_paths "$runtime" "$container" "$out" "$mode"
  scan_discovered_paths "$runtime" "$container" "$out" "$mode"
  sort -u -o "$out" "$out" 2>/dev/null || true
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
  local runtime=$1 container=$2 display=$3 os before after
  os=$(container_os "$runtime" "$container" || true)
  case "$os" in
    debian|alpine) ;;
    *)
      log "SKIP runtime=$runtime container=$display reason=os-not-debian-or-alpine"
      return 0
      ;;
  esac

  before=$(mktemp)
  after=$(mktemp)
  trap 'rm -f "${before:-}" "${after:-}"' RETURN

  scan_container "$runtime" "$container" "$display" "$os" cleanup "$before"
  if [[ -s "$before" ]]; then
    sleep 1
    scan_container "$runtime" "$container" "$display" "$os" audit "$after"
    log "RISK runtime=$runtime container=$display os=$os found=$(wc -l < "$before" | tr -d ' ') remaining=$(wc -l < "$after" | tr -d ' ')"
    notify_if_needed "$runtime" "$container" "$display" "$os" "$before" "$after"
  else
    state_clear "$(state_key "$runtime" "$container")"
  fi

  rm -f "$before" "$after"
  trap - RETURN
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
  scan_incus
  scan_podman
  # Docker intentionally not scanned.
}

main "$@"
AGENT_EOF

chmod 750 "$AGENT"

# Stop the old schedule before replacing the unit files.
# This is important when upgrading from the old 2-minute timer: otherwise the
# existing timer can retrigger the scanner while the installer is updating it.
systemctl disable --now abuse-guard-v34.timer >/dev/null 2>&1 || true
systemctl stop abuse-guard-v34.service >/dev/null 2>&1 || true
systemctl reset-failed abuse-guard-v34.service >/dev/null 2>&1 || true

cat > "$SERVICE" <<EOF
[Unit]
Description=Abuse Guard V3.4 - Incus/Podman Debian/Alpine scanner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT
User=root

# Keep the scanner low priority. It is a periodic maintenance job, not a daemon.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

# A broken/slow scan must not remain active forever.
TimeoutStartSec=45min
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

cat > "$TIMER" <<'EOF'
[Unit]
Description=Run Abuse Guard V3.4 once per hour

[Timer]
# First scan shortly after boot.
OnBootSec=5min

# IMPORTANT:
# Schedule from the END of the previous scan, not from its start.
# Therefore a slow scan can never turn into back-to-back continuous scanning.
OnUnitInactiveSec=1h

# Exact-to-the-second execution is unnecessary for this maintenance task.
AccuracySec=1min

Unit=abuse-guard-v34.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now abuse-guard-v34.timer

# Syntax-check the installed scanner.
bash -n "$AGENT"

echo "[OK] Abuse Guard V3.4 installed / updated"
if (( ${#legacy_removed[@]} > 0 )); then
  echo "     Legacy: removed ${#legacy_removed[@]} old file(s)/state item(s)"
else
  echo "     Legacy: no old Abuse Guard files found"
fi
echo "     Agent : $AGENT"
echo "     Config: $CONF"
echo "     Timer : abuse-guard-v34.timer (1 hour after the previous scan finishes)"
echo ""
echo "Scope: Incus + root Podman, running Debian/Alpine containers only; Docker ignored."
echo "Allow: x-ui / 3x-ui / sing-box are not cleanup targets."
echo "Clean: airport/node panels, Nezha agent/dashboard, exact board, known miners/malware."
echo "Packet: active hping3/masscan/zmap/nping processes or persistence are stopped/removed; package binaries are not deleted."
echo ""
echo "Test once: systemctl start abuse-guard-v34.service"
echo "Logs     : journalctl -u abuse-guard-v34.service -n 100 --no-pager"
