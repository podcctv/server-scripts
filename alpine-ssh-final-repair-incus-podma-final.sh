#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Alpine SSH Final Repair for Incus + Podman
#
# 适用场景：
#   - 同一宿主机只有 Incus
#   - 同一宿主机只有 Podman（rootful）
#   - 同一宿主机同时运行 Incus + Podman
#
# Incus：
#   - 批量修复 Alpine system containers
#   - DNS 异常自动处理
#   - 宿主机 PID/netns 精确清理残留 sshd listener
#   - 恢复 Alpine 原生 OpenRC sshd
#   - 严格验证 OpenRC/PID/socket owner/SSH 配置/runlevel
#   - 自动修复 alpine/*/cloud/{amd64,arm64}/ready 模板
#   - 修复 cloud-init ssh_pwauth/disable_root
#   - first boot 等 cloud-init 完成后验证，失败自动回滚模板 alias
#
# Podman：
#   - 扫描 rootful Podman Alpine containers
#   - 自动识别三种运行模式：
#       1) PID1/Entrypoint 为 sshd：修改配置后重启整个容器
#       2) OpenRC system-container：由 Alpine 原生 rc-service sshd 接管
#       3) 普通 application container：只修当前运行态 sshd，不修改 CMD/Entrypoint
#   - 不自动 podman commit，不修改 Podman image，避免不可逆污染应用镜像
#
# 安全原则：
#   - 只有确认 :22 owner 是 sshd 且属于目标容器 netns 才会从宿主机 kill
#   - owner 属于宿主机 netns 或非 sshd 时拒绝自动处理
#   - 不设置统一 root 密码
#
# 默认：
#   FIX_INCUS_CONTAINERS=1
#   FIX_INCUS_TEMPLATES=1
#   FIX_PODMAN_CONTAINERS=1
#
# 示例：
#   ./alpine-ssh-final-repair.sh
#   FIX_INCUS_TEMPLATES=0 ./alpine-ssh-final-repair.sh
#   FIX_INCUS_CONTAINERS=0 FIX_PODMAN_CONTAINERS=0 ./alpine-ssh-final-repair.sh
# =============================================================================

FIX_INCUS_CONTAINERS="${FIX_INCUS_CONTAINERS:-1}"
FIX_INCUS_TEMPLATES="${FIX_INCUS_TEMPLATES:-1}"
FIX_PODMAN_CONTAINERS="${FIX_PODMAN_CONTAINERS:-1}"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="/root/alpine-ssh-final-repair-${TS}.log"

exec > >(tee -a "$LOG") 2>&1

say(){ printf '\n%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "请使用 root 执行。Podman 部分默认处理 rootful Podman 容器。"
    exit 1
fi

for cmd in awk sed grep readlink; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "缺少基础命令：$cmd"
        exit 1
    fi
done

HAS_INCUS=0
HAS_PODMAN=0

command -v incus >/dev/null 2>&1 && HAS_INCUS=1
command -v podman >/dev/null 2>&1 && HAS_PODMAN=1

if [ "$HAS_INCUS" -eq 0 ] && [ "$HAS_PODMAN" -eq 0 ]; then
    fail "未检测到 Incus 或 Podman。"
    exit 1
fi

# 宿主机 namespace/socket 检查需要这两个命令。
if { [ "$HAS_INCUS" -eq 1 ] && { [ "$FIX_INCUS_CONTAINERS" -eq 1 ] || [ "$FIX_INCUS_TEMPLATES" -eq 1 ]; }; } ||
   { [ "$HAS_PODMAN" -eq 1 ] && [ "$FIX_PODMAN_CONTAINERS" -eq 1 ]; }
then
    for cmd in nsenter ss; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fail "缺少命令：$cmd（通常由 util-linux/iproute2 提供）"
            exit 1
        fi
    done
fi

say "运行环境"
echo "Incus  : $([ "$HAS_INCUS" -eq 1 ] && echo YES || echo NO)"
echo "Podman : $([ "$HAS_PODMAN" -eq 1 ] && echo YES || echo NO)"
echo "日志   : $LOG"

# Incus 原脚本内部变量兼容层
FIX_CONTAINERS="$FIX_INCUS_CONTAINERS"
FIX_TEMPLATES="$FIX_INCUS_TEMPLATES"

# ------------------------------------------------------------
# Incus 安全停止
#
# incus stop 的 --timeout 默认是 -1（无限等待）。
# 先给容器短暂 clean shutdown 时间；失败/超时后强制 stop。
# 外层再用 coreutils timeout（若存在）防止客户端/operation 异常卡住。
# ------------------------------------------------------------

incus_stop_safe(){
    local ct="$1"
    local grace="${2:-10}"
    local hard_wait=$((grace + 15))

    # 已经不是 RUNNING 时直接成功
    local state
    state="$(
        incus info "$ct" 2>/dev/null |
        awk '/^Status:/ {print $2; exit}'
    )"

    if [ -n "$state" ] && [ "$state" != "RUNNING" ]; then
        return 0
    fi

    if command -v timeout >/dev/null 2>&1; then
        if timeout "${hard_wait}s" \
            incus stop "$ct" --timeout "$grace" \
            >/dev/null 2>&1
        then
            return 0
        fi
    else
        if incus stop "$ct" --timeout "$grace" \
            >/dev/null 2>&1
        then
            return 0
        fi
    fi

    warn "$ct 正常 shutdown 超时，改用强制停止"

    if command -v timeout >/dev/null 2>&1; then
        timeout 20s \
            incus stop "$ct" --force \
            >/dev/null 2>&1 || true
    else
        incus stop "$ct" --force \
            >/dev/null 2>&1 || true
    fi

    state="$(
        incus info "$ct" 2>/dev/null |
        awk '/^Status:/ {print $2; exit}'
    )"

    if [ "$state" = "STOPPED" ]; then
        return 0
    fi

    fail "$ct 强制停止后状态仍为：${state:-UNKNOWN}"
    return 1
}

wait_exec(){
    local ct="$1"
    local i

    for i in $(seq 1 40); do
        if incus exec "$ct" -- true </dev/null >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    return 1
}

is_alpine(){
    incus exec "$1" -- test -f /etc/alpine-release \
        </dev/null >/dev/null 2>&1
}

get_init_pid(){
    incus list "$1" --format csv -c p 2>/dev/null | head -n1
}

# ------------------------------------------------------------
# DNS
# DNS 正常时完全不修改；失败才尝试 DHCP + DNS 兜底
# ------------------------------------------------------------

repair_dns(){
    local ct="$1"

    incus exec "$ct" -- sh -s </dev/null <<'INNER'
set +e

TEST_HOST="dl-cdn.alpinelinux.org"

check_dns(){
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$TEST_HOST" >/dev/null 2>&1
    else
        ping -c 1 -W 3 "$TEST_HOST" >/dev/null 2>&1
    fi
}

if check_dns; then
    echo "DNS_STATUS=OK"
    exit 0
fi

echo "DNS_STATUS=FAILED_BEFORE_FIX"

ip link set eth0 up >/dev/null 2>&1 || true

if command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i eth0 -q -n -t 5 >/dev/null 2>&1 || true
fi

if check_dns; then
    echo "DNS_STATUS=FIXED_BY_DHCP"
    exit 0
fi

GW="$(
    ip -4 route 2>/dev/null |
    awk '/^default / {print $3; exit}'
)"

if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
    cp -L \
        /etc/resolv.conf \
        /etc/resolv.conf.before-incus-final-repair \
        2>/dev/null || true
fi

{
    [ -n "$GW" ] && echo "nameserver $GW"
    echo "nameserver 1.1.1.1"
    echo "nameserver 8.8.8.8"
    echo "options timeout:2 attempts:2"
} >/etc/resolv.conf

if check_dns; then
    echo "DNS_STATUS=FIXED"
    exit 0
fi

echo "DNS_STATUS=FAILED_AFTER_FIX"
echo "--- resolv.conf ---"
cat /etc/resolv.conf 2>/dev/null || true
echo "--- IPv4 route ---"
ip -4 route 2>/dev/null || true

exit 2
INNER
}

# ------------------------------------------------------------
# 如果机器上跑过早期测试版，恢复 Alpine 原生 sshd init
# 新机器没有备份时保持原生文件不动
# ------------------------------------------------------------

restore_native_sshd_init(){
    local ct="$1"

    incus exec "$ct" -- sh -s </dev/null <<'INNER'
set +e

if [ -f /etc/init.d/sshd.original-alpine ]; then
    cp -af /etc/init.d/sshd.original-alpine /etc/init.d/sshd
    chmod +x /etc/init.d/sshd
    echo "SSHD_INIT=RESTORED"
else
    echo "SSHD_INIT=NATIVE"
fi

# 清理早期测试版可能创建的自定义 HostKey 服务
rc-update del ssh-hostkeys default >/dev/null 2>&1 || true

rm -f \
    /etc/init.d/ssh-hostkeys \
    /etc/runlevels/default/ssh-hostkeys \
    2>/dev/null || true
INNER
}

# ------------------------------------------------------------
# 现有容器：完整重建 SSH 配置
# 不叠加旧 Include / drop-in，避免重复 Port 和认证冲突
# ------------------------------------------------------------

rebuild_container_sshd_config(){
    local ct="$1"

    incus exec "$ct" -- sh -s </dev/null <<'INNER'
set -e

STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p \
    /root/incus-ssh-backup \
    /etc/ssh \
    /run/sshd

if ! command -v sshd >/dev/null 2>&1; then
    apk add --no-cache openssh >/dev/null
fi

if [ -f /etc/ssh/sshd_config ]; then
    cp -a \
        /etc/ssh/sshd_config \
        "/root/incus-ssh-backup/sshd_config.${STAMP}"
fi

if [ -d /etc/ssh/sshd_config.d ]; then
    cp -a \
        /etc/ssh/sshd_config.d \
        "/root/incus-ssh-backup/sshd_config.d.${STAMP}" \
        2>/dev/null || true
fi

cat >/etc/ssh/sshd_config <<'CONF'
Port 22
PidFile /run/sshd.pid

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key

PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
UseDNS no

Subsystem sftp internal-sftp
CONF

ssh-keygen -A >/dev/null 2>&1 || true

/usr/sbin/sshd -t

ROOT_FIELD="$(
    awk -F: '$1=="root"{print $2}' /etc/shadow
)"

# 已有密码 hash 只是被 ! 锁定时尝试解锁；
# 纯 ! / !! / * 不自动生成新密码。
case "$ROOT_FIELD" in
    '!$'*)
        passwd -u root >/dev/null 2>&1 || true
        ;;
    '!'*)
        if [ "$ROOT_FIELD" != "!" ] &&
           [ "$ROOT_FIELD" != "!!" ] &&
           [ "${#ROOT_FIELD}" -gt 10 ]
        then
            passwd -u root >/dev/null 2>&1 || true
        fi
        ;;
esac

ROOT_FIELD="$(
    awk -F: '$1=="root"{print $2}' /etc/shadow
)"

case "$ROOT_FIELD" in
    ""|"!"|"!!"|"*")
        echo "ROOT_PASSWORD_STATUS=NEED_PASSWORD"
        ;;
    '!'*)
        echo "ROOT_PASSWORD_STATUS=LOCKED"
        ;;
    *)
        echo "ROOT_PASSWORD_STATUS=OK"
        ;;
esac

/usr/sbin/sshd \
    -T \
    -C user=root,host=localhost,addr=127.0.0.1 \
    2>/dev/null |
grep -E \
'^(port|pidfile|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) '
INNER
}

# ------------------------------------------------------------
# 宿主机 network namespace 中检查 22
# ------------------------------------------------------------

port22_listening(){
    local initpid="$1"

    nsenter \
        -t "$initpid" \
        -n \
        ss -lntH \
        2>/dev/null |
    grep -qE '(:22[[:space:]]|\]:22[[:space:]])'
}

# ------------------------------------------------------------
# 找到目标 netns 的 :22 对应宿主机真实 PID
# ------------------------------------------------------------

find_port22_owners(){
    local initpid="$1"
    local owners
    local inodes
    local inode
    local fd
    local link
    local pid

    owners="$(
        nsenter \
            -t "$initpid" \
            -n \
            ss -lntpH \
            2>/dev/null |
        grep -E '(:22[[:space:]]|\]:22[[:space:]])' |
        grep -oE 'pid=[0-9]+' |
        cut -d= -f2 |
        sort -nu
    )"

    if [ -n "$owners" ]; then
        printf '%s\n' "$owners"
        return 0
    fi

    # ss 未直接给 PID 时，从 socket inode 反查宿主机 /proc
    inodes="$(
        nsenter \
            -t "$initpid" \
            -n \
            ss -lntpeH \
            2>/dev/null |
        grep -E '(:22[[:space:]]|\]:22[[:space:]])' |
        sed -n 's/.*ino:\([0-9][0-9]*\).*/\1/p' |
        sort -u
    )"

    for inode in $inodes; do
        for fd in /proc/[0-9]*/fd/*; do
            # socket FD 是符号链接，必须用 -L，不能用 -e
            [ -L "$fd" ] || continue

            link="$(readlink "$fd" 2>/dev/null || true)"
            [ "$link" = "socket:[$inode]" ] || continue

            pid="$(printf '%s\n' "$fd" | cut -d/ -f3)"

            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                echo "$pid"
            fi
        done
    done | sort -nu
}

# ------------------------------------------------------------
# 安全释放目标容器残留 sshd listener
#
# 自动 kill 之前同时要求：
#   - owner 是 sshd
#   - owner netns == 目标容器 netns
#   - owner netns != 宿主机 netns
# 非 sshd 占用 22 时绝不自动 kill。
# ------------------------------------------------------------

release_old_sshd(){
    local ct="$1"
    local initpid="$2"

    local ct_net
    local host_net
    local owner
    local comm
    local exe
    local owner_net
    local owners=()

    ct_net="$(readlink "/proc/$initpid/ns/net" 2>/dev/null || true)"
    host_net="$(readlink /proc/1/ns/net 2>/dev/null || true)"

    if [ -z "$ct_net" ]; then
        fail "$ct 无法获取 network namespace"
        return 1
    fi

    # 先尝试正常停止
    incus exec "$ct" -- \
        rc-service sshd stop \
        </dev/null \
        >/dev/null 2>&1 || true

    sleep 1

    if ! port22_listening "$initpid"; then
        ok "$ct :22 已释放"
        return 0
    fi

    mapfile -t owners < <(
        find_port22_owners "$initpid"
    )

    if [ "${#owners[@]}" -eq 0 ]; then
        fail "$ct :22 在监听，但无法定位宿主 PID"
        return 2
    fi

    # 先验证所有 owner，确认安全后再结束
    for owner in "${owners[@]}"; do
        [ -d "/proc/$owner" ] || continue

        comm="$(cat "/proc/$owner/comm" 2>/dev/null || true)"
        exe="$(readlink "/proc/$owner/exe" 2>/dev/null || true)"
        owner_net="$(readlink "/proc/$owner/ns/net" 2>/dev/null || true)"

        echo "旧 listener: host_pid=$owner comm=$comm exe=$exe netns=$owner_net"

        if [ "$comm" != "sshd" ]; then
            fail "$ct :22 被非 sshd 程序占用：PID=$owner COMM=$comm"
            return 3
        fi

        if [ "$owner_net" != "$ct_net" ]; then
            fail "$ct listener PID=$owner 不属于目标容器 netns"
            return 4
        fi

        if [ "$owner_net" = "$host_net" ]; then
            fail "$ct listener PID=$owner 属于宿主机，拒绝操作"
            return 5
        fi
    done

    for owner in "${owners[@]}"; do
        [ -d "/proc/$owner" ] || continue
        echo "TERM host sshd PID=$owner"
        kill -TERM "$owner" 2>/dev/null || true
    done

    sleep 2

    for owner in "${owners[@]}"; do
        if [ -d "/proc/$owner" ]; then
            echo "KILL host sshd PID=$owner"
            kill -KILL "$owner" 2>/dev/null || true
        fi
    done

    sleep 1

    if port22_listening "$initpid"; then
        fail "$ct 宿主机清理后 :22 仍在监听"

        nsenter \
            -t "$initpid" \
            -n \
            ss -lntpe \
            2>/dev/null |
        grep -E '(:22[[:space:]]|\]:22[[:space:]])' || true

        return 6
    fi

    ok "$ct 旧 sshd listener 已彻底释放"
    return 0
}

# ------------------------------------------------------------
# 让 Alpine 原生 OpenRC 接管 sshd
# ------------------------------------------------------------

start_native_sshd(){
    local ct="$1"

    incus exec "$ct" -- sh -s </dev/null <<'INNER'
set -e

rm -f \
    /run/sshd.pid \
    /var/run/sshd.pid \
    2>/dev/null || true

mkdir -p /run/sshd

rc-service sshd zap >/dev/null 2>&1 || true
rc-update add sshd default >/dev/null 2>&1 || true

ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd -t

rc-service sshd start

sleep 1
INNER
}

# ------------------------------------------------------------
# 严格验证现有容器 SSH
# ------------------------------------------------------------

verify_sshd(){
    local ct="$1"
    local initpid="$2"

    local out
    local port_count
    local root_auth
    local pass_auth
    local ct_net
    local p

    local rc_ok=0
    local pid_ok=0
    local port_ok=0
    local owner_ok=0
    local config_ok=0
    local runlevel_ok=0

    local vpids=()

    # 1. OpenRC started
    if incus exec "$ct" -- \
        rc-service sshd status \
        </dev/null \
        >/dev/null 2>&1
    then
        rc_ok=1
    fi

    # 2. /run/sshd.pid 必须指向容器内真实 sshd
    if incus exec "$ct" -- sh -c '
        PID=$(cat /run/sshd.pid 2>/dev/null)
        [ -n "$PID" ] &&
        [ -d "/proc/$PID" ] &&
        [ "$(cat "/proc/$PID/comm" 2>/dev/null)" = "sshd" ]
    ' </dev/null >/dev/null 2>&1
    then
        pid_ok=1
    fi

    # 3. :22 实际监听
    if port22_listening "$initpid"; then
        port_ok=1
    fi

    # 4. :22 宿主机真实 owner 属于目标容器 sshd
    mapfile -t vpids < <(
        find_port22_owners "$initpid"
    )

    if [ "${#vpids[@]}" -gt 0 ]; then
        owner_ok=1
        ct_net="$(readlink "/proc/$initpid/ns/net" 2>/dev/null || true)"

        for p in "${vpids[@]}"; do
            if [ ! -d "/proc/$p" ]; then
                owner_ok=0
                break
            fi

            if [ "$(cat "/proc/$p/comm" 2>/dev/null || true)" != "sshd" ]; then
                owner_ok=0
                break
            fi

            if [ "$(readlink "/proc/$p/ns/net" 2>/dev/null || true)" != "$ct_net" ]; then
                owner_ok=0
                break
            fi
        done
    fi

    # 5. 有效 SSH 配置
    out="$(
        incus exec "$ct" -- \
            /usr/sbin/sshd \
            -T \
            -C user=root,host=localhost,addr=127.0.0.1 \
            </dev/null \
            2>/dev/null || true
    )"

    port_count="$(printf '%s\n' "$out" | grep -c '^port 22$')"

    root_auth="$(
        printf '%s\n' "$out" |
        awk '$1=="permitrootlogin" {print $2; exit}'
    )"

    pass_auth="$(
        printf '%s\n' "$out" |
        awk '$1=="passwordauthentication" {print $2; exit}'
    )"

    if [ "$port_count" -eq 1 ] &&
       [ "$root_auth" = "yes" ] &&
       [ "$pass_auth" = "yes" ]
    then
        config_ok=1
    fi

    # 6. default runlevel
    # 直接检查 OpenRC runlevel 文件，不解析 rc-update show 的格式化文本。
    if incus exec "$ct" -- sh -c '
        [ -L /etc/runlevels/default/sshd ] ||
        [ -e /etc/runlevels/default/sshd ]
    ' </dev/null >/dev/null 2>&1
    then
        runlevel_ok=1
    fi

    echo "OPENRC_OK=$rc_ok"
    echo "PIDFILE_OK=$pid_ok"
    echo "PORT22_OK=$port_ok"
    echo "OWNER_OK=$owner_ok"
    echo "PORT_COUNT=$port_count"
    echo "PERMIT_ROOT_LOGIN=$root_auth"
    echo "PASSWORD_AUTH=$pass_auth"
    echo "RUNLEVEL_OK=$runlevel_ok"

    if [ "$rc_ok" -eq 1 ] &&
       [ "$pid_ok" -eq 1 ] &&
       [ "$port_ok" -eq 1 ] &&
       [ "$owner_ok" -eq 1 ] &&
       [ "$config_ok" -eq 1 ] &&
       [ "$runlevel_ok" -eq 1 ]
    then
        echo "RESULT=OK"
        return 0
    fi

    echo "RESULT=FAILED"
    return 1
}

# ============================================================
# 模板网络
# ============================================================

get_ref_nic(){
    local ct="$1"

    incus config show "$ct" --expanded 2>/dev/null |
    awk '
    BEGIN {
        indev=0
        dev=""
        name=""
        network=""
        parent=""
        nictype=""
        type=""
    }

    /^devices:/ {
        indev=1
        next
    }

    indev && /^[^ ]/ {
        indev=0
    }

    indev && /^  [^ ].*:$/ {
        if (dev!="" && type=="nic") {
            print dev "|" name "|" network "|" parent "|" nictype
            exit
        }

        dev=$0
        sub(/^  /,"",dev)
        sub(/:$/,"",dev)

        name=""
        network=""
        parent=""
        nictype=""
        type=""
        next
    }

    indev && /^    [A-Za-z0-9_.-]+:/ {
        line=$0
        sub(/^    /,"",line)

        key=line
        sub(/:.*/,"",key)

        val=line
        sub(/^[^:]*:[ ]*/,"",val)
        gsub(/^"|"$/,"",val)

        if (key=="name")
            name=val
        else if (key=="network")
            network=val
        else if (key=="parent")
            parent=val
        else if (key=="nictype")
            nictype=val
        else if (key=="type")
            type=val
    }

    END {
        if (dev!="" && type=="nic")
            print dev "|" name "|" network "|" parent "|" nictype
    }'
}

REF_CT=""
REF_NAME="eth0"
REF_NETWORK=""
REF_PARENT=""
REF_NICTYPE="bridged"

find_reference_nic(){
    local ct
    local line

    for ct in "${ALL_CTS[@]}"; do
        line="$(get_ref_nic "$ct" | head -n1)"
        [ -n "$line" ] || continue

        IFS='|' read -r \
            _DEV \
            REF_NAME \
            REF_NETWORK \
            REF_PARENT \
            REF_NICTYPE \
            <<<"$line"

        REF_CT="$ct"
        [ -n "$REF_NAME" ] || REF_NAME="eth0"
        [ -n "$REF_NICTYPE" ] || REF_NICTYPE="bridged"

        return 0
    done

    # 没有实例可参考时，尝试第一块 Incus managed bridge
    REF_NETWORK="$(
        incus network list --format csv 2>/dev/null |
        awk -F, 'tolower($2)=="bridge" {print $1; exit}'
    )"

    if [ -n "$REF_NETWORK" ]; then
        REF_CT="INCUS_NETWORK"
        return 0
    fi

    return 1
}

attach_reference_nic(){
    local ct="$1"

    # 若 default/profile 已经提供 NIC，就不重复添加
    if incus config show "$ct" --expanded 2>/dev/null |
       grep -q '^[[:space:]]*type: nic[[:space:]]*$'
    then
        return 0
    fi

    if [ -n "$REF_NETWORK" ]; then
        incus config device add \
            "$ct" \
            eth0 \
            nic \
            network="$REF_NETWORK" \
            name="$REF_NAME"
        return $?
    fi

    if [ -n "$REF_PARENT" ]; then
        incus config device add \
            "$ct" \
            eth0 \
            nic \
            nictype="$REF_NICTYPE" \
            parent="$REF_PARENT" \
            name="$REF_NAME"
        return $?
    fi

    return 1
}

# ============================================================
# Cloud 模板处理
# ============================================================

wait_cloud_init(){
    local ct="$1"
    local i
    local status

    # 非 cloud-init 镜像直接视为无需等待
    if ! incus exec "$ct" -- \
        command -v cloud-init \
        </dev/null >/dev/null 2>&1
    then
        echo "CLOUD_INIT=NOT_INSTALLED"
        return 0
    fi

    echo "等待 cloud-init 完成..."

    # 最长约 300 秒
    for i in $(seq 1 150); do

        if incus exec "$ct" -- \
            test -f /var/lib/cloud/instance/boot-finished \
            </dev/null >/dev/null 2>&1
        then
            echo "CLOUD_INIT_BOOT_FINISHED=1"
            return 0
        fi

        status="$(
            incus exec "$ct" -- \
                cloud-init status \
                </dev/null \
                2>/dev/null || true
        )"

        case "$status" in
            *"status: done"*)
                echo "CLOUD_INIT_STATUS=DONE"
                return 0
                ;;
            *"status: error"*)
                echo "CLOUD_INIT_STATUS=ERROR"
                return 2
                ;;
        esac

        sleep 2
    done

    echo "CLOUD_INIT_STATUS=TIMEOUT"
    return 1
}

cloud_diagnostics(){
    local ct="$1"

    echo
    echo "===== cloud-init status ====="
    incus exec "$ct" -- \
        cloud-init status --long \
        </dev/null 2>/dev/null || true

    echo
    echo "===== cloud/OpenRC services ====="
    incus exec "$ct" -- sh -c '
        rc-status -a 2>/dev/null |
        grep -Ei "cloud|network" || true
    ' </dev/null || true

    echo
    echo "===== cloud-init processes ====="
    incus exec "$ct" -- sh -c '
        ps 2>/dev/null |
        grep -E "[c]loud-init|[c]loud-config|[c]loud-final" || true
    ' </dev/null || true

    echo
    echo "===== cloud-init.log tail ====="
    incus exec "$ct" -- sh -c '
        tail -n 80 /var/log/cloud-init.log 2>/dev/null || true
    ' </dev/null || true

    echo
    echo "===== cloud-init-output.log tail ====="
    incus exec "$ct" -- sh -c '
        tail -n 80 /var/log/cloud-init-output.log 2>/dev/null || true
    ' </dev/null || true
}

image_fingerprint(){
    local alias="$1"

    incus image list "$alias" \
        --format csv \
        -c f \
        2>/dev/null |
    head -n1
}

rollback_image_alias(){
    local alias="$1"
    local old_fp="$2"

    [ -n "$old_fp" ] || return 1

    incus image alias delete "$alias" >/dev/null 2>&1 || true

    incus image alias create \
        "$alias" \
        "$old_fp" \
        >/dev/null 2>&1
}

prepare_cloud_template(){
    local ct="$1"

    # 先停 cloud-init 服务，避免 clean 过程中仍有进程写状态
    incus exec "$ct" -- sh -s </dev/null <<'INNER'
set +e

echo "TEMPLATE_STAGE=STOP_CLOUD_SERVICES"

for svc in \
    cloud-final \
    cloud-config \
    cloud-init \
    cloud-init-local
do
    # 某个 OpenRC service 状态异常也不能让模板流程永久卡住。
    if command -v timeout >/dev/null 2>&1; then
        timeout 8s rc-service "$svc" stop >/dev/null 2>&1 || true
    elif command -v busybox >/dev/null 2>&1; then
        busybox timeout 8 rc-service "$svc" stop >/dev/null 2>&1 || true
    else
        rc-service "$svc" stop >/dev/null 2>&1 || true
    fi
done

echo "TEMPLATE_STAGE=STOP_CLOUD_SERVICES_DONE"

sleep 1
INNER

    incus exec "$ct" -- sh -s </dev/null <<'INNER'
set -e

mkdir -p \
    /etc/cloud/cloud.cfg.d \
    /etc/ssh \
    /run/sshd

# ------------------------------------------------------------
# Cloud-init 默认策略
# ------------------------------------------------------------

if [ -f /etc/cloud/cloud.cfg ]; then

    if grep -qE '^[[:space:]]*ssh_pwauth:' /etc/cloud/cloud.cfg; then
        sed -i -E \
            's/^[[:space:]]*ssh_pwauth:.*/ssh_pwauth: true/' \
            /etc/cloud/cloud.cfg
    else
        printf '\nssh_pwauth: true\n' >>/etc/cloud/cloud.cfg
    fi

    if grep -qE '^[[:space:]]*disable_root:' /etc/cloud/cloud.cfg; then
        sed -i -E \
            's/^[[:space:]]*disable_root:.*/disable_root: false/' \
            /etc/cloud/cloud.cfg
    else
        printf 'disable_root: false\n' >>/etc/cloud/cloud.cfg
    fi
fi

# 最终 override，确保新实例首次 cloud-init 仍允许密码 SSH/root
cat >/etc/cloud/cloud.cfg.d/99-incus-ssh-password.cfg <<'CFG'
ssh_pwauth: true
disable_root: false
CFG

echo "CLOUD_CONFIG:"
grep -RniE \
    '^[[:space:]]*(ssh_pwauth|disable_root):' \
    /etc/cloud/cloud.cfg \
    /etc/cloud/cloud.cfg.d \
    2>/dev/null || true

# ------------------------------------------------------------
# SSH 基础配置
# ------------------------------------------------------------

if ! command -v sshd >/dev/null 2>&1; then
    apk add --no-cache openssh >/dev/null
fi

cat >/etc/ssh/sshd_config <<'SSH'
Port 22
PidFile /run/sshd.pid

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key

PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
UseDNS no

Subsystem sftp internal-sftp
SSH

ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd -t

echo "SSH_CONFIG_BEFORE_PUBLISH:"
/usr/sbin/sshd \
    -T \
    -C user=root,host=localhost,addr=127.0.0.1 \
    2>/dev/null |
grep -E '^(port|permitrootlogin|passwordauthentication|pidfile) '

# ------------------------------------------------------------
# OpenRC
# ------------------------------------------------------------

echo "TEMPLATE_STAGE=OPENRC_RUNLEVEL"

# 模板构建容器马上会整体停止，因此这里绝不再执行：
#   rc-service sshd stop
#   rc-service sshd zap
#
# 已确认部分 Alpine/Incus 环境里 sshd listener 与 OpenRC PID tracking
# 不一致时，stop 可能卡住。只需要把 sshd 加入 default runlevel。
rc-update add sshd default >/dev/null 2>&1 || true

echo "TEMPLATE_STAGE=OPENRC_RUNLEVEL_DONE"

# ------------------------------------------------------------
# 清理 cloud-init 首次启动状态
# ------------------------------------------------------------

echo "TEMPLATE_STAGE=CLOUD_INIT_CLEAN"

if command -v cloud-init >/dev/null 2>&1; then

    # cloud-init clean 是必要的 golden-image 清理步骤，但不能允许它无限卡住。
    if command -v timeout >/dev/null 2>&1; then

        if ! timeout 30s cloud-init clean --logs >/dev/null 2>&1; then
            RC=$?

            # timeout 常见退出码 124；无论哪种失败都停止发布，
            # 不拿未 clean 的 cloud image 冒险继续。
            echo "CLOUD_INIT_CLEAN_FAILED_RC=$RC"
            exit 31
        fi

    else

        # Alpine BusyBox 一般包含 timeout applet；如果 PATH 中没有，
        # 尝试通过 busybox 调用。
        if command -v busybox >/dev/null 2>&1 &&
           busybox timeout 30 cloud-init clean --logs >/dev/null 2>&1
        then
            :
        else
            echo "CLOUD_INIT_CLEAN_FAILED_RC=NO_TIMEOUT_OR_FAILED"
            exit 31
        fi

    fi
fi

echo "TEMPLATE_STAGE=CLOUD_INIT_CLEAN_DONE"

# ------------------------------------------------------------
# Golden-image 清理
# ------------------------------------------------------------

echo "TEMPLATE_STAGE=GOLDEN_IMAGE_CLEAN"

# 新实例必须生成自己的 HostKey
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true

rm -f \
    /run/sshd.pid \
    /var/run/sshd.pid \
    2>/dev/null || true

if [ -f /etc/machine-id ]; then
    : >/etc/machine-id
fi

rm -f \
    /var/lib/dbus/machine-id \
    /root/.ash_history \
    /root/.bash_history \
    2>/dev/null || true

rm -rf /root/incus-ssh-backup 2>/dev/null || true

rm -f \
    /etc/resolv.conf.before-incus-final-repair \
    2>/dev/null || true

# 不再遍历/清空整个 /var/log。
# cloud-init clean --logs 已处理 cloud-init 日志，
# 其他日志不影响 SSH/cloud-init 模板首次启动逻辑。

echo "TEMPLATE_STAGE=SYNC"

if command -v timeout >/dev/null 2>&1; then
    timeout 10s sync >/dev/null 2>&1 || true
elif command -v busybox >/dev/null 2>&1; then
    busybox timeout 10 sync >/dev/null 2>&1 || true
else
    sync || true
fi

echo "TEMPLATE_STAGE=PREPARE_DONE"
INNER
}

verify_cloud_template_instance(){
    local ct="$1"
    local initpid="$2"

    local sshd_out
    local root_auth
    local pass_auth
    local port_count

    local cloud_ok=0
    local ssh_ok=0
    local dns_ok=0
    local key_ok=0
    local runlevel_ok=0
    local full_sshd_ok=0

    # 1. 等 cloud-init 真正完成
    if wait_cloud_init "$ct"; then
        cloud_ok=1
    else
        cloud_diagnostics "$ct"
    fi

    if [ "$cloud_ok" -ne 1 ]; then
        echo "CLOUD_INIT_DONE=0"
        echo "RESULT=FAILED"
        return 1
    fi

    echo
    echo "===== cloud-init final status ====="
    incus exec "$ct" -- \
        cloud-init status --long \
        </dev/null 2>/dev/null || true

    echo
    echo "===== cloud config ====="
    incus exec "$ct" -- sh -c '
        grep -RniE \
            "^[[:space:]]*(ssh_pwauth|disable_root):" \
            /etc/cloud/cloud.cfg \
            /etc/cloud/cloud.cfg.d \
            2>/dev/null || true
    ' </dev/null || true

    # 2. 等 sshd 原生服务完成启动
    for _ in $(seq 1 30); do
        if incus exec "$ct" -- \
            rc-service sshd status \
            </dev/null >/dev/null 2>&1
        then
            ssh_ok=1
            break
        fi
        sleep 1
    done

    # 3. sshd 语法必须正确
    if ! incus exec "$ct" -- \
        /usr/sbin/sshd -t \
        </dev/null >/dev/null 2>&1
    then
        echo "SSHD_TEST=FAILED"
        echo "RESULT=FAILED"
        return 1
    fi

    # 4. 有效配置
    sshd_out="$(
        incus exec "$ct" -- \
            /usr/sbin/sshd \
            -T \
            -C user=root,host=localhost,addr=127.0.0.1 \
            </dev/null \
            2>/dev/null || true
    )"

    port_count="$(printf '%s\n' "$sshd_out" | grep -c '^port 22$')"

    root_auth="$(
        printf '%s\n' "$sshd_out" |
        awk '$1=="permitrootlogin" {print $2; exit}'
    )"

    pass_auth="$(
        printf '%s\n' "$sshd_out" |
        awk '$1=="passwordauthentication" {print $2; exit}'
    )"

    if [ "$port_count" -eq 1 ] &&
       [ "$root_auth" = "yes" ] &&
       [ "$pass_auth" = "yes" ]
    then
        full_sshd_ok=1
    fi

    # 5. DNS
    if incus exec "$ct" -- sh -c '
        if command -v nslookup >/dev/null 2>&1; then
            nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1
        else
            ping -c1 -W3 dl-cdn.alpinelinux.org >/dev/null 2>&1
        fi
    ' </dev/null >/dev/null 2>&1
    then
        dns_ok=1
    fi

    # 6. 新实例独立 HostKey
    if incus exec "$ct" -- sh -c '
        ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1
    ' </dev/null >/dev/null 2>&1
    then
        key_ok=1
    fi

    # 7. default runlevel
    if incus exec "$ct" -- sh -c '
        [ -L /etc/runlevels/default/sshd ] ||
        [ -e /etc/runlevels/default/sshd ]
    ' </dev/null >/dev/null 2>&1
    then
        runlevel_ok=1
    fi

    # 8. 复用现有严格验证，确认 OpenRC/PID/socket owner
    if verify_sshd "$ct" "$initpid" >/dev/null 2>&1; then
        :
    else
        # 保留 verify_sshd 的详细输出给日志
        verify_sshd "$ct" "$initpid" || true
        ssh_ok=0
    fi

    echo "CLOUD_INIT_DONE=$cloud_ok"
    echo "SSHD_READY=$ssh_ok"
    echo "PORT_COUNT=$port_count"
    echo "PERMIT_ROOT_LOGIN=$root_auth"
    echo "PASSWORD_AUTH=$pass_auth"
    echo "DNS_OK=$dns_ok"
    echo "HOSTKEY_OK=$key_ok"
    echo "RUNLEVEL_OK=$runlevel_ok"

    if [ "$cloud_ok" -eq 1 ] &&
       [ "$ssh_ok" -eq 1 ] &&
       [ "$full_sshd_ok" -eq 1 ] &&
       [ "$dns_ok" -eq 1 ] &&
       [ "$key_ok" -eq 1 ] &&
       [ "$runlevel_ok" -eq 1 ]
    then
        echo "RESULT=OK"
        return 0
    fi

    echo "RESULT=FAILED"
    return 1
}

# ============================================================
# 读取全部实例（先读入数组，避免 incus exec 消费 while stdin）
# ============================================================


# =============================================================================
# Incus main
# =============================================================================

# Defaults for unified summary when Incus is absent.
TOTAL=0
ALPINE=0
SUCCESS=0
FAILED=0
SKIPPED=0
NEEDPASS=0
TEMPLATE_SUCCESS=0
TEMPLATE_FAILED=0
TEMPLATE_ROLLBACK=0

if [ "$HAS_INCUS" -eq 1 ]; then
mapfile -t ALL_CTS < <(
    incus list --format csv -c n 2>/dev/null |
    sed '/^[[:space:]]*$/d'
)

TOTAL=${#ALL_CTS[@]}

say "Incus Alpine 最终修复开始"
echo "日志：$LOG"
echo "实例总数：$TOTAL"
echo "FIX_CONTAINERS=$FIX_CONTAINERS"
echo "FIX_TEMPLATES=$FIX_TEMPLATES"

# 模板网络提前识别
find_reference_nic || true

if [ -n "$REF_CT" ]; then
    ok "模板构建参考网络：$REF_CT"
    [ -n "$REF_NETWORK" ] && echo "network=$REF_NETWORK"
    [ -n "$REF_PARENT" ] && echo "parent=$REF_PARENT nictype=$REF_NICTYPE"
else
    warn "未识别到模板构建网络；模板部分将跳过"
fi

# ============================================================
# 现有容器
# ============================================================

INDEX=0
ALPINE=0
SUCCESS=0
FAILED=0
SKIPPED=0
NEEDPASS=0

FAILED_LIST=()
NEEDPASS_LIST=()

if [ "$FIX_CONTAINERS" -eq 1 ]; then

    for CT in "${ALL_CTS[@]}"; do
        INDEX=$((INDEX + 1))
        say "[$INDEX/$TOTAL] $CT"

        TYPE="$(
            incus info "$CT" 2>/dev/null |
            awk '/^Type:/ {print tolower($2); exit}'
        )"

        STATUS="$(
            incus info "$CT" 2>/dev/null |
            awk '/^Status:/ {print $2; exit}'
        )"

        if [ -n "$TYPE" ] && [ "$TYPE" != "container" ]; then
            warn "非 Container，跳过"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        WAS_STOPPED=0

        if [ "$STATUS" != "RUNNING" ]; then
            echo "原状态：$STATUS，临时启动"

            if ! incus start "$CT" >/dev/null 2>&1; then
                fail "启动失败"
                FAILED=$((FAILED + 1))
                FAILED_LIST+=("$CT:start")
                continue
            fi

            WAS_STOPPED=1

            if ! wait_exec "$CT"; then
                fail "启动后无法 incus exec"
                incus_stop_safe "$CT" 10 >/dev/null 2>&1 || true

                FAILED=$((FAILED + 1))
                FAILED_LIST+=("$CT:exec")
                continue
            fi
        fi

        if ! is_alpine "$CT"; then
            warn "非 Alpine，跳过"
            SKIPPED=$((SKIPPED + 1))

            if [ "$WAS_STOPPED" -eq 1 ]; then
                incus_stop_safe "$CT" 10 >/dev/null 2>&1 || true
            fi

            continue
        fi

        ALPINE=$((ALPINE + 1))

        INITPID="$(get_init_pid "$CT")"

        if ! [[ "$INITPID" =~ ^[0-9]+$ ]]; then
            fail "无法获取实例宿主机 init PID"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$CT:initpid")

            if [ "$WAS_STOPPED" -eq 1 ]; then
                incus_stop_safe "$CT" 10 >/dev/null 2>&1 || true
            fi
            continue
        fi

        echo "HOST_INIT_PID=$INITPID"

        echo "检查 DNS..."
        DNS_OUT="$(repair_dns "$CT" 2>&1)"
        DNS_RC=$?
        printf '%s\n' "$DNS_OUT"

        if [ "$DNS_RC" -ne 0 ]; then
            warn "DNS 仍异常；继续尝试修复已安装的 SSH"
        fi

        restore_native_sshd_init "$CT"

        echo "重建 SSH 配置..."
        CFG_OUT="$(rebuild_container_sshd_config "$CT" 2>&1)"
        CFG_RC=$?
        printf '%s\n' "$CFG_OUT"

        if printf '%s\n' "$CFG_OUT" |
           grep -q '^ROOT_PASSWORD_STATUS=NEED_PASSWORD$'
        then
            NEEDPASS=$((NEEDPASS + 1))
            NEEDPASS_LIST+=("$CT")
        fi

        if [ "$CFG_RC" -ne 0 ]; then
            fail "SSH 配置生成失败"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$CT:config")

            if [ "$WAS_STOPPED" -eq 1 ]; then
                incus_stop_safe "$CT" 10 >/dev/null 2>&1 || true
            fi
            continue
        fi

        echo "清理旧 sshd listener..."

        if ! release_old_sshd "$CT" "$INITPID"; then
            fail "旧 sshd listener 清理失败"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$CT:listener")

            if [ "$WAS_STOPPED" -eq 1 ]; then
                incus_stop_safe "$CT" 10 >/dev/null 2>&1 || true
            fi
            continue
        fi

        echo "启动 Alpine 原生 sshd..."

        if ! start_native_sshd "$CT"; then
            fail "OpenRC 启动 sshd 失败"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$CT:start-sshd")

            if [ "$WAS_STOPPED" -eq 1 ]; then
                incus_stop_safe "$CT" 10 >/dev/null 2>&1 || true
            fi
            continue
        fi

        echo "严格验证 SSH..."
        VERIFY_OUT="$(verify_sshd "$CT" "$INITPID" 2>&1)"
        VERIFY_RC=$?
        printf '%s\n' "$VERIFY_OUT"

        if [ "$VERIFY_RC" -eq 0 ] &&
           printf '%s\n' "$VERIFY_OUT" | grep -q '^RESULT=OK$'
        then
            ok "$CT 修复完成"
            SUCCESS=$((SUCCESS + 1))
        else
            fail "$CT 验证失败"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$CT:verify")
        fi

        if [ "$WAS_STOPPED" -eq 1 ]; then
            echo "恢复原停止状态"
            incus_stop_safe "$CT" 10 >/dev/null 2>&1 || true
        fi
    done

else
    warn "FIX_CONTAINERS=0，跳过现有容器"
fi

# ============================================================
# Alpine Cloud ready 模板
# ============================================================

TEMPLATE_SUCCESS=0
TEMPLATE_FAILED=0
TEMPLATE_ROLLBACK=0

if [ "$FIX_TEMPLATES" -eq 1 ]; then

    say "Alpine Cloud 模板修复"

    # 只匹配正式 ready alias，不会匹配 backup alias
    mapfile -t IMAGES < <(
        incus image alias list \
            --format csv \
            -c a \
            2>/dev/null |
        grep -E '^alpine/[^/]+/cloud/(amd64|arm64)/ready$' |
        sort -u
    )

    if [ "${#IMAGES[@]}" -eq 0 ]; then
        warn "没有发现 alpine/<version>/cloud/{amd64,arm64}/ready 模板"
    fi

    for IMAGE in "${IMAGES[@]}"; do

        say "模板：$IMAGE"

        if [ -z "$REF_CT" ]; then
            fail "没有可复用网络，跳过模板"
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        OLD_FP="$(image_fingerprint "$IMAGE")"

        if [ -z "$OLD_FP" ]; then
            fail "无法取得原模板 fingerprint"
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        SAFE="$(printf '%s' "$IMAGE" | tr '/ :' '---')"
        SHORT_SAFE="${SAFE:0:18}"

        # Incus image alias 最大 64 字符，使用短备份名
        BACKUP_ALIAS="bak-${SHORT_SAFE}-${OLD_FP:0:8}-${TS}"
        if [ "${#BACKUP_ALIAS}" -gt 64 ]; then
            BACKUP_ALIAS="${BACKUP_ALIAS:0:64}"
        fi

        TMP="alpine-build-${TS}-${RANDOM}"
        VERIFY="alpine-verify-${TS}-${RANDOM}"

        echo "原 Fingerprint：${OLD_FP:0:12}"
        echo "备份 Alias：$BACKUP_ALIAS"

        if ! incus image alias create \
            "$BACKUP_ALIAS" \
            "$OLD_FP" \
            >/dev/null 2>&1
        then
            fail "旧模板备份失败，停止处理该模板"
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        ok "旧模板已备份"

        BUILD_OK=1

        incus init "$IMAGE" "$TMP" >/dev/null 2>&1 || BUILD_OK=0

        if [ "$BUILD_OK" -eq 1 ]; then
            attach_reference_nic "$TMP" >/dev/null 2>&1 || BUILD_OK=0
        fi

        if [ "$BUILD_OK" -eq 1 ]; then
            incus start "$TMP" >/dev/null 2>&1 || BUILD_OK=0
        fi

        if [ "$BUILD_OK" -eq 1 ]; then
            wait_exec "$TMP" || BUILD_OK=0
        fi

        if [ "$BUILD_OK" -ne 1 ]; then
            fail "模板构建实例创建/联网失败"
            incus delete "$TMP" --force >/dev/null 2>&1 || true
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        echo "检查模板构建实例 DNS..."
        T_DNS_OUT="$(repair_dns "$TMP" 2>&1)"
        T_DNS_RC=$?
        printf '%s\n' "$T_DNS_OUT"

        if [ "$T_DNS_RC" -ne 0 ]; then
            fail "模板构建实例 DNS 失败，不发布"
            incus delete "$TMP" --force >/dev/null 2>&1 || true
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        restore_native_sshd_init "$TMP"

        echo "写入 Cloud-init / SSH 最终模板配置..."

        PREP_OUT="$(prepare_cloud_template "$TMP" 2>&1)"
        PREP_RC=$?
        printf '%s\n' "$PREP_OUT"

        if [ "$PREP_RC" -ne 0 ]; then
            fail "模板配置失败，不发布"
            incus delete "$TMP" --force >/dev/null 2>&1 || true
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        # 发布前停止整个构建实例，确保没有运行态残留
        if ! incus_stop_safe "$TMP" 10; then
            fail "模板构建实例无法停止，不发布该模板"
            incus delete "$TMP" --force >/dev/null 2>&1 || true
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        echo "重新发布模板..."

        if ! incus publish \
            "$TMP" \
            --alias "$IMAGE" \
            --reuse \
            >/dev/null 2>&1
        then
            fail "模板发布失败"
            incus delete "$TMP" --force >/dev/null 2>&1 || true
            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
            continue
        fi

        incus delete "$TMP" --force >/dev/null 2>&1 || true

        NEW_FP="$(image_fingerprint "$IMAGE")"
        ok "模板发布成功：${NEW_FP:0:12}"

        # ----------------------------------------------------
        # 新模板必须创建全新实例做 first-boot 验证
        # ----------------------------------------------------

        TEST_OK=1

        incus init "$IMAGE" "$VERIFY" >/dev/null 2>&1 || TEST_OK=0

        if [ "$TEST_OK" -eq 1 ]; then
            attach_reference_nic "$VERIFY" >/dev/null 2>&1 || TEST_OK=0
        fi

        if [ "$TEST_OK" -eq 1 ]; then
            incus start "$VERIFY" >/dev/null 2>&1 || TEST_OK=0
        fi

        if [ "$TEST_OK" -eq 1 ]; then
            wait_exec "$VERIFY" || TEST_OK=0
        fi

        VERIFIED=0

        if [ "$TEST_OK" -eq 1 ]; then

            VPID="$(get_init_pid "$VERIFY")"

            if [[ "$VPID" =~ ^[0-9]+$ ]]; then
                VOUT="$(
                    verify_cloud_template_instance \
                        "$VERIFY" \
                        "$VPID" \
                        2>&1
                )"
                VRC=$?

                printf '%s\n' "$VOUT"

                if [ "$VRC" -eq 0 ] &&
                   printf '%s\n' "$VOUT" | grep -q '^RESULT=OK$'
                then
                    VERIFIED=1
                fi
            else
                fail "无法取得模板验证实例宿主 PID"
            fi
        else
            fail "模板验证实例创建/启动失败"
        fi

        incus delete "$VERIFY" --force >/dev/null 2>&1 || true

        if [ "$VERIFIED" -eq 1 ]; then
            ok "模板最终验证通过"
            TEMPLATE_SUCCESS=$((TEMPLATE_SUCCESS + 1))
        else
            fail "模板验证失败，自动恢复原模板 alias"

            if rollback_image_alias "$IMAGE" "$OLD_FP"; then
                warn "已回滚：$IMAGE -> ${OLD_FP:0:12}"
                TEMPLATE_ROLLBACK=$((TEMPLATE_ROLLBACK + 1))

                # 发布出来但验证失败的新 image 没有正式 alias 后可尝试清理；
                # 删除失败不会影响回滚结果。
                if [ -n "$NEW_FP" ] && [ "$NEW_FP" != "$OLD_FP" ]; then
                    incus image delete "$NEW_FP" >/dev/null 2>&1 || true
                fi
            else
                fail "自动回滚失败，请使用备份 alias：$BACKUP_ALIAS"
            fi

            TEMPLATE_FAILED=$((TEMPLATE_FAILED + 1))
        fi
    done

else
    warn "FIX_TEMPLATES=0，跳过模板"
fi

# ============================================================
# 最终统计
# ============================================================

say "Incus 最终结果"

echo "Incus 实例总数       : $TOTAL"
echo "Alpine 容器          : $ALPINE"
echo "SSH 修复成功         : $SUCCESS"
echo "SSH 修复失败         : $FAILED"
echo "跳过                 : $SKIPPED"
echo "需要设置 root 密码   : $NEEDPASS"
echo "模板验证成功         : $TEMPLATE_SUCCESS"
echo "模板失败             : $TEMPLATE_FAILED"
echo "模板自动回滚         : $TEMPLATE_ROLLBACK"

if [ "${#FAILED_LIST[@]}" -gt 0 ]; then
    say "失败项目"
    printf '  %s\n' "${FAILED_LIST[@]}"
fi

if [ "${#NEEDPASS_LIST[@]}" -gt 0 ]; then
    say "需要设置 root 密码的容器"
    printf '  %s\n' "${NEEDPASS_LIST[@]}"
    echo
    echo "设置命令：incus exec <容器名> -- passwd root"
fi

echo
echo "日志：$LOG"

else
    say "Incus"
    warn "未安装 Incus，跳过 Incus 容器和模板。"
fi


# =============================================================================
# Podman functions
# =============================================================================

podman_wait_exec(){
    local ct="$1"
    local i

    for i in $(seq 1 30); do
        if podman exec --user 0 "$ct" true </dev/null >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    return 1
}

podman_is_alpine(){
    podman exec --user 0 "$1" test -f /etc/alpine-release \
        </dev/null >/dev/null 2>&1
}

podman_get_init_pid(){
    podman inspect \
        --format '{{.State.Pid}}' \
        "$1" 2>/dev/null |
    head -n1
}

podman_repair_dns(){
    local ct="$1"

    podman exec --user 0 -i "$ct" sh -s <<'INNER'
set +e

TEST_HOST="dl-cdn.alpinelinux.org"

check_dns(){
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$TEST_HOST" >/dev/null 2>&1
    else
        ping -c 1 -W 3 "$TEST_HOST" >/dev/null 2>&1
    fi
}

if check_dns; then
    echo "DNS_STATUS=OK"
    exit 0
fi

echo "DNS_STATUS=FAILED_BEFORE_FIX"

# Podman 网络通常由 runtime 注入；先只尝试恢复现有 resolv.conf 能力。
# 不主动执行 DHCP，因为 Podman application container 并不一定运行 DHCP client。
GW="$(
    ip -4 route 2>/dev/null |
    awk '/^default / {print $3; exit}'
)"

if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
    cp -L \
        /etc/resolv.conf \
        /etc/resolv.conf.before-podman-ssh-repair \
        2>/dev/null || true
fi

{
    [ -n "$GW" ] && echo "nameserver $GW"
    echo "nameserver 1.1.1.1"
    echo "nameserver 8.8.8.8"
    echo "options timeout:2 attempts:2"
} >/etc/resolv.conf

if check_dns; then
    echo "DNS_STATUS=FIXED"
    exit 0
fi

echo "DNS_STATUS=FAILED_AFTER_FIX"
cat /etc/resolv.conf 2>/dev/null || true
ip -4 route 2>/dev/null || true

exit 2
INNER
}

podman_restore_native_sshd_init(){
    local ct="$1"

    podman exec --user 0 -i "$ct" sh -s <<'INNER'
set +e

if [ -f /etc/init.d/sshd.original-alpine ]; then
    cp -af /etc/init.d/sshd.original-alpine /etc/init.d/sshd
    chmod +x /etc/init.d/sshd
    echo "SSHD_INIT=RESTORED"
else
    echo "SSHD_INIT=NATIVE_OR_UNUSED"
fi

rc-update del ssh-hostkeys default >/dev/null 2>&1 || true

rm -f \
    /etc/init.d/ssh-hostkeys \
    /etc/runlevels/default/ssh-hostkeys \
    2>/dev/null || true
INNER
}

podman_rebuild_sshd_config(){
    local ct="$1"

    podman exec --user 0 -i "$ct" sh -s <<'INNER'
set -e

STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p \
    /root/podman-ssh-backup \
    /etc/ssh \
    /run/sshd

if ! command -v sshd >/dev/null 2>&1; then
    apk add --no-cache openssh >/dev/null
fi

if [ -f /etc/ssh/sshd_config ]; then
    cp -a \
        /etc/ssh/sshd_config \
        "/root/podman-ssh-backup/sshd_config.${STAMP}"
fi

if [ -d /etc/ssh/sshd_config.d ]; then
    cp -a \
        /etc/ssh/sshd_config.d \
        "/root/podman-ssh-backup/sshd_config.d.${STAMP}" \
        2>/dev/null || true
fi

cat >/etc/ssh/sshd_config <<'CONF'
Port 22
PidFile /run/sshd.pid

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key

PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
UseDNS no

Subsystem sftp internal-sftp
CONF

ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd -t

ROOT_FIELD="$(
    awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null
)"

case "$ROOT_FIELD" in
    '!$'*)
        passwd -u root >/dev/null 2>&1 || true
        ;;
    '!'*)
        if [ "$ROOT_FIELD" != "!" ] &&
           [ "$ROOT_FIELD" != "!!" ] &&
           [ "${#ROOT_FIELD}" -gt 10 ]
        then
            passwd -u root >/dev/null 2>&1 || true
        fi
        ;;
esac

ROOT_FIELD="$(
    awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null
)"

case "$ROOT_FIELD" in
    ""|"!"|"!!"|"*")
        echo "ROOT_PASSWORD_STATUS=NEED_PASSWORD"
        ;;
    '!'*)
        echo "ROOT_PASSWORD_STATUS=LOCKED"
        ;;
    *)
        echo "ROOT_PASSWORD_STATUS=OK"
        ;;
esac

/usr/sbin/sshd \
    -T \
    -C user=root,host=localhost,addr=127.0.0.1 \
    2>/dev/null |
grep -E \
'^(port|pidfile|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) '
INNER
}

podman_port22_listening(){
    local initpid="$1"

    nsenter \
        -t "$initpid" \
        -n \
        ss -lntH \
        2>/dev/null |
    grep -qE '(:22[[:space:]]|\]:22[[:space:]])'
}

podman_find_port22_owners(){
    local initpid="$1"
    local owners
    local inodes
    local inode
    local fd
    local link
    local pid

    owners="$(
        nsenter \
            -t "$initpid" \
            -n \
            ss -lntpH \
            2>/dev/null |
        grep -E '(:22[[:space:]]|\]:22[[:space:]])' |
        grep -oE 'pid=[0-9]+' |
        cut -d= -f2 |
        sort -nu
    )"

    if [ -n "$owners" ]; then
        printf '%s\n' "$owners"
        return 0
    fi

    inodes="$(
        nsenter \
            -t "$initpid" \
            -n \
            ss -lntpeH \
            2>/dev/null |
        grep -E '(:22[[:space:]]|\]:22[[:space:]])' |
        sed -n 's/.*ino:\([0-9][0-9]*\).*/\1/p' |
        sort -u
    )"

    for inode in $inodes; do
        for fd in /proc/[0-9]*/fd/*; do
            [ -L "$fd" ] || continue

            link="$(readlink "$fd" 2>/dev/null || true)"
            [ "$link" = "socket:[$inode]" ] || continue

            pid="$(printf '%s\n' "$fd" | cut -d/ -f3)"
            [[ "$pid" =~ ^[0-9]+$ ]] && echo "$pid"
        done
    done | sort -nu
}

podman_release_old_sshd(){
    local ct="$1"
    local initpid="$2"
    local allow_pid1_kill="${3:-0}"

    local ct_net
    local ct_pidns
    local host_net
    local owner
    local comm
    local owner_net
    local owner_pidns
    local owners=()

    ct_net="$(readlink "/proc/$initpid/ns/net" 2>/dev/null || true)"
    ct_pidns="$(readlink "/proc/$initpid/ns/pid" 2>/dev/null || true)"
    host_net="$(readlink /proc/1/ns/net 2>/dev/null || true)"

    if [ -z "$ct_net" ]; then
        fail "Podman $ct 无法获取 network namespace"
        return 1
    fi

    if [ "$ct_net" = "$host_net" ]; then
        fail "Podman $ct 使用宿主机 network namespace，拒绝自动清理 :22"
        return 5
    fi

    mapfile -t owners < <(
        podman_find_port22_owners "$initpid"
    )

    # 没 listener 是正常情况。
    if [ "${#owners[@]}" -eq 0 ]; then
        if podman_port22_listening "$initpid"; then
            fail "Podman $ct :22 在监听但无法定位 owner"
            return 2
        fi
        return 0
    fi

    for owner in "${owners[@]}"; do
        [ -d "/proc/$owner" ] || continue

        comm="$(cat "/proc/$owner/comm" 2>/dev/null || true)"
        owner_net="$(readlink "/proc/$owner/ns/net" 2>/dev/null || true)"
        owner_pidns="$(readlink "/proc/$owner/ns/pid" 2>/dev/null || true)"

        echo "Podman 旧 listener: host_pid=$owner comm=$comm netns=$owner_net pidns=$owner_pidns"

        if [ "$comm" != "sshd" ]; then
            fail "Podman $ct :22 被非 sshd 程序占用：PID=$owner COMM=$comm"
            return 3
        fi

        if [ "$owner_net" != "$ct_net" ]; then
            fail "Podman $ct owner PID=$owner 不属于目标 netns"
            return 4
        fi

        if [ "$owner_pidns" != "$ct_pidns" ]; then
            fail "Podman $ct owner PID=$owner 不属于目标 PID namespace"
            return 8
        fi

        if [ "$owner" = "$initpid" ] && [ "$allow_pid1_kill" -ne 1 ]; then
            fail "Podman $ct 的 PID1 本身就是 sshd，不直接 kill PID1；应走容器 restart 模式"
            return 6
        fi
    done

    for owner in "${owners[@]}"; do
        [ -d "/proc/$owner" ] || continue
        echo "TERM Podman sshd host PID=$owner"
        kill -TERM "$owner" 2>/dev/null || true
    done

    sleep 2

    for owner in "${owners[@]}"; do
        if [ -d "/proc/$owner" ]; then
            echo "KILL Podman sshd host PID=$owner"
            kill -KILL "$owner" 2>/dev/null || true
        fi
    done

    sleep 1

    if podman_port22_listening "$initpid"; then
        fail "Podman $ct 清理后 :22 仍在监听"
        return 7
    fi

    return 0
}

podman_detect_mode(){
    local ct="$1"
    local pid1_comm
    local start_cfg

    pid1_comm="$(
        podman exec --user 0 "$ct" sh -c \
            'cat /proc/1/comm 2>/dev/null || true' \
            2>/dev/null |
        head -n1
    )"

    start_cfg="$(
        podman inspect \
            --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' \
            "$ct" 2>/dev/null || true
    )"

    if [ "$pid1_comm" = "sshd" ] ||
       printf '%s\n' "$start_cfg" | grep -qiE '(^|[^[:alnum:]_-])sshd([^[:alnum:]_-]|$|/usr/sbin/sshd)'
    then
        echo "MAIN_SSHD"
        return 0
    fi

    if podman exec --user 0 "$ct" sh -c '
        command -v rc-service >/dev/null 2>&1 &&
        [ -x /etc/init.d/sshd ] &&
        P1="$(cat /proc/1/comm 2>/dev/null)" &&
        { [ "$P1" = "init" ] || [ "$P1" = "openrc-init" ]; }
    ' >/dev/null 2>&1
    then
        echo "OPENRC"
        return 0
    fi

    echo "APPLICATION"
}

podman_start_openrc_sshd(){
    local ct="$1"

    podman exec --user 0 -i "$ct" sh -s <<'INNER'
set -e

rm -f \
    /run/sshd.pid \
    /var/run/sshd.pid \
    2>/dev/null || true

mkdir -p /run/sshd

rc-service sshd zap >/dev/null 2>&1 || true
rc-update add sshd default >/dev/null 2>&1 || true

ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd -t

rc-service sshd start
sleep 1
INNER
}

podman_start_direct_sshd(){
    local ct="$1"

    podman exec --user 0 "$ct" sh -c '
        set -e

        mkdir -p /run/sshd

        rm -f \
            /run/sshd.pid \
            /var/run/sshd.pid \
            2>/dev/null || true

        ssh-keygen -A >/dev/null 2>&1 || true
        /usr/sbin/sshd -t

        /usr/sbin/sshd
    '
}

podman_verify_common(){
    local ct="$1"
    local initpid="$2"
    local require_openrc="${3:-0}"

    local out
    local port_count
    local root_auth
    local pass_auth
    local ct_net
    local p
    local owner_ok=0
    local port_ok=0
    local config_ok=0
    local rc_ok=0
    local pid_ok=0
    local runlevel_ok=0
    local vpids=()

    if podman_port22_listening "$initpid"; then
        port_ok=1
    fi

    mapfile -t vpids < <(
        podman_find_port22_owners "$initpid"
    )

    if [ "${#vpids[@]}" -gt 0 ]; then
        owner_ok=1
        ct_net="$(readlink "/proc/$initpid/ns/net" 2>/dev/null || true)"
        ct_pidns="$(readlink "/proc/$initpid/ns/pid" 2>/dev/null || true)"

        for p in "${vpids[@]}"; do
            if [ ! -d "/proc/$p" ]; then
                owner_ok=0
                break
            fi

            if [ "$(cat "/proc/$p/comm" 2>/dev/null || true)" != "sshd" ]; then
                owner_ok=0
                break
            fi

            if [ "$(readlink "/proc/$p/ns/net" 2>/dev/null || true)" != "$ct_net" ]; then
                owner_ok=0
                break
            fi

            if [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null || true)" != "$ct_pidns" ]; then
                owner_ok=0
                break
            fi
        done
    fi

    out="$(
        podman exec --user 0 "$ct" \
            /usr/sbin/sshd \
            -T \
            -C user=root,host=localhost,addr=127.0.0.1 \
            2>/dev/null || true
    )"

    port_count="$(printf '%s\n' "$out" | grep -c '^port 22$')"

    root_auth="$(
        printf '%s\n' "$out" |
        awk '$1=="permitrootlogin" {print $2; exit}'
    )"

    pass_auth="$(
        printf '%s\n' "$out" |
        awk '$1=="passwordauthentication" {print $2; exit}'
    )"

    if [ "$port_count" -eq 1 ] &&
       [ "$root_auth" = "yes" ] &&
       [ "$pass_auth" = "yes" ]
    then
        config_ok=1
    fi

    if [ "$require_openrc" -eq 1 ]; then
        if podman exec --user 0 "$ct" rc-service sshd status \
            >/dev/null 2>&1
        then
            rc_ok=1
        fi

        if podman exec --user 0 "$ct" sh -c '
            PID=$(cat /run/sshd.pid 2>/dev/null)
            [ -n "$PID" ] &&
            [ -d "/proc/$PID" ] &&
            [ "$(cat "/proc/$PID/comm" 2>/dev/null)" = "sshd" ]
        ' >/dev/null 2>&1
        then
            pid_ok=1
        fi

        if podman exec --user 0 "$ct" sh -c '
            [ -L /etc/runlevels/default/sshd ] ||
            [ -e /etc/runlevels/default/sshd ]
        ' >/dev/null 2>&1
        then
            runlevel_ok=1
        fi
    else
        rc_ok=1
        pid_ok=1
        runlevel_ok=1
    fi

    echo "PORT22_OK=$port_ok"
    echo "OWNER_OK=$owner_ok"
    echo "PORT_COUNT=$port_count"
    echo "PERMIT_ROOT_LOGIN=$root_auth"
    echo "PASSWORD_AUTH=$pass_auth"

    if [ "$require_openrc" -eq 1 ]; then
        echo "OPENRC_OK=$rc_ok"
        echo "PIDFILE_OK=$pid_ok"
        echo "RUNLEVEL_OK=$runlevel_ok"
    fi

    if [ "$port_ok" -eq 1 ] &&
       [ "$owner_ok" -eq 1 ] &&
       [ "$config_ok" -eq 1 ] &&
       [ "$rc_ok" -eq 1 ] &&
       [ "$pid_ok" -eq 1 ] &&
       [ "$runlevel_ok" -eq 1 ]
    then
        echo "RESULT=OK"
        return 0
    fi

    echo "RESULT=FAILED"
    return 1
}

# =============================================================================
# Podman main
# =============================================================================

PODMAN_TOTAL=0
PODMAN_ALPINE=0
PODMAN_SUCCESS=0
PODMAN_RUNTIME_ONLY=0
PODMAN_FAILED=0
PODMAN_SKIPPED=0
PODMAN_NEEDPASS=0

PODMAN_FAILED_LIST=()
PODMAN_RUNTIME_LIST=()
PODMAN_NEEDPASS_LIST=()

if [ "$HAS_PODMAN" -eq 1 ] && [ "$FIX_PODMAN_CONTAINERS" -eq 1 ]; then

    say "Podman Alpine 容器修复"

    # Podman 官方也允许 ps --sync；先同步一次 runtime 状态，失败不阻断。
    podman ps --sync >/dev/null 2>&1 || true

    mapfile -t PODMAN_CTS < <(
        podman ps -a \
            --format '{{.ID}}|{{.Names}}' \
            2>/dev/null |
        sed '/^[[:space:]]*$/d'
    )

    PODMAN_TOTAL=${#PODMAN_CTS[@]}
    echo "Podman 容器总数：$PODMAN_TOTAL"

    P_INDEX=0

    for ROW in "${PODMAN_CTS[@]}"; do
        P_INDEX=$((P_INDEX + 1))

        P_ID="${ROW%%|*}"
        P_NAME="${ROW#*|}"

        say "[Podman $P_INDEX/$PODMAN_TOTAL] $P_NAME ($P_ID)"

        P_STATUS="$(
            podman inspect \
                --format '{{.State.Status}}' \
                "$P_ID" 2>/dev/null || true
        )"

        P_WAS_STOPPED=0

        if [ "$P_STATUS" != "running" ]; then
            echo "原状态：$P_STATUS，临时启动"

            if ! podman start "$P_ID" >/dev/null 2>&1; then
                fail "Podman $P_NAME 无法启动，跳过"
                PODMAN_FAILED=$((PODMAN_FAILED + 1))
                PODMAN_FAILED_LIST+=("$P_NAME:start")
                continue
            fi

            P_WAS_STOPPED=1

            if ! podman_wait_exec "$P_ID"; then
                fail "Podman $P_NAME 启动后无法 exec"
                podman stop "$P_ID" >/dev/null 2>&1 || true

                PODMAN_FAILED=$((PODMAN_FAILED + 1))
                PODMAN_FAILED_LIST+=("$P_NAME:exec")
                continue
            fi
        fi

        if ! podman_is_alpine "$P_ID"; then
            warn "非 Alpine，跳过"
            PODMAN_SKIPPED=$((PODMAN_SKIPPED + 1))

            if [ "$P_WAS_STOPPED" -eq 1 ]; then
                podman stop "$P_ID" >/dev/null 2>&1 || true
            fi

            continue
        fi

        PODMAN_ALPINE=$((PODMAN_ALPINE + 1))

        P_INITPID="$(podman_get_init_pid "$P_ID")"

        if ! [[ "$P_INITPID" =~ ^[0-9]+$ ]] || [ "$P_INITPID" -le 0 ]; then
            fail "无法获取 Podman 宿主机 init PID"

            PODMAN_FAILED=$((PODMAN_FAILED + 1))
            PODMAN_FAILED_LIST+=("$P_NAME:initpid")

            if [ "$P_WAS_STOPPED" -eq 1 ]; then
                podman stop "$P_ID" >/dev/null 2>&1 || true
            fi

            continue
        fi

        echo "HOST_INIT_PID=$P_INITPID"

        P_CT_NET="$(readlink "/proc/$P_INITPID/ns/net" 2>/dev/null || true)"
        P_HOST_NET="$(readlink /proc/1/ns/net 2>/dev/null || true)"

        if [ -n "$P_CT_NET" ] && [ "$P_CT_NET" = "$P_HOST_NET" ]; then
            warn "Podman $P_NAME 使用 host network；为避免影响宿主机 :22，默认跳过自动 SSH 修复"
            PODMAN_FAILED=$((PODMAN_FAILED + 1))
            PODMAN_FAILED_LIST+=("$P_NAME:host-network")

            if [ "$P_WAS_STOPPED" -eq 1 ]; then
                podman stop "$P_ID" >/dev/null 2>&1 || true
            fi
            continue
        fi

        echo "检查 DNS..."
        P_DNS_OUT="$(podman_repair_dns "$P_ID" 2>&1)"
        P_DNS_RC=$?
        printf '%s\n' "$P_DNS_OUT"

        if [ "$P_DNS_RC" -ne 0 ]; then
            warn "Podman $P_NAME DNS 仍异常；继续处理已安装 SSH"
        fi

        podman_restore_native_sshd_init "$P_ID"

        echo "重建 SSH 配置..."
        P_CFG_OUT="$(podman_rebuild_sshd_config "$P_ID" 2>&1)"
        P_CFG_RC=$?
        printf '%s\n' "$P_CFG_OUT"

        if printf '%s\n' "$P_CFG_OUT" |
           grep -q '^ROOT_PASSWORD_STATUS=NEED_PASSWORD$'
        then
            PODMAN_NEEDPASS=$((PODMAN_NEEDPASS + 1))
            PODMAN_NEEDPASS_LIST+=("$P_NAME")
        fi

        if [ "$P_CFG_RC" -ne 0 ]; then
            fail "Podman $P_NAME SSH 配置失败"

            PODMAN_FAILED=$((PODMAN_FAILED + 1))
            PODMAN_FAILED_LIST+=("$P_NAME:config")

            if [ "$P_WAS_STOPPED" -eq 1 ]; then
                podman stop "$P_ID" >/dev/null 2>&1 || true
            fi
            continue
        fi

        P_MODE="$(podman_detect_mode "$P_ID")"
        echo "PODMAN_MODE=$P_MODE"

        case "$P_MODE" in

            MAIN_SSHD)
                # PID1/容器启动命令本身就是 sshd。
                # 不 kill PID1，直接让 Podman 正常重启整个容器。
                echo "容器主进程为 sshd，重启整个 Podman 容器..."

                if ! podman restart "$P_ID" >/dev/null 2>&1; then
                    fail "Podman $P_NAME restart 失败"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:restart")
                    continue
                fi

                if ! podman_wait_exec "$P_ID"; then
                    fail "Podman $P_NAME restart 后无法 exec"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:restart-exec")
                    continue
                fi

                P_INITPID="$(podman_get_init_pid "$P_ID")"

                P_VERIFY="$(
                    podman_verify_common \
                        "$P_ID" \
                        "$P_INITPID" \
                        0 \
                        2>&1
                )"
                P_VRC=$?
                printf '%s\n' "$P_VERIFY"

                if [ "$P_VRC" -eq 0 ]; then
                    ok "Podman $P_NAME 修复完成（MAIN_SSHD）"
                    PODMAN_SUCCESS=$((PODMAN_SUCCESS + 1))
                else
                    fail "Podman $P_NAME 验证失败"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:verify-main")
                fi
                ;;

            OPENRC)
                # system-container 型 Podman，与 Incus 类似，但使用 Podman PID/netns。
                podman exec --user 0 "$P_ID" \
                    rc-service sshd stop \
                    >/dev/null 2>&1 || true

                echo "清理 Podman OpenRC 旧 sshd listener..."

                if ! podman_release_old_sshd "$P_ID" "$P_INITPID" 0; then
                    fail "Podman $P_NAME listener 清理失败"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:listener")

                    if [ "$P_WAS_STOPPED" -eq 1 ]; then
                        podman stop "$P_ID" >/dev/null 2>&1 || true
                    fi
                    continue
                fi

                echo "启动 Alpine 原生 OpenRC sshd..."

                if ! podman_start_openrc_sshd "$P_ID"; then
                    fail "Podman $P_NAME OpenRC sshd 启动失败"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:start-sshd")

                    if [ "$P_WAS_STOPPED" -eq 1 ]; then
                        podman stop "$P_ID" >/dev/null 2>&1 || true
                    fi
                    continue
                fi

                P_VERIFY="$(
                    podman_verify_common \
                        "$P_ID" \
                        "$P_INITPID" \
                        1 \
                        2>&1
                )"
                P_VRC=$?
                printf '%s\n' "$P_VERIFY"

                if [ "$P_VRC" -eq 0 ]; then
                    ok "Podman $P_NAME 修复完成（OPENRC）"
                    PODMAN_SUCCESS=$((PODMAN_SUCCESS + 1))
                else
                    fail "Podman $P_NAME OpenRC 验证失败"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:verify-openrc")
                fi
                ;;

            APPLICATION|*)
                # 普通应用容器通常没有 init/OpenRC。
                # 不改 Entrypoint/CMD，也不 commit image；仅恢复当前运行态 sshd。
                CT_NET="$(readlink "/proc/$P_INITPID/ns/net" 2>/dev/null || true)"
                HOST_NET="$(readlink /proc/1/ns/net 2>/dev/null || true)"

                if [ "$CT_NET" = "$HOST_NET" ]; then
                    warn "Podman $P_NAME 是 host network application container；拒绝自动启动/清理 :22"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:host-network")

                    if [ "$P_WAS_STOPPED" -eq 1 ]; then
                        podman stop "$P_ID" >/dev/null 2>&1 || true
                    fi
                    continue
                fi

                echo "普通 application container：修复当前运行态 sshd，不修改 CMD/Entrypoint"

                if podman_port22_listening "$P_INITPID"; then
                    if ! podman_release_old_sshd "$P_ID" "$P_INITPID" 0; then
                        fail "Podman $P_NAME 当前 sshd listener 清理失败"
                        PODMAN_FAILED=$((PODMAN_FAILED + 1))
                        PODMAN_FAILED_LIST+=("$P_NAME:listener-runtime")

                        if [ "$P_WAS_STOPPED" -eq 1 ]; then
                            podman stop "$P_ID" >/dev/null 2>&1 || true
                        fi
                        continue
                    fi
                fi

                if ! podman_start_direct_sshd "$P_ID"; then
                    fail "Podman $P_NAME 直接启动 sshd 失败"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:start-runtime")

                    if [ "$P_WAS_STOPPED" -eq 1 ]; then
                        podman stop "$P_ID" >/dev/null 2>&1 || true
                    fi
                    continue
                fi

                P_VERIFY="$(
                    podman_verify_common \
                        "$P_ID" \
                        "$P_INITPID" \
                        0 \
                        2>&1
                )"
                P_VRC=$?
                printf '%s\n' "$P_VERIFY"

                if [ "$P_VRC" -eq 0 ]; then
                    warn "Podman $P_NAME 当前运行态 SSH 已修复；该容器没有 OpenRC/sshd 主进程，重启后是否自动启动 SSH 取决于原始 image/CMD"
                    PODMAN_RUNTIME_ONLY=$((PODMAN_RUNTIME_ONLY + 1))
                    PODMAN_RUNTIME_LIST+=("$P_NAME")
                else
                    fail "Podman $P_NAME runtime SSH 验证失败"
                    PODMAN_FAILED=$((PODMAN_FAILED + 1))
                    PODMAN_FAILED_LIST+=("$P_NAME:verify-runtime")
                fi
                ;;
        esac

        # 原本停止的容器恢复停止状态。
        # MAIN_SSHD restart 后也按原状态恢复。
        if [ "$P_WAS_STOPPED" -eq 1 ]; then
            echo "恢复 Podman 容器原停止状态"
            podman stop "$P_ID" >/dev/null 2>&1 || true
        fi
    done

elif [ "$HAS_PODMAN" -eq 1 ]; then
    warn "FIX_PODMAN_CONTAINERS=0，跳过 Podman"
fi

say "Podman 最终结果"
echo "Podman 容器总数       : $PODMAN_TOTAL"
echo "Alpine 容器           : $PODMAN_ALPINE"
echo "持久模式修复成功      : $PODMAN_SUCCESS"
echo "仅当前运行态修复      : $PODMAN_RUNTIME_ONLY"
echo "修复失败              : $PODMAN_FAILED"
echo "跳过                  : $PODMAN_SKIPPED"
echo "需要设置 root 密码    : $PODMAN_NEEDPASS"

if [ "${#PODMAN_FAILED_LIST[@]}" -gt 0 ]; then
    say "Podman 失败项目"
    printf '  %s\n' "${PODMAN_FAILED_LIST[@]}"
fi

if [ "${#PODMAN_RUNTIME_LIST[@]}" -gt 0 ]; then
    say "Podman runtime-only 容器"
    printf '  %s\n' "${PODMAN_RUNTIME_LIST[@]}"
fi

if [ "${#PODMAN_NEEDPASS_LIST[@]}" -gt 0 ]; then
    say "Podman 需要设置 root 密码"
    printf '  %s\n' "${PODMAN_NEEDPASS_LIST[@]}"
    echo
    echo "设置命令：podman exec --user 0 -it <容器名> passwd root"
fi

say "统一结果"
echo "Incus 检测             : $([ "$HAS_INCUS" -eq 1 ] && echo YES || echo NO)"
echo "Podman 检测            : $([ "$HAS_PODMAN" -eq 1 ] && echo YES || echo NO)"

if [ "$HAS_INCUS" -eq 1 ]; then
    echo "Incus Alpine 成功/失败 : ${SUCCESS:-0}/${FAILED:-0}"
    echo "Incus 模板成功/失败    : ${TEMPLATE_SUCCESS:-0}/${TEMPLATE_FAILED:-0}"
fi

if [ "$HAS_PODMAN" -eq 1 ]; then
    echo "Podman 持久成功/失败   : $PODMAN_SUCCESS/$PODMAN_FAILED"
    echo "Podman runtime-only    : $PODMAN_RUNTIME_ONLY"
fi

echo "日志：$LOG"
echo "完成"
