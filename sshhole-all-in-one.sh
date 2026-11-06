#!/bin/sh
# SSHhole OpenSSH password-authentication bypass remediation for Alpine hosts and Alpine containers.
# Supported managers: Docker, Podman, Incus, LXD, Rust Runman v2.
# Safe baseline: do not change authentication, users, keys, passwords, ports,
# SSH daemon config, host firewall, repositories, container lifecycle or images.
# Updated: 2026-11-06 (v1.6). POSIX sh, BusyBox ash compatible.
set -u
umask 077

ACTION=check
SCOPE=all
ENGINE=all
RELOAD=yes
ALLOW_OPENRC_RESTART=no
RUNMAN_DATA_DIR=
COLOR_MODE=auto
COLOR_ON=no
SUMMARY_OK=0
SUMMARY_FIXED=0
SUMMARY_SAFE=0
SUMMARY_UNVERIFIED=0
SUMMARY_RISK=0
SUMMARY_PENDING=0
SUMMARY_SKIP=0
SUMMARY_FAIL=0
SUMMARY_TOTAL=0
LOG_FILE=
WORK=

usage() {
  cat <<'USAGE'
Usage:
  sh sshhole-all-in-one.sh --check [options]       # default: audit only
  sh sshhole-all-in-one.sh --fix [options]         # scan, auto-patch vulnerable Alpine OpenSSH, verify + safe HUP

Options:
  --scope all|host|containers   Default: all
  --engine all|docker|podman|incus|lxd|runman
                                Default: all; only limits container managers
  --no-reload                   Install patches, do NOT HUP sshd (reports pending)
  --allow-openrc-restart        Explicit fallback when sshd is managed by OpenRC but
                                has no verified master PID (may disconnect sessions)
  --color auto|always|never     Colored terminal status table (default: auto)
  --runman-data-dir /ABS/PATH   Override Rust Runman v2 persistent data directory
  -h, --help                    Help

Host may be Alpine, Debian or Ubuntu. Guest must be Alpine Linux with APK OpenSSH.
All running instances are examined; stopped instances are never started.
SAFE means no OpenSSH server is detected (safe against this OpenSSH issue),
OK means already-patched OpenSSH. FIXED(OK) means this run patched it and verified
the relevant running service (or found no running sshd). SKIP means out of scope.
UNVERIFIED means the image could not be audited reliably; never assume safe.
No permanent repository rewrites / full distribution upgrades / user or SSH config changes.
If the configured mirror is outdated, retries using a temporary, verified Alpine
official repository file for the SAME release branch; removes the file on exit.
Uses SIGHUP only on a PID-file-verified SSH listener; if uncertain, leaves a
PENDING_RELOAD item (the disk is patched but live daemon may still be vulnerable).
Container image templates are NOT updated: Docker/Podman re-create needs new image.
Rootless Podman launched under OTHER users is not discoverable via root's Podman CLI.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) ACTION=check ;;
    --fix) ACTION=fix ;;
    --scope) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; SCOPE=$2; shift ;;
    --engine) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; ENGINE=$2; shift ;;
    --no-reload) RELOAD=no ;;
    --allow-openrc-restart) ALLOW_OPENRC_RESTART=yes ;;
    --color) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; COLOR_MODE=$2; shift ;;
    --runman-data-dir) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; RUNMAN_DATA_DIR=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done
case "$COLOR_MODE" in auto|always|never) ;; *) echo "Invalid --color" >&2; exit 64 ;; esac
case "$SCOPE" in all|host|containers) ;; *) echo 'Invalid --scope' >&2; exit 64 ;; esac
case "$ENGINE" in all|docker|podman|incus|lxd|runman) ;; *) echo 'Invalid --engine' >&2; exit 64 ;; esac
case "$RUNMAN_DATA_DIR" in '') ;; /*) ;; *) echo '--runman-data-dir must be absolute' >&2; exit 64 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root on the host.' >&2; exit 1; }

case "$COLOR_MODE" in
  always) COLOR_ON=yes ;;
  auto) if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then COLOR_ON=yes; fi ;;
esac
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sshhole-all.XXXXXXXX") || exit 1
cleanup() { [ -z "$WORK" ] || rm -rf -- "$WORK"; }
trap 'cleanup' 0
trap 'exit 130' 2
trap 'exit 143' 15
if [ -d /var/log ] && [ -w /var/log ]; then
  LOG_FILE="/var/log/sshhole-all-$(date +%Y%m%d-%H%M%S)-$$.log"
else
  LOG_FILE="/tmp/sshhole-all-$(date +%Y%m%d-%H%M%S)-$$.log"
fi
: > "$LOG_FILE" || { echo 'Cannot create host log' >&2; exit 1; }
# Command substitution removes trailing tabs; build a reliable TAB character.
TAB=$(printf '\tX')
TAB=${TAB%X}
RESULTS_FILE="$WORK/results.tsv"
ENGINES_FILE="$WORK/engines.tsv"
: > "$RESULTS_FILE"
: > "$ENGINES_FILE"

say() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
want_engine() { [ "$ENGINE" = all ] || [ "$ENGINE" = "$1" ]; }

# Guest worker stays inline in this one-file installer: stdin is piped to /bin/sh.
guest_script() {
cat <<'GUEST_WORKER'
#!/bin/sh
set -u
umask 077
MODE=${1:-check}
RELOAD=${2:-yes}
ALLOW_OPENRC_RESTART=${3:-no}

out() { printf '%s\n' "$*"; }
finish() { out "SSHH_RESULT=$1"; exit "$2"; }

if [ ! -f /etc/alpine-release ] || ! command -v apk >/dev/null 2>&1; then
  out '[SKIP] Not Alpine or apk unavailable'; finish SKIP 0
fi
release=$(cat /etc/alpine-release 2>/dev/null)
branch=$(printf '%s\n' "$release" | cut -d. -f1,2)
if grep -Eq '^[[:space:]]*[^#[:space:]].*/edge/main' /etc/apk/repositories 2>/dev/null; then
  branch=edge
fi
case "$branch" in
  3.16) min=9.0_p1-r6 ;;
  3.17) min=9.1_p1-r7 ;;
  3.18) min=9.3_p2-r4 ;;
  3.19) min=9.6_p1-r3 ;;
  3.20) min=9.7_p1-r6 ;;
  3.21) min=9.9_p2-r1 ;;
  3.22) min=10.0_p1-r11 ;;
  3.23) min=10.2_p1-r1 ;;
  3.24) min=10.3_p1-r2 ;;
  edge) min=10.6_p2-r0 ;;
  *) out "[WARN] Alpine $release is not in verified fixed-version matrix"; finish FAIL 2 ;;
esac
out "[INFO] Alpine=$release branch=$branch minimum_patched=$min"

pkg=''
for p in openssh-server openssh-server-pam openssh-server-krb5; do
  if apk info -e "$p" >/dev/null 2>&1; then pkg=$p; break; fi
done
if [ -z "$pkg" ]; then
  if [ -x /usr/sbin/sshd ] || command -v sshd >/dev/null 2>&1; then
    out '[WARN] Non-APK or unknown sshd; will not replace a custom SSH installation'; finish FAIL 2
  fi
  # An untracked sshd process could be a manually-installed OpenSSH daemon.
  if command -v pidof >/dev/null 2>&1 && pidof sshd >/dev/null 2>&1; then
    out '[WARN] sshd is running but no OpenSSH APK server is installed; unknown binary, manual review needed'
    finish FAIL 2
  fi
  out '[SAFE] No OpenSSH server installed; not affected by this SSHhole OpenSSH vulnerability'
  finish SAFE 0
fi
# Alpine 3.23+ uses apk-tools v3: `apk info -v PKG` is NOT a stable way
# to obtain the installed version across apk v2 / v3. Read the installed DB
# first (v2 text DB still used by v3.23), then try the installed-package list.
# Never use apk policy/search here: they also show AVAILABLE repository versions.
parse_installed_list() {
  awk -v pre="$1-" '
    {
      entry=$1
      if (substr(entry,1,length(pre)) == pre) {
        v=substr(entry,length(pre)+1)
        if (v ~ /^[0-9][0-9A-Za-z._-]*$/) {print v; exit}
      }
    }
  '
}
version_from_db() {
  [ -r /lib/apk/db/installed ] || return 1
  awk -v want="$1" '
    /^P:/ { name=substr($0,3); next }
    /^V:/ { if (name==want) { print substr($0,3); exit } }
    /^$/ { name="" }
  ' /lib/apk/db/installed
}
version_of() {
  pkgname=$1
  # DB is local and authoritative; no network or repository cache needed.
  from_db=$(version_from_db "$pkgname" 2>/dev/null || true)
  if [ -n "$from_db" ]; then
    printf '%s\n' "$from_db"
    return 0
  fi
  from_list=$(apk list --installed "$pkgname" 2>/dev/null | parse_installed_list "$pkgname")
  if [ -n "$from_list" ]; then
    printf '%s\n' "$from_list"
    return 0
  fi
  # Compatibility fallback for older apk-tools and trimmed databases.
  from_info=$(apk info -a "$pkgname" 2>/dev/null | parse_installed_list "$pkgname")
  if [ -n "$from_info" ]; then
    printf '%s\n' "$from_info"
    return 0
  fi
  apk info -v "$pkgname" 2>/dev/null | parse_installed_list "$pkgname"
}
ver=$(version_of "$pkg")
if [ -z "$ver" ]; then
  out '[ERROR] Installed OpenSSH APK detected, but installed version could not be determined by APK database/list/info'
  out "[DIAG] apk_tools=$(apk --version 2>/dev/null | head -n 1)"
  if [ -r /lib/apk/db/installed ]; then
    out '[DIAG] /lib/apk/db/installed is readable'
  else
    out '[DIAG] /lib/apk/db/installed unavailable; tried apk list and apk info'
  fi
  finish FAIL 2
fi
compare() {
  apk version -t "$1" "$2" 2>/dev/null | tr -d '[:space:]'
}
cmp=$(compare "$ver" "$min")
case "$cmp" in
  '<') old=yes ;;
  '>'|'=') old=no ;;
  *) out "[ERROR] Invalid apk version comparison: $cmp"; finish FAIL 2 ;;
esac
out "[INFO] $pkg=$ver patched_threshold=$min"
# Do not report credentials or password hashes.
if [ -r /etc/shadow ]; then
  accounts=$(awk -F: '$2=="*" {n++} END {print n+0}' /etc/shadow)
  sha=$(awk -F: '$2 ~ /^\$[56]\$/ {n++} END {print n+0}' /etc/shadow)
  out "[INFO] shadow_star_accounts=$accounts sha_crypt_accounts=$sha"
fi
SSHD=/usr/sbin/sshd
[ -x "$SSHD" ] || SSHD=$(command -v sshd 2>/dev/null || true)
[ -n "$SSHD" ] && [ -x "$SSHD" ] || { out '[ERROR] OpenSSH APK installed but sshd binary missing'; finish FAIL 2; }

# Only trust the SSH master PID in a standard pidfile; do NOT signal a session.
master_pid=''
# Account for custom PidFile in sshd_config without modifying it.
configured_pidfile=$("$SSHD" -T 2>/dev/null | awk '$1=="pidfile" {print $2; exit}')
case "$configured_pidfile" in /*) ;; *) configured_pidfile='' ;; esac
for pf in "$configured_pidfile" /run/sshd.pid /var/run/sshd.pid; do
  [ -n "$pf" ] && [ -r "$pf" ] || continue
  pid=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  [ "$pid" -gt 1 ] 2>/dev/null || continue
  [ -d "/proc/$pid" ] || continue
  [ -r "/proc/$pid/comm" ] || continue
  [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = sshd ] || continue
  master_pid=$pid
  break
done
if [ -n "$master_pid" ]; then
  out "[INFO] SSH master PID (pidfile verified)=$master_pid"
else
  out '[INFO] No verified SSH listener pidfile (may be inactive/custom/supervised)'
fi
stale=no
if [ -n "$master_pid" ] && [ -r "/proc/$master_pid/exe" ]; then
  if command -v cmp >/dev/null 2>&1; then
    if ! cmp -s "/proc/$master_pid/exe" "$SSHD" 2>/dev/null; then stale=yes; fi
  else
    exe=$(readlink "/proc/$master_pid/exe" 2>/dev/null || true)
    case "$exe" in *' (deleted)') stale=yes ;; esac
  fi
fi

if [ "$MODE" = check ]; then
  if [ "$old" = yes ]; then
    out '[RISK] Vulnerable OpenSSH APK revision (no changes made)'; finish RISK 3
  fi
  if [ "$stale" = yes ]; then
    out '[PENDING] Patched APK on disk but sshd listener still runs a different binary'
    finish PENDING 4
  fi
  out '[OK] Installed OpenSSH server package meets fixed version'; finish OK 0
fi
[ "$MODE" = fix ] || { out "[ERROR] Unknown action: $MODE"; finish FAIL 2; }
[ "$(id -u)" = 0 ] || { out '[ERROR] Guest must run as root'; finish FAIL 2; }

# Snapshot effective SSH policy + config files. Never edit config deliberately.
TMP=$(mktemp -d /tmp/sshhole-guest.XXXXXXXX) || { out '[ERROR] tmp unavailable'; finish FAIL 2; }
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
config_fingerprints() {
  # Only hashes, never record private-key or password contents.
  # This also protects account credentials and host identity from surprise APK hooks.
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* \
           /etc/ssh/ssh_host_* /etc/passwd /etc/shadow /etc/group /etc/gshadow \
           /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] && sha256sum "$f"
  done
}
auth_snapshot() {
  "$SSHD" -T > "$1.all" 2>/dev/null || return 1
  grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|usepam|authenticationmethods|authorizedkeysfile|authorizedkeyscommand|authorizedkeyscommanduser|allowusers|denyusers|allowgroups|denygroups|hostbasedauthentication|gssapiauthentication|permittty|chrootdirectory|subsystem|forcecommand|hostkey|hostcertificate|trustedusercakeys|pubkeyacceptedalgorithms) ' "$1.all" | LC_ALL=C sort > "$1"
  [ -s "$1" ]
}
config_fingerprints > "$TMP/config.before"
before_valid=no
if "$SSHD" -t >/dev/null 2>&1 && auth_snapshot "$TMP/policy.before"; then
  before_valid=yes
else
  out '[WARN] Pre-upgrade sshd configuration validation failed; will NOT auto-reload'
fi

# Do not upgrade the entire Alpine installation or permanently change repositories.
# Use the configured mirror first. If that mirror is stale (APK returns success
# but leaves a vulnerable revision), retry ONLY preinstalled OpenSSH components
# from signed, official Alpine packages for this exact distribution branch.
# --repositories-file replaces repository selection for this ONE apk invocation.
if [ "$old" = yes ]; then
  set -- "$pkg"
  for p in openssh openssh-server openssh-server-pam openssh-server-krb5 \
           openssh-server-common openssh-server-common-openrc \
           openssh-keygen openssh-sftp-server openssh-client-common; do
    if [ "$p" != "$pkg" ] && apk info -e "$p" >/dev/null 2>&1; then set -- "$@" "$p"; fi
  done
  out "[ACTION] Upgrade preinstalled OpenSSH components: $*"
  out '[ACTION] First attempt: configured APK repositories (unchanged)'
  if ! apk update; then
    out '[WARN] Configured APK repository update failed; trying verified official fallback'
  elif ! apk upgrade "$@"; then
    out '[WARN] OpenSSH upgrade from configured repository failed; checking package state then trying official fallback'
  fi
  new=$(version_of "$pkg")
  [ -n "$new" ] || { out '[ERROR] Cannot read installed OpenSSH version after configured-mirror attempt'; finish FAIL 2; }
  post_cmp=$(compare "$new" "$min")
  case "$post_cmp" in
    '>'|'=') out "[OK] Configured mirror supplied patched $pkg=$new" ;;
    '<')
      out "[WARN] Configured mirror did not provide the required patch: $pkg=$new (need >=$min)"
      case "$branch" in
        edge) official_branch=edge ;;
        3.16|3.17|3.18|3.19|3.20|3.21|3.22|3.23|3.24)
          official_branch="v$branch" ;;
        *) out '[ERROR] No official fallback is defined for this Alpine branch'; finish FAIL 2 ;;
      esac
      fallback="$TMP/official-repositories"
      # Use Alpine's own HTTPS CDN and APK signing keys, and only the same
      # release branch. Never add edge or latest-stable to a stable installation.
      printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n' \
        "$official_branch" "$official_branch" > "$fallback" || {
          out '[ERROR] Cannot prepare temporary Alpine official repository list'; finish FAIL 2;
        }
      out "[ACTION] Temporary official Alpine repository fallback: $official_branch (configuration untouched)"
      # --no-cache forces fresh package indexes: the stale mirror's cached
      # APKINDEX must NOT influence this second attempt.
      if ! apk --repositories-file "$fallback" --no-cache upgrade "$@"; then
        out '[ERROR] Official Alpine fallback upgrade failed (network, package pinning or repository issue)'
        finish FAIL 2
      fi
      new=$(version_of "$pkg")
      [ -n "$new" ] || { out '[ERROR] Cannot read OpenSSH version after official fallback'; finish FAIL 2; }
      post_cmp=$(compare "$new" "$min")
      case "$post_cmp" in
        '>'|'=') out "[OK] Official fallback patched $pkg=$new; /etc/apk/repositories left unchanged" ;;
        '<') out "[ERROR] Official fallback did not reach patched version ($pkg=$new; need >=$min)"; finish FAIL 2 ;;
        *) out "[ERROR] Unexpected apk version comparison after fallback: $post_cmp"; finish FAIL 2 ;;
      esac
      ;;
    *) out "[ERROR] Unexpected apk version comparison after upgrade: $post_cmp"; finish FAIL 2 ;;
  esac
else
  new=$(version_of "$pkg")
  [ -n "$new" ] || { out '[ERROR] Cannot read installed OpenSSH version'; finish FAIL 2; }
  post_cmp=$(compare "$new" "$min")
  case "$post_cmp" in
    '>'|'=') out "[OK] $pkg remains patched at $new" ;;
    *) out "[ERROR] Patched version check failed: $pkg=$new"; finish FAIL 2 ;;
  esac
fi
if [ "$old" = yes ]; then
  out "[INFO] OpenSSH successfully upgraded from $ver to $new"
  out 'SSHH_PACKAGE_UPDATED=yes'
  success='FIXED(OK)'
else
  success=OK
fi
success_done() {
  out "[$success] $1"
  finish "$success" 0
}

config_fingerprints > "$TMP/config.after"
if ! cmp -s "$TMP/config.before" "$TMP/config.after"; then
  out '[WARN] sshd config files unexpectedly changed during APK transaction; DO NOT reload; review manually'
  finish PENDING 4
fi
if ! "$SSHD" -t >/dev/null 2>&1; then
  out '[WARN] Post-upgrade sshd -t failed; DO NOT reload; review manually'
  finish PENDING 4
fi
if [ "$before_valid" = yes ]; then
  if ! auth_snapshot "$TMP/policy.after" || ! cmp -s "$TMP/policy.before" "$TMP/policy.after"; then
    out '[WARN] Effective SSH policy changed; DO NOT reload; review manually'
    finish PENDING 4
  fi
fi
if [ "$RELOAD" = no ] && [ -z "$master_pid" ] && ! pidof sshd >/dev/null 2>&1; then
  success_done 'No SSH listener to reload; patched version verified'
fi
if [ "$RELOAD" = no ]; then
  out '[PENDING] --no-reload: package patched but listening daemon may still be stale'
  finish PENDING 4
fi
if [ -z "$master_pid" ]; then
  if command -v pidof >/dev/null 2>&1 && pidof sshd >/dev/null 2>&1; then
    if [ "$ALLOW_OPENRC_RESTART" = yes ] && [ -x /etc/init.d/sshd ] && command -v rc-service >/dev/null 2>&1 \
        && rc-service sshd status >/dev/null 2>&1 && [ "$before_valid" = yes ]; then
      out '[WARN] No trusted SSH master PID; explicitly requested OpenRC restart (may disconnect sessions)'
      if ! rc-service sshd restart; then
        out '[FAIL] OpenRC sshd restart failed; use provider console to recover'
        finish FAIL 2
      fi
      if ! rc-service sshd status >/dev/null 2>&1; then
        out '[FAIL] OpenRC sshd did not report running after restart'
        finish FAIL 2
      fi
      success_done 'OpenRC sshd restarted with patched package; configuration unchanged'
    fi
    out '[PENDING] sshd running without trusted master pidfile; not restarted automatically'
    finish PENDING 4
  fi
  success_done 'sshd is not running; patched version verified on disk'
fi
if [ -r /proc/1/comm ] && [ "$(cat /proc/1/comm)" = sshd ] && [ "$master_pid" = 1 ]; then
  out '[PENDING] sshd is PID 1 (application container); refuse SIGHUP to protect container lifecycle'
  finish PENDING 4
fi
if [ "$before_valid" != yes ]; then
  out '[PENDING] No verified pre-upgrade policy; refused SIGHUP'
  finish PENDING 4
fi
if [ "$old" = no ] && [ "$stale" = no ]; then
  success_done 'Patched package and listener already match; no signal necessary'
fi
# Never HUP a custom sshd binary. Re-exec would otherwise reload the wrong binary.
if command -v readlink >/dev/null 2>&1 && [ -L "/proc/$master_pid/exe" ]; then
  listener_binary=$(readlink "/proc/$master_pid/exe" 2>/dev/null || true)
  case "$listener_binary" in
    "$SSHD"|"$SSHD (deleted)") ;;
    *) out "[PENDING] SSH listener binary is custom/unexpected: $listener_binary; refuse signal"; finish PENDING 4 ;;
  esac
fi
# OpenSSH documents listener SIGHUP as self re-exec. Existing sessions are generally retained,
# but this is not an absolute zero-disconnection guarantee, especially under custom supervision.
out "[ACTION] SIGHUP to verified listener PID $master_pid; no SSH port/auth changes"
if ! kill -HUP "$master_pid" 2>/dev/null; then
  out '[PENDING] Could not signal SSH master'; finish PENDING 4
fi
sleep 1
new_pid=''
for pf in "$configured_pidfile" /run/sshd.pid /var/run/sshd.pid; do
  [ -n "$pf" ] && [ -r "$pf" ] || continue
  p=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
  case "$p" in ''|*[!0-9]*) continue ;; esac
  if [ -r "/proc/$p/comm" ] && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = sshd ]; then
    new_pid=$p
    break
  fi
done
if [ -z "$new_pid" ]; then
  out '[FAIL] Listener PID disappeared after SIGHUP; recover using VM/provider console'
  finish FAIL 2
fi
if [ -r "/proc/$new_pid/exe" ] && command -v cmp >/dev/null 2>&1 && ! cmp -s "/proc/$new_pid/exe" "$SSHD"; then
  out '[PENDING] Listener still differs from disk binary after SIGHUP; investigate manually'
  finish PENDING 4
fi
success_done "SSH listener re-executed / verified PID=$new_pid; login policy unchanged"
GUEST_WORKER
}

# Log text stays free of ANSI escapes. Final table colors only the terminal.
engine_record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ENGINES_FILE"
  say "[ENGINE] $1: $2 ($3)"
}

record_failure() {
  fail_engine=$1
  fail_target=$2
  fail_msg=$3
  SUMMARY_FAIL=$((SUMMARY_FAIL+1))
  SUMMARY_TOTAL=$((SUMMARY_TOTAL+1))
  printf '%s\t%s\t%s\t%s\t%s\n' "$fail_engine" "$fail_target" '-' 'FAIL' "$fail_msg" >> "$RESULTS_FILE"
  say "[ERROR] $fail_engine/$fail_target: $fail_msg"
}

show_result() {
  label=$1
  response=$2
  rc=$3
  SUMMARY_TOTAL=$((SUMMARY_TOTAL + 1))
  say "----- $label -----"
  cat "$response" | tee -a "$LOG_FILE"
  status=$(sed -n 's/^SSHH_RESULT=//p' "$response" | tail -n 1)
  case "$status:$rc" in
    OK:0) SUMMARY_OK=$((SUMMARY_OK+1)) ;;
    'FIXED(OK):0') SUMMARY_FIXED=$((SUMMARY_FIXED+1)) ;;
    UNVERIFIED:5) SUMMARY_UNVERIFIED=$((SUMMARY_UNVERIFIED+1)) ;;
    SAFE:0) SUMMARY_SAFE=$((SUMMARY_SAFE+1)) ;;
    RISK:3) SUMMARY_RISK=$((SUMMARY_RISK+1)) ;;
    PENDING:4) SUMMARY_PENDING=$((SUMMARY_PENDING+1)) ;;
    SKIP:0) SUMMARY_SKIP=$((SUMMARY_SKIP+1)) ;;
    *) status=FAIL; SUMMARY_FAIL=$((SUMMARY_FAIL+1)); say "[ERROR] execution exit_code=$rc guest_result=$(sed -n 's/^SSHH_RESULT=//p' "$response" | tail -n 1)" ;;
  esac
  # Last matching status line is used as a short explanation in the report.
  case "$status" in
    SAFE|OK|'FIXED(OK)'|RISK|PENDING|SKIP|UNVERIFIED)
      note=$(awk -v s="[$status]" 'index($0,s)==1 {v=substr($0,length(s)+2)} END{print v}' "$response") ;;
    FAIL)
      note=$(awk '/^\[(ERROR|FAIL|WARN)\]/{v=$0} END{print v}' "$response") ;;
  esac
  [ -n "$note" ] || note="See detailed log (exit=$rc)"
  os=$(sed -n 's/^\[INFO\] Alpine=\([^ ]*\).*/Alpine \1/p' "$response" | head -n 1)
  if [ -z "$os" ]; then
    if [ "$status" = SKIP ]; then os='Other OS'; else os='Unknown'; fi
  fi
  kind=${label%%:*}
  if [ "$kind" = "$label" ]; then target=$label; else target=${label#*:}; fi
  note=$(printf '%s' "$note" | tr '\t\r\n' '   ')
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$target" "$os" "$status" "$note" >> "$RESULTS_FILE"
}

run_target() {
  label=$1
  shift
  tmp="$WORK/guest-result"
  : > "$tmp"
  guest_script | "$@" > "$tmp" 2>&1
  rc=$?
  show_result "$label" "$tmp" "$rc"
}

# CLI output can become stale during a large scan. Re-check each container's
# running state and do not count stop/start races as failed vulnerability checks.
oci_running() {
  "$1" inspect -f '{{.State.Running}}' "$2" 2>/dev/null | head -n 1
}

oci_synthetic() {
  label=$1
  state=$2
  code=$3
  detail=$4
  printf '[%s] %s\nSSHH_RESULT=%s\n' "$state" "$detail" "$state" > "$WORK/guest-result"
  show_result "$label" "$WORK/guest-result" "$code"
}

# Shell-less/distroless OCI containers: read-only, offline OS identification via
# Docker/Podman cp. Never insert binaries, edit the filesystem or start a stopped
# container to get a result. Failure to prove non-Alpine is UNVERIFIED, not SAFE.
oci_probe_no_shell() {
  engine=$1
  id=$2
  label=$3
  probe=$(mktemp -d "$WORK/oci-probe.XXXXXXXX") || {
    oci_synthetic "$label" UNVERIFIED 5 'No /bin/sh and cannot create audit directory'
    return
  }
  os_id=''
  alpine_release=''
  if "$engine" cp -L "$id:/etc/os-release" "$probe/os-release" >/dev/null 2>&1 && [ -f "$probe/os-release" ]; then
    os_id=$(sed -n 's/^ID=//p' "$probe/os-release" | head -n 1 | tr -d "\"'[:space:]")
  fi
  if "$engine" cp -L "$id:/etc/alpine-release" "$probe/alpine-release" >/dev/null 2>&1 && [ -s "$probe/alpine-release" ]; then
    alpine_release=$(head -n 1 "$probe/alpine-release")
  fi
  if [ -n "$alpine_release" ] || [ "$os_id" = alpine ]; then
    if "$engine" cp -L "$id:/lib/apk/db/installed" "$probe/installed" >/dev/null 2>&1 && [ -f "$probe/installed" ]; then
      open_pkg=$(awk '/^P:openssh-server(-pam|-krb5)?$/ {print substr($0,3); exit}' "$probe/installed")
      if [ -n "$open_pkg" ]; then
        ver=$(awk -v want="$open_pkg" '/^P:/ {p=substr($0,3)} /^V:/ {if(p==want){print substr($0,3);exit}} /^$/ {p=""}' "$probe/installed")
        oci_synthetic "$label" UNVERIFIED 5 "Alpine $alpine_release: $open_pkg=$ver but /bin/sh missing; cannot safely upgrade or validate running sshd"
      else
        # In addition to package DB, check standard sshd paths for custom builds.
        has_ssh=no
        for loc in /usr/sbin/sshd /usr/local/sbin/sshd /usr/bin/sshd; do
          if "$engine" cp -L "$id:$loc" "$probe/sshd-probe" >/dev/null 2>&1; then has_ssh=yes; break; fi
        done
        if [ "$has_ssh" = yes ]; then
          oci_synthetic "$label" UNVERIFIED 5 'Alpine shell-less image has custom sshd binary; manual audit required'
        else
          oci_synthetic "$label" SAFE 0 "Alpine $alpine_release shell-less image: APK DB has no OpenSSH server and no standard sshd binary"
        fi
      fi
    else
      oci_synthetic "$label" UNVERIFIED 5 "Alpine $alpine_release image without /bin/sh: APK installed database unavailable"
    fi
  elif [ -n "$os_id" ]; then
    oci_synthetic "$label" SKIP 0 "Shell-less image identified as $os_id (not Alpine); no Alpine OpenSSH patch needed"
  else
    oci_synthetic "$label" UNVERIFIED 5 'No /bin/sh and OS identity unavailable; cannot prove absence of OpenSSH, manual review needed'
  fi
}

scan_oci() {
  engine=$1
  if ! command -v "$engine" >/dev/null 2>&1; then
    engine_record "$engine" NOT_INSTALLED 'CLI not found; no containers scanned'
    return
  fi
  ids="$WORK/$engine.ids"
  if ! "$engine" ps --no-trunc --format '{{.ID}}' > "$ids" 2> "$WORK/$engine.err"; then
    msg=$(head -n 1 "$WORK/$engine.err")
    engine_record "$engine" ERROR 'Cannot list containers'
    record_failure "$engine" '(discovery)' "ps failed: $msg"
    return
  fi
  count=$(grep -c . "$ids" || true)
  engine_record "$engine" SCANNED "running_at_discovery=$count (root-visible only)"
  image_update_needed=no
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    name=$("$engine" inspect -f '{{.Name}}' "$id" 2>/dev/null | head -n 1)
    [ -n "$name" ] || name=$id
    label="$engine:$name"
    state=$(oci_running "$engine" "$id")
    if [ "$state" = false ]; then
      oci_synthetic "$label" SKIP 0 'Container stopped during discovery; no exec performed'
      continue
    fi
    if [ "$state" != true ]; then
      oci_synthetic "$label" UNVERIFIED 5 'Cannot confirm container running state; no exec performed'
      continue
    fi
    guest_script | "$engine" exec -u 0 -i "$id" /bin/sh -s -- "$ACTION" "$RELOAD" "$ALLOW_OPENRC_RESTART" > "$WORK/guest-result" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && ! grep -q '^SSHH_RESULT=' "$WORK/guest-result"; then
      # OCI daemon may report a stopped state after ps -- inspect it again.
      state=$(oci_running "$engine" "$id")
      if [ "$state" = false ]; then
        oci_synthetic "$label" SKIP 0 'Container stopped between discovery and exec; no vulnerability verdict'
      elif grep -Eiq '(/bin/sh.*(no such file|not found)|executable file not found.*(/bin/sh|sh)|stat /bin/sh)' "$WORK/guest-result"; then
        oci_probe_no_shell "$engine" "$id" "$label"
      else
        show_result "$label" "$WORK/guest-result" "$rc"
      fi
    else
      show_result "$label" "$WORK/guest-result" "$rc"
    fi
    if grep -qx 'SSHH_PACKAGE_UPDATED=yes' "$WORK/guest-result"; then
      image_update_needed=yes
    fi
  done < "$ids"
  if [ "$image_update_needed" = yes ]; then
    say "[WARN] $engine: OpenSSH updated in running container(s); update original images/Dockerfiles before re-create or redeploy."
  fi
}

# Incus/LXD: CLI's column "t" means PERSISTENT/EPHEMERAL, NOT container/VM!
# Prefer type=container status=running server-side filters with all-projects.
# Fallback to per-project listing for older management clients.
scan_incus_like() {
  engine=$1
  if ! command -v "$engine" >/dev/null 2>&1; then
    engine_record "$engine" NOT_INSTALLED 'CLI not found; no instances scanned'
    return
  fi
  items="$WORK/$engine.items"
  if "$engine" list --all-projects type=container status=running --columns nse --format csv,noheader > "$items" 2> "$WORK/$engine.err"; then
    count=0
    while IFS=, read -r name state project rest || [ -n "$name" ]; do
      [ -n "$name" ] || continue
      state_u=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
      [ "$state_u" = RUNNING ] || {
        record_failure "$engine" "(discovery:$name)" "unexpected instance state in CSV: $state"
        continue
      }
      [ -n "$project" ] || {
        record_failure "$engine" "(discovery:$name)" 'missing project in all-project CSV'
        continue
      }
      count=$((count+1))
      run_target "$engine:$project/$name" "$engine" exec --project "$project" "$name" -- /bin/sh -s -- "$ACTION" "$RELOAD" "$ALLOW_OPENRC_RESTART"
    done < "$items"
    engine_record "$engine" SCANNED "all-projects; running containers=$count"
    return
  fi
  say "[WARN] $engine --all-projects failed: $(head -n 1 "$WORK/$engine.err"); trying per-project enumeration"
  projects="$WORK/$engine.projects"
  if ! "$engine" project list --columns n --format csv,noheader > "$projects" 2> "$WORK/$engine.err"; then
    msg=$(head -n 1 "$WORK/$engine.err")
    engine_record "$engine" ERROR 'All-project and project-list discovery failed'
    record_failure "$engine" '(discovery)' "project list failed: $msg"
    return
  fi
  count=0
  projects_total=0
  failed_projects=0
  while IFS= read -r project || [ -n "$project" ]; do
    [ -n "$project" ] || continue
    projects_total=$((projects_total+1))
    items="$WORK/$engine.$projects_total.items"
    if ! "$engine" list --project "$project" type=container status=running --columns ns --format csv,noheader > "$items" 2> "$WORK/$engine.err"; then
      failed_projects=$((failed_projects+1))
      record_failure "$engine" "project:$project" "instance list failed: $(head -n 1 "$WORK/$engine.err")"
      continue
    fi
    while IFS=, read -r name state rest || [ -n "$name" ]; do
      [ -n "$name" ] || continue
      state_u=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
      [ "$state_u" = RUNNING ] || {
        record_failure "$engine" "project:$project/$name" "unexpected instance state: $state"
        continue
      }
      count=$((count+1))
      run_target "$engine:$project/$name" "$engine" exec --project "$project" "$name" -- /bin/sh -s -- "$ACTION" "$RELOAD" "$ALLOW_OPENRC_RESTART"
    done < "$items"
  done < "$projects"
  if [ "$projects_total" -eq 0 ]; then
    record_failure "$engine" '(discovery)' 'project enumeration returned no projects; cannot assert full coverage'
  fi
  if [ "$failed_projects" -gt 0 ]; then
    engine_record "$engine" PARTIAL "projects=$projects_total failed=$failed_projects running_containers=$count"
  else
    engine_record "$engine" SCANNED "projects=$projects_total running_containers=$count"
  fi
}

scan_runman() {
  if ! command -v runman-agent >/dev/null 2>&1; then
    engine_record runman NOT_INSTALLED 'Rust Runman v2 CLI not found'
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    engine_record runman ERROR 'systemctl missing; unable to inspect Runman runtime'
    record_failure runman '(discovery)' 'systemctl missing'
    return
  fi
  if [ -n "$RUNMAN_DATA_DIR" ]; then
    dir=$RUNMAN_DATA_DIR
  else
    dir=/var/lib/runman-agent
    conf=/etc/runman-agent/config.toml
    if [ -r "$conf" ]; then
      # Toml string-valued data_dir, from Runman v2 config only. No shell evaluation.
      found=$(sed -n 's/^[[:space:]]*data_dir[[:space:]]*=[[:space:]]*"\([^"[:cntrl:]]*\)".*/\1/p' "$conf" | head -n 1)
      [ -z "$found" ] || dir=$found
    fi
  fi
  case "$dir" in
    /*) ;; *) engine_record runman ERROR 'Invalid Runman data_dir'; record_failure runman '(discovery)' "invalid data_dir=$dir"; return ;;
  esac
  [ -d "$dir/instances" ] || { engine_record runman NO_INSTANCES 'Rust Runman v2 instance directory missing'; return; }
  say "[INFO] Rust Runman v2 persistent dir=$dir; using native __exec (not SSH)"
  count=0
  image_update_needed=no
  for item in "$dir"/instances/*; do
    [ -d "$item" ] && [ -f "$item/instance.json" ] || continue
    id=${item##*/}
    # Only canonical UUID pattern; fail closed on unexpected paths.
    if ! printf '%s\n' "$id" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
      continue
    fi
    unit="runman-$id.service"
    systemctl is-active --quiet "$unit" 2>/dev/null || continue
    pidfile="/run/runman-agent/$id/init.pid"
    [ -r "$pidfile" ] || { record_failure runman "$id" 'unit active but init.pid missing'; continue; }
    pid=$(cat "$pidfile" 2>/dev/null | tr -d '[:space:]')
    case "$pid" in ''|*[!0-9]*) record_failure runman "$id" 'invalid Runman PID'; continue ;; esac
    [ -r "/proc/$pid/cgroup" ] || { record_failure runman "$id" 'cannot read Runman init cgroup'; continue; }
    if ! grep -Fq "$unit" "/proc/$pid/cgroup"; then
      record_failure runman "$id" 'init PID not in expected cgroup'; continue
    fi
    count=$((count+1))
    cg="/sys/fs/cgroup/system.slice/$unit"
    [ -d "$cg" ] || { record_failure runman "$id" 'unit cgroup path missing'; continue; }
    run_target "runman:$id" runman-agent __exec "$pidfile" "$cg" -- /bin/sh -s -- "$ACTION" "$RELOAD" "$ALLOW_OPENRC_RESTART"
    if grep -qx 'SSHH_PACKAGE_UPDATED=yes' "$WORK/guest-result"; then
      image_update_needed=yes
    fi
  done
  engine_record runman SCANNED "running_records=$count (native __exec)"
  if [ "$image_update_needed" = yes ]; then
    say '[WARN] Runman: OpenSSH was upgraded in existing guest(s). Refresh Alpine base images before new VPS/reinstall.'
  fi
}

render_row() {
  row_engine=$1; row_target=$2; row_os=$3; row_state=$4; row_reason=$5
  # Bound display length only; full original content remains in plain logfile.
  case "$row_state" in
    SAFE|OK|'FIXED(OK)') col='\033[1;32m' ;;
    RISK|FAIL) col='\033[1;31m' ;;
    PENDING|UNVERIFIED) col='\033[1;33m' ;;
    SKIP) col='\033[0;90m' ;;
    *) col='\033[0m' ;;
  esac
  # Print ANSI only around status field and only when colors are enabled.
  printf '%-8.8s | %-45.45s | %-15.15s | ' "$row_engine" "$row_target" "$row_os"
  if [ "$COLOR_ON" = yes ]; then printf "$col"; fi
  printf '%-11.11s' "$row_state"
  if [ "$COLOR_ON" = yes ]; then printf '\033[0m'; fi
  printf ' | %.70s\n' "$row_reason"
  printf '%-8.8s | %-45.45s | %-15.15s | %-11.11s | %.70s\n' "$row_engine" "$row_target" "$row_os" "$row_state" "$row_reason" >> "$LOG_FILE"
}

render_summary() {
  say ''
  say '============================ CONTAINER MANAGERS ============================'
  while IFS="$TAB" read -r mgr st notes || [ -n "$mgr" ]; do
    [ -n "$mgr" ] || continue
    printf '%-9.9s | %-14.14s | %s\n' "$mgr" "$st" "$notes"
  done < "$ENGINES_FILE"
  say ''
  say '================================ RESULTS =================================='
  say 'ENGINE   | TARGET                                        | OS              | STATUS      | DETAILS'
  say '---------+-----------------------------------------------+-----------------+-------------+--------------------------------'
  while IFS="$TAB" read -r mgr target os st notes || [ -n "$mgr" ]; do
    [ -n "$mgr" ] || continue
    render_row "$mgr" "$target" "$os" "$st" "$notes"
  done < "$RESULTS_FILE"
  say '---------------------------------------------------------------------------'
  say "SUMMARY total=$SUMMARY_TOTAL safe=$SUMMARY_SAFE ok=$SUMMARY_OK fixed=$SUMMARY_FIXED vulnerable=$SUMMARY_RISK pending_reload=$SUMMARY_PENDING unverified=$SUMMARY_UNVERIFIED skipped=$SUMMARY_SKIP failed=$SUMMARY_FAIL"
  if [ "$SUMMARY_FAIL" -gt 0 ]; then
    outcome='INCOMPLETE / CHECK FAILED'
    color='\033[1;31m'
  elif [ "$SUMMARY_RISK" -gt 0 ]; then
    outcome='VULNERABLE INSTANCES FOUND'
    color='\033[1;31m'
  elif [ "$SUMMARY_PENDING" -gt 0 ]; then
    outcome='PATCHED BUT RELOAD PENDING'
    color='\033[1;33m'
  elif [ "$SUMMARY_UNVERIFIED" -gt 0 ]; then
    outcome='INCOMPLETE / UNVERIFIED CONTAINERS'
    color='\033[1;33m'
  else
    outcome='NO KNOWN VULNERABILITY FOUND IN SCANNED TARGETS'
    color='\033[1;32m'
  fi
  if [ "$COLOR_ON" = yes ]; then printf "$color"; fi
  printf 'OVERALL: %s\n' "$outcome"
  if [ "$COLOR_ON" = yes ]; then printf '\033[0m'; fi
  printf 'OVERALL: %s\n' "$outcome" >> "$LOG_FILE"
  say 'NOTE: Rootless Podman of other users and stopped instances are not scanned.'
  say "Host log: $LOG_FILE"
}

say "SSHhole All-in-One v1.6 | action=$ACTION scope=$SCOPE engine=$ENGINE reload=$RELOAD color=$COLOR_MODE openrc_restart=$ALLOW_OPENRC_RESTART"
say "Host OS: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
say 'Policy: never change SSH auth/port/password/key config; no VM restart; no image rebuild.'
if [ "$ACTION" = fix ]; then say '[AUTO-FIX] Vulnerable Alpine OpenSSH will be upgraded in place; already-safe targets left unchanged.'; fi
if [ "$SCOPE" = all ] || [ "$SCOPE" = host ]; then
  run_target 'host' /bin/sh -s -- "$ACTION" "$RELOAD" "$ALLOW_OPENRC_RESTART"
fi
if [ "$SCOPE" = all ] || [ "$SCOPE" = containers ]; then
  if want_engine docker; then scan_oci docker; fi
  if want_engine podman; then scan_oci podman; fi
  if want_engine incus; then scan_incus_like incus; fi
  if want_engine lxd; then scan_incus_like lxc; fi
  if want_engine runman; then scan_runman; fi
fi
render_summary
if [ "$SUMMARY_FAIL" -gt 0 ] || [ "$SUMMARY_UNVERIFIED" -gt 0 ]; then exit 2; fi
if [ "$SUMMARY_RISK" -gt 0 ] || [ "$SUMMARY_PENDING" -gt 0 ]; then exit 3; fi
exit 0
