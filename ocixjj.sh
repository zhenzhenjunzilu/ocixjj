#!/bin/bash
#
# chicken.sh —— ARM 主机 Incus 容器批量分发管理脚本
#
# 适用场景: Oracle Cloud ARM (Ampere A1) + Incus 容器 + 单公网IP按端口区分多台"小鸡"
#
# 用法:
#   sudo ./chicken.sh init                      初始化环境:装 Incus、自动初始化、放开本机防火墙(只需跑一次)
#   sudo ./chicken.sh create [N] [CPU%] [MEM] [DISK]
#                                                批量创建 N 台(默认1台),自动分配端口段、装ssh、随机密码
#                                                CPU%/MEM/DISK 可选,不填则用脚本顶部默认值
#                                                CPU% 是时间片百分比(如 5%),不是核数,可以设得很小
#                                                示例: sudo ./chicken.sh create 50 5% 128MiB 512MiB
#   sudo ./chicken.sh list                       查看所有小鸡及其端口/密码/资源限制
#   sudo ./chicken.sh resize <名称> [CPU%] [MEM] [DISK]
#                                                调整已存在小鸡的资源限制(留空的项不改)
#   sudo ./chicken.sh delete <名称>              删除指定小鸡(同时清理端口转发规则)
#   sudo ./chicken.sh check <名称>               自检:从本机直接测试该小鸡的SSH端口是否真的能连通
#
# 重要前提(脚本不会帮你做,必须手动去甲骨文控制台操作一次):
#   VCN -> Security Lists / NSG -> Ingress Rules -> 添加规则:
#     Source CIDR: 0.0.0.0/0
#     IP Protocol: All Protocols
#   不放行这条,本机端口再怎么开都连不进来,是两道独立的墙。
#   (跑 init 时脚本会打印出本机公网IP,方便你去控制台核对)
#
# ---------------------------------------------------------------------------
# 关于端口转发方式(重要变更说明):
#   旧版每个端口用 incus proxy device 走用户态转发(forkproxy 进程),
#   每台小鸡 20 端口(tcp+udp)= 40 个常驻进程,台数一多内存/句柄容易爆炸。
#
#   本版改为 proxy device 加 nat=true,由内核态 iptables/nftables 直接做
#   DNAT 转发,不再为每个端口 fork 进程,几乎零额外常驻内存开销。
#   代价:nat=true 模式下宿主机不会真的 listen 该端口(是DNAT不是accept),
#   所以 check 命令改用查 iptables NAT 规则 + 实际连接测试来验证,而不是 ss -tln。
# ---------------------------------------------------------------------------

set -e

# ================= 可调参数 =================
PORTS_PER=20                                  # 每台小鸡分配的端口数量
POOL_START=21000                              # 端口池起始端口(建议避开20000-20099等常见默认端口)
IMAGE="images:alpine/edge"                    # 容器镜像(Alpine,体积小,适合高密度切鸡;edge=始终指向当前可用最新版,不会像固定版本号那样过期下架)
STATE_FILE="/root/chicken_port_pool.state"    # 端口池分配进度记录
LOG_FILE="/root/chicken_accounts.txt"         # 账号信息记录(名称/IP/SSH端口/端口段/密码/CPU/内存/磁盘)
NAME_PREFIX="ck"                              # 小鸡命名前缀,如 ck1 ck2 ck3

# ---- 资源限制默认值(可在此改,或 create 时用参数临时覆盖) ----
DEFAULT_CPU="5%"         # CPU 时间片百分比,对应 incus limits.cpu.allowance,如 5% / 10% / 50%
                          # 用百分比而不是整数核,高密度切鸡时才能切得细,不受"最少1核"限制
DEFAULT_MEM="128MiB"     # 内存,对应 incus limits.memory,如 128MiB / 256MiB / 1GiB
DEFAULT_DISK="512MiB"    # 根盘大小,对应 root 设备的 size,如 512MiB / 1GiB / 10GiB
                          # 注意: 磁盘限额是否生效取决于存储池驱动(zfs/btrfs 支持配额;
                          # dir 驱动不支持,只会记录不会真正限制,脚本会给出提示)

# ================= 通用检查 =================
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请用 sudo 运行本脚本"
        exit 1
    fi
}

# 检测当前 Incus 存储池驱动是否支持磁盘配额(zfs/btrfs 支持, dir/lvm-thin 等可能不支持或行为不同)
check_disk_quota_support() {
    local pool driver
    pool=$(incus profile device get default root pool 2>/dev/null || echo "")
    if [ -z "$pool" ]; then
        return
    fi
    driver=$(incus storage show "$pool" 2>/dev/null | awk -F': ' '/^driver:/ {print $2}')
    case "$driver" in
        zfs|btrfs)
            ;;
        *)
            echo "!! 提示: 当前存储池驱动是 [$driver],该驱动可能不支持真正的磁盘配额限制。"
            echo "   size= 设置会被记录,但不一定能强制生效,磁盘用量请配合 df -h 自行监控。"
            echo "   如需强制磁盘配额,建议存储池换成 zfs 或 btrfs (需在 incus admin init 时选择)。"
            ;;
    esac
}

# ================= 子命令: init =================
cmd_init() {
    echo "===== 1. 安装基础依赖 ====="
    export DEBIAN_FRONTEND=noninteractive
    apt update -qq
    apt install -y -qq curl iptables iptables-persistent >/dev/null

    echo "===== 2. 安装 Incus ====="
    if ! command -v incus &>/dev/null; then
        # 先试系统自带源(较新的 Ubuntu/Debian 有 incus 包)
        if apt-cache show incus &>/dev/null; then
            apt install -y -qq incus incus-client
        else
            echo "系统自带源没有 incus 包,改用官方 Zabbly 源安装..."
            apt install -y -qq gpg
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
            cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo "${VERSION_CODENAME}")
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
            apt update -qq
            apt install -y -qq incus incus-client
        fi
    else
        echo "Incus 已安装,跳过"
    fi

    echo "===== 3. 初始化 Incus(全自动默认配置) ====="
    # 只判断服务是否能连上不够(装了包但没跑过admin init时incus info也能连上),
    # 改为检查是否已存在存储池,这才是"真正初始化过"的标志。
    if ! incus storage list --format csv 2>/dev/null | grep -q .; then
        incus admin init --auto
        echo "已用默认配置自动初始化(本地存储 + 网桥NAT网络)。"
        echo "如果你需要自定义存储池/网络(比如想用 zfs 以支持磁盘配额),请先执行: incus admin init 手动配置,再重跑本脚本。"
    else
        echo "Incus 已初始化,跳过"
    fi

    echo "===== 4. 放开本机 iptables(全部放行,防火墙统一交给OCI控制台管) ====="
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    iptables -X
    netfilter-persistent save

    echo ""
    echo "===== 环境初始化完成 ====="
    PUB_IP=$(curl -s -4 --max-time 5 ifconfig.me || echo "获取失败,可手动执行: curl ifconfig.me")
    echo "本机公网IP: ${PUB_IP}"
    echo "!! 别忘了去 OCI 控制台放行 Security List: Source 0.0.0.0/0, Protocol All Protocols"
    echo "!! 否则本机端口开了也没用,外部连不进来"

    check_disk_quota_support
}

# ================= 子命令: create =================
cmd_create() {
    local COUNT=${1:-1}
    local CPU=${2:-$DEFAULT_CPU}   # 百分比,如 5%
    local MEM=${3:-$DEFAULT_MEM}
    local DISK=${4:-$DEFAULT_DISK}

    # 兼容:如果用户传了纯数字(比如 "2"),自动补上 % 号,避免手滑忘记加%
    case "$CPU" in
        *%) ;;
        *) CPU="${CPU}%" ;;
    esac

    [ -f "$STATE_FILE" ] || echo "$POOL_START" > "$STATE_FILE"
    [ -f "$LOG_FILE" ] || echo -e "名称\tIP\tSSH端口\t端口段\t密码\tCPU\t内存\t磁盘" > "$LOG_FILE"

    check_disk_quota_support

    # nat=true 模式下 proxy device 不允许监听通配地址 0.0.0.0,必须绑定宿主机网卡的具体IP。
    # OCI等云主机的"公网IP"通常是网关层1:1 NAT到私网IP,系统自己只看得到私网IP,
    # 绑定这个私网IP即可,通过公网IP访问时网关会自动转进来。
    HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$HOST_IP" ]; then
        echo "!! 无法自动探测宿主机网卡IP,请手动检查网络配置后重试"
        exit 1
    fi
    echo "宿主机绑定IP(用于端口转发监听): ${HOST_IP}"

    get_next_index() {
        local i=1
        while incus info "${NAME_PREFIX}${i}" &>/dev/null; do
            i=$((i+1))
        done
        echo $i
    }

    # 端口段是否与本机已在监听的端口冲突(比如80/443/其他服务),冲突则跳过整段往后找
    # 注意: nat=true 模式下,已分配给其他小鸡的端口不会出现在 ss -tln 里(是DNAT不是listen),
    # 所以这里只能防真实占用(比如宿主机自己跑的服务),防不了"跟其他小鸡端口段重叠"。
    # 重叠问题由 STATE_FILE 递增分配来保证,不依赖 ss 检测。
    find_free_port_start() {
        local candidate=$1
        while true; do
            local conflict=0
            for p in $(seq "$candidate" $((candidate + PORTS_PER - 1))); do
                if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$"; then
                    conflict=1
                    break
                fi
            done
            if [ "$conflict" -eq 0 ]; then
                echo "$candidate"
                return
            fi
            candidate=$((candidate + PORTS_PER))
        done
    }

    echo "开始批量创建 $COUNT 台 (每台限制: CPU=${CPU} 内存=${MEM} 磁盘=${DISK})..."

    for n in $(seq 1 "$COUNT"); do
        IDX=$(get_next_index)
        NAME="${NAME_PREFIX}${IDX}"

        NEXT_PORT=$(cat "$STATE_FILE")
        PORT_START=$(find_free_port_start "$NEXT_PORT")
        PORT_END=$((PORT_START + PORTS_PER - 1))
        echo $((PORT_END + 1)) > "$STATE_FILE"

        echo "===== 创建 $NAME (端口段: ${PORT_START}-${PORT_END}, CPU=${CPU} 内存=${MEM} 磁盘=${DISK}) ====="

        # 创建时直接带上资源限制:
        #   -c limits.cpu.allowance=  CPU 时间片百分比(不是核数,可以设很小,如 5%)
        #   -c limits.memory=         内存上限
        #   -d root,size=             根盘大小限制(需存储池驱动支持配额才会真正强制)
        incus launch "$IMAGE" "$NAME" \
            -c limits.cpu.allowance="${CPU}" \
            -c limits.memory="${MEM}" \
            -d root,size="${DISK}"

        IP=""
        for i in $(seq 1 15); do
            IP=$(incus list "$NAME" -c 4 --format csv | cut -d' ' -f1)
            [ -n "$IP" ] && break
            sleep 2
        done

        if [ -z "$IP" ]; then
            echo "!! $NAME 没拿到IP,跳过,请手动检查(incus exec $NAME -- ip a)"
            continue
        fi

        sleep 3

        # nat=true 模式要求 proxy device 的 connect IP 必须是容器"静态声明"的地址,
        # 单纯DHCP动态分配的IP即使数值一样也会被拒绝(报错 must be one of the instance's
        # static IPv4 addresses)。这里找到容器的网卡设备名,把当前拿到的IP显式声明为静态。
        NIC_DEVICE=""
        for d in $(incus config device list "$NAME" 2>/dev/null); do
            t=$(incus config device get "$NAME" "$d" type 2>/dev/null || echo "")
            if [ "$t" = "nic" ]; then
                NIC_DEVICE="$d"
                break
            fi
        done
        if [ -z "$NIC_DEVICE" ]; then
            echo "!! $NAME 找不到网卡设备名,跳过端口转发,请手动检查: incus config device list $NAME"
            continue
        fi
        incus config device override "$NAME" "$NIC_DEVICE" ipv4.address="${IP}" >/dev/null

        # 仅仅"登记"为静态还不够,容器手里还攥着之前DHCP动态分配的旧租约,
        # 必须重启一次让它重新走DHCP,dnsmasq才会真正把这个IP作为保留地址分配下去,
        # 之后 config device override 声明的"静态"校验才会通过。
        incus restart "$NAME"
        for i in $(seq 1 15); do
            CUR_IP=$(incus list "$NAME" -c 4 --format csv | cut -d' ' -f1)
            [ "$CUR_IP" = "$IP" ] && break
            sleep 2
        done
        if [ "$CUR_IP" != "$IP" ]; then
            echo "!! $NAME 重启后IP有变化(重启前=$IP 重启后=$CUR_IP),改用重启后的实际IP继续"
            IP="$CUR_IP"
        fi
        sleep 2

        # Alpine 用 apk 装包、ash 跑脚本、OpenRC 管服务,和 Debian 版(apt/bash/systemd)不一样
        incus exec "$NAME" -- sh -c "apk update -q && apk add -q openssh"
        incus exec "$NAME" -- sh -c "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
        incus exec "$NAME" -- sh -c "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"

        PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
        incus exec "$NAME" -- sh -c "echo 'root:${PASSWORD}' | chpasswd"
        incus exec "$NAME" -- sh -c "rc-update add sshd default && (rc-service sshd restart || rc-service sshd start)"

        # ---- 端口转发: 全部走 nat=true 内核态转发,不再 fork 用户态进程 ----
        # 注意 connect 目标必须是容器的真实IP(不能用127.0.0.1),因为是内核DNAT。
        SSH_PORT=$PORT_START
        incus config device add "$NAME" sshport proxy \
            listen=tcp:${HOST_IP}:${SSH_PORT} \
            connect=tcp:${IP}:22 \
            nat=true >/dev/null

        for p in $(seq $((PORT_START+1)) $PORT_END); do
            incus config device add "$NAME" "tcp-$p" proxy \
                listen=tcp:${HOST_IP}:${p} \
                connect=tcp:${IP}:${p} \
                nat=true >/dev/null
            incus config device add "$NAME" "udp-$p" proxy \
                listen=udp:${HOST_IP}:${p} \
                connect=udp:${IP}:${p} \
                nat=true >/dev/null
        done

        echo -e "${NAME}\t${IP}\t${SSH_PORT}\t${PORT_START}-${PORT_END}\t${PASSWORD}\t${CPU}\t${MEM}\t${DISK}" >> "$LOG_FILE"
        echo "$NAME 完成: SSH端口=${SSH_PORT} 密码=${PASSWORD} CPU=${CPU} 内存=${MEM} 磁盘=${DISK}"
    done

    echo ""
    echo "全部完成,汇总如下:"
    column -t -s $'\t' "$LOG_FILE"
}

# ================= 子命令: resize =================
# 调整已存在小鸡的资源限制。留空的参数表示不改该项。
# 用法: sudo ./chicken.sh resize ck1 10% 256MiB 1GiB
cmd_resize() {
    local NAME="$1"
    local CPU="$2"     # 百分比,如 10%
    local MEM="$3"
    local DISK="$4"

    if [ -z "$NAME" ]; then
        echo "用法: sudo ./chicken.sh resize <名称> [CPU%] [MEM] [DISK]"
        echo "  留空的项不修改,例如只改内存: sudo ./chicken.sh resize ck1 '' 256MiB"
        exit 1
    fi

    if ! incus info "$NAME" &>/dev/null; then
        echo "容器 $NAME 不存在"
        exit 1
    fi

    if [ -n "$CPU" ]; then
        case "$CPU" in
            *%) ;;
            *) CPU="${CPU}%" ;;
        esac
        incus config set "$NAME" limits.cpu.allowance "$CPU"
        echo "$NAME CPU 限制已改为 ${CPU}"
    fi

    if [ -n "$MEM" ]; then
        incus config set "$NAME" limits.memory "$MEM"
        echo "$NAME 内存限制已改为 ${MEM}"
    fi

    if [ -n "$DISK" ]; then
        check_disk_quota_support
        incus config device override "$NAME" root size="$DISK" 2>/dev/null \
            || incus config device set "$NAME" root size="$DISK"
        echo "$NAME 磁盘限制已改为 ${DISK} (容器需重启后部分场景才完全生效)"
    fi

    # 同步更新 LOG_FILE 里的记录(如果存在这一行)
    if [ -f "$LOG_FILE" ] && grep -q "^${NAME}	" "$LOG_FILE"; then
        local CUR_CPU CUR_MEM CUR_DISK
        CUR_CPU=$(incus config get "$NAME" limits.cpu.allowance 2>/dev/null || echo "-")
        CUR_MEM=$(incus config get "$NAME" limits.memory 2>/dev/null || echo "-")
        CUR_DISK=$(incus config device get "$NAME" root size 2>/dev/null || echo "-")
        awk -F'\t' -v name="$NAME" -v c="$CUR_CPU" -v m="$CUR_MEM" -v d="$CUR_DISK" \
            'BEGIN{OFS="\t"} $1==name {$6=c;$7=m;$8=d} {print}' "$LOG_FILE" > "${LOG_FILE}.tmp" \
            && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

# ================= 子命令: list =================
cmd_list() {
    echo "===== Incus 容器状态(含CPU/内存实时用量) ====="
    incus list -c ns4tM
    echo ""
    if [ -f "$LOG_FILE" ]; then
        echo "===== 账号信息与资源限制 ====="
        column -t -s $'\t' "$LOG_FILE"
    else
        echo "暂无账号记录($LOG_FILE 不存在)"
    fi
}

# ================= 子命令: delete =================
cmd_delete() {
    local NAME="$1"
    if [ -z "$NAME" ]; then
        echo "用法: sudo ./chicken.sh delete <名称>"
        exit 1
    fi

    if ! incus info "$NAME" &>/dev/null; then
        echo "容器 $NAME 不存在"
        exit 1
    fi

    echo "删除容器 $NAME(会自动清理其端口转发规则,包括nat=true下发的iptables规则)..."
    incus delete "$NAME" --force

    if [ -f "$LOG_FILE" ]; then
        grep -vP "^${NAME}\t" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi

    echo "$NAME 已删除。注意:它占用的端口段不会自动回收复用,新建的小鸡会继续往后分配,避免冲突。"
}

# ================= 子命令: check =================
cmd_check() {
    local NAME="$1"
    if [ -z "$NAME" ]; then
        echo "用法: sudo ./chicken.sh check <名称>"
        exit 1
    fi

    if [ ! -f "$LOG_FILE" ]; then
        echo "找不到账号记录文件 $LOG_FILE"
        exit 1
    fi

    local ROW
    ROW=$(grep -P "^${NAME}\t" "$LOG_FILE" || true)
    if [ -z "$ROW" ]; then
        echo "在 $LOG_FILE 中找不到 $NAME 的记录"
        exit 1
    fi

    local SSH_PORT PASSWORD
    SSH_PORT=$(echo "$ROW" | cut -f3)
    PASSWORD=$(echo "$ROW" | cut -f5)

    echo "===== 自检 $NAME (本机SSH端口 ${SSH_PORT}) ====="
    echo "1) NAT转发规则是否已下发(nat=true模式下宿主机不会listen该端口,查iptables NAT表):"
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:${SSH_PORT}[^0-9]"; then
        echo "   OK - 找到 ${SSH_PORT} 的DNAT规则"
    else
        echo "   !! 没找到 ${SSH_PORT} 的DNAT规则,proxy device 可能没生效,检查: incus config device list ${NAME}"
        return
    fi

    echo "2) 用密码尝试SSH登录(通过 127.0.0.1,验证转发链路本身是否通):"
    if ! command -v sshpass &>/dev/null; then
        apt install -y -qq sshpass >/dev/null
    fi

    if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        root@127.0.0.1 -p "$SSH_PORT" 'echo 本机内部连接成功' 2>/dev/null; then
        echo "   OK - 本机内部能连通,说明 Incus NAT 转发链路没问题"
        echo "   若外部(比如你自己电脑)连不上,问题基本可以定位在: OCI控制台Security List 没放行"
    else
        echo "   !! 本机内部都连不上,问题在 Incus/容器内sshd本身,检查: incus exec ${NAME} -- rc-service sshd status"
    fi

    echo "3) 当前资源限制:"
    echo "   CPU: $(incus config get "$NAME" limits.cpu.allowance 2>/dev/null || echo '未设置(不限)')"
    echo "   内存: $(incus config get "$NAME" limits.memory 2>/dev/null || echo '未设置(不限)')"
    echo "   磁盘: $(incus config device get "$NAME" root size 2>/dev/null || echo '未设置(不限)')"
}

# ================= 主入口 =================
require_root

case "$1" in
    init)
        cmd_init
        ;;
    create)
        cmd_create "$2" "$3" "$4" "$5"
        ;;
    resize)
        cmd_resize "$2" "$3" "$4" "$5"
        ;;
    list)
        cmd_list
        ;;
    delete)
        cmd_delete "$2"
        ;;
    check)
        cmd_check "$2"
        ;;
    *)
        echo "用法:"
        echo "  sudo ./chicken.sh init                          初始化环境(装Incus+自动init+放开防火墙,只需跑一次)"
        echo "  sudo ./chicken.sh create [N] [CPU%] [MEM] [DISK] 批量创建N台小鸡(默认1台,资源限制用脚本顶部默认值)"
        echo "                                                   示例: sudo ./chicken.sh create 50 5% 128MiB 512MiB"
        echo "  sudo ./chicken.sh resize <名称> [CPU%] [MEM] [DISK]  调整已存在小鸡的资源限制(留空项不改)"
        echo "  sudo ./chicken.sh list                           查看所有小鸡状态和账号信息/资源限制"
        echo "  sudo ./chicken.sh delete <名称>                  删除指定小鸡"
        echo "  sudo ./chicken.sh check <名称>                   自检该小鸡SSH是否真的通,并显示资源限制"
        exit 1
        ;;
esac
