#!/bin/bash
#
# chicken.sh —— ARM 主机 Incus 容器批量分发管理脚本
#
# 适用场景: Oracle Cloud ARM (Ampere A1) + Incus 容器 + 单公网IP按端口区分多台"小鸡"
#
# 用法:
#   sudo ./chicken.sh init                      初始化环境:装 Incus、自动初始化、放开本机防火墙(只需跑一次)
#   sudo ./chicken.sh build-image               构建自定义基础镜像(预装好sshd),之后create会自动使用,大幅提速(建议先跑一次)
#   sudo ./chicken.sh delete-image              删除自定义基础镜像,create会退回用原始镜像现装sshd
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

set -e

# ================= 可调参数 =================
PORTS_PER=5                                   # 每台小鸡分配的端口数量(前3个tcp,含ssh端口;后2个udp)
POOL_START=21000                              # 端口池起始端口(建议避开20000-20099等常见默认端口)
IMAGE="images:alpine/edge"                    # 原始容器镜像(Alpine,体积小,适合高密度切鸡;edge=始终指向当前可用最新版,不会像固定版本号那样过期下架)
CUSTOM_IMAGE="chicken-base"                   # build-image 生成的自定义基础镜像别名。create时若存在会优先使用它(已预装配置好sshd),
                                               # 省掉每台apk update/install的网络等待,建议先跑一次: sudo ./chicken.sh build-image
BUILD_TMP_NAME="chicken-image-builder"        # 构建自定义基础镜像时使用的临时容器名
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

# 获取指定容器的IPv4地址(带重试),返回空字符串表示失败
wait_for_ip() {
    local name="$1"
    local ip=""
    for i in $(seq 1 15); do
        ip=$(incus list "$name" -c 4 --format csv | head -n1 | cut -d',' -f1)
        [ -n "$ip" ] && break
        sleep 2
    done
    echo "$ip"
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
    # 注意: 不能只用 `incus info` 是否成功来判断"是否已初始化"——
    # 只要 incus 服务装好并启动了,`incus info` 就会成功,哪怕存储池/网络都还没配置,
    # 这会导致 admin init --auto 被误判跳过,后续 incus launch 报错
    # "Failed getting root disk: No root device could be found"。
    # 改成直接检查 default profile 是否真的挂了 root 存储设备,这才是判断"是否已初始化"的准确依据。
    if ! incus profile device get default root pool &>/dev/null; then
        echo "检测到 default profile 缺少 root 存储设备,执行自动初始化..."
        incus admin init --auto
        echo "已用默认配置自动初始化(本地存储 + 网桥NAT网络)。"
        echo "如果你需要自定义存储池/网络(比如想用 zfs 以支持磁盘配额),请先执行: incus admin init 手动配置,再重跑本脚本。"
    else
        echo "Incus 已初始化(default profile 已有 root 存储设备),跳过"
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
    echo ""
    echo "建议接下来先跑一次: sudo ./chicken.sh build-image  构建自定义基础镜像,后续批量创建会快很多。"

    check_disk_quota_support
}

# ================= 子命令: build-image =================
# 起一个临时容器,装好openssh并把开机自启配好,然后publish成本地镜像。
# 之后 create 会自动检测并优先使用这个镜像,省掉每台重复 apk update/install 的网络耗时。
#
# 注意: 这里故意不在构建阶段启动sshd(不生成host key)。Alpine的sshd openrc初始化脚本
# 在服务真正启动时会自动执行 ssh-keygen -A 补全缺失的host key,所以每台新容器首次开机
# 会各自生成自己独立的host key,不会出现"所有小鸡共用同一个SSH host key"的问题。
cmd_build_image() {
    echo "===== 构建自定义基础镜像 [$CUSTOM_IMAGE] ====="

    if incus info "$BUILD_TMP_NAME" &>/dev/null; then
        echo "发现残留的临时容器 $BUILD_TMP_NAME,先清理..."
        incus delete "$BUILD_TMP_NAME" --force
    fi

    echo "----- 启动临时容器 -----"
    incus launch "$IMAGE" "$BUILD_TMP_NAME"

    echo "----- 等待网络就绪 -----"
    IP=$(wait_for_ip "$BUILD_TMP_NAME")
    if [ -z "$IP" ]; then
        echo "!! 临时容器没拿到IP,构建失败。容器已保留(名称: $BUILD_TMP_NAME),可手动排查后重跑本命令,或先 incus delete $BUILD_TMP_NAME --force 清理。"
        exit 1
    fi
    sleep 3

    echo "----- 安装openssh/bash/curl并配置(不启动sshd,交给每台容器首次开机自己生成host key) -----"
    incus exec "$BUILD_TMP_NAME" -- sh -c "apk update -q && apk add -q openssh bash curl"
    incus exec "$BUILD_TMP_NAME" -- sh -c "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
    incus exec "$BUILD_TMP_NAME" -- sh -c "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
    incus exec "$BUILD_TMP_NAME" -- sh -c "rc-update add sshd default"

    echo "----- 停止容器并 publish 成镜像 -----"
    incus stop "$BUILD_TMP_NAME"
    if incus image list -c l --format csv | grep -qx "$CUSTOM_IMAGE"; then
        echo "已存在同名镜像 [$CUSTOM_IMAGE],先删除旧的..."
        incus image delete "$CUSTOM_IMAGE"
    fi
    incus publish "$BUILD_TMP_NAME" --alias "$CUSTOM_IMAGE" >/dev/null

    echo "----- 清理临时容器 -----"
    incus delete "$BUILD_TMP_NAME" --force

    echo ""
    echo "===== 基础镜像 [$CUSTOM_IMAGE] 构建完成 ====="
    echo "之后跑 create 会自动检测到并优先使用它,单台创建耗时可以省掉 apk update/install 那一步的网络等待。"
}

# ================= 子命令: delete-image =================
cmd_delete_image() {
    if ! incus image list -c l --format csv | grep -qx "$CUSTOM_IMAGE"; then
        echo "自定义镜像 [$CUSTOM_IMAGE] 不存在,无需删除"
        exit 0
    fi
    incus image delete "$CUSTOM_IMAGE"
    echo "已删除自定义镜像 [$CUSTOM_IMAGE],之后 create 会退回使用原始镜像 [$IMAGE] 并重新走 apk 安装流程"
}

# ================= 子命令: create =================
cmd_create() {
    local COUNT=${1:-1}
    local CPU=${2:-$DEFAULT_CPU}   # 百分比,如 5%
    local MEM=${3:-$DEFAULT_MEM}
    local DISK=${4:-$DEFAULT_DISK}

    if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
        echo "N 必须是正整数,收到的是: $COUNT"
        exit 1
    fi

    # 兼容:如果用户传了纯数字(比如 "2"),自动补上 % 号,避免手滑忘记加%
    case "$CPU" in
        *%) ;;
        *) CPU="${CPU}%" ;;
    esac

    [ -f "$STATE_FILE" ] || echo "$POOL_START" > "$STATE_FILE"
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "名称\tIP\tSSH端口\t端口段\t密码\tCPU\t内存\t磁盘" > "$LOG_FILE"
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    check_disk_quota_support

    # 判断是否有自定义基础镜像可用
    local BASE_IMAGE="$IMAGE"
    local USE_CUSTOM=0
    if incus image list -c l --format csv | grep -qx "$CUSTOM_IMAGE"; then
        BASE_IMAGE="$CUSTOM_IMAGE"
        USE_CUSTOM=1
        echo "检测到自定义基础镜像 [$CUSTOM_IMAGE],将使用它加速创建(跳过apk安装步骤)"
    else
        echo "!! 提示: 未检测到自定义基础镜像,本次将用原始镜像现装sshd,速度较慢。"
        echo "   如果经常大批量创建,建议先跑一次: sudo ./chicken.sh build-image"
    fi

    get_next_index() {
        local i=1
        while incus info "${NAME_PREFIX}${i}" &>/dev/null; do
            i=$((i+1))
        done
        echo $i
    }

    # 端口段是否与本机已在监听的端口冲突(比如80/443/其他服务),冲突则跳过整段往后找
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

    echo "开始批量创建 $COUNT 台 (每台限制: CPU=${CPU} 内存=${MEM} 磁盘=${DISK}, 每台${PORTS_PER}个端口: 3 tcp含ssh + 2 udp)..."

    for n in $(seq 1 "$COUNT"); do
        (
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
        incus launch "$BASE_IMAGE" "$NAME" \
            -c limits.cpu.allowance="${CPU}" \
            -c limits.memory="${MEM}" \
            -d root,size="${DISK}"

        IP=$(wait_for_ip "$NAME")
        if [ -z "$IP" ]; then
            echo "!! $NAME 没拿到IP,跳过,请手动检查(incus exec $NAME -- ip a)"
            exit 1
        fi
        sleep 3

        PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

        if [ "$USE_CUSTOM" -eq 1 ]; then
            # 自定义镜像已经预装配置好sshd并设了开机自启,这里只需设密码
            incus exec "$NAME" -- sh -c "echo 'root:${PASSWORD}' | chpasswd"
            # 兜底: 万一开机自启没生效(极少数情况),手动确认一下
            incus exec "$NAME" -- sh -c "rc-service sshd status >/dev/null 2>&1 || (rc-update add sshd default; rc-service sshd restart || rc-service sshd start)"
        else
            # 原始镜像:走完整安装配置流程(Alpine 用 apk 装包、ash 跑脚本、OpenRC 管服务)
            incus exec "$NAME" -- sh -c "apk update -q && apk add -q openssh bash curl"
            incus exec "$NAME" -- sh -c "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
            incus exec "$NAME" -- sh -c "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
            incus exec "$NAME" -- sh -c "echo 'root:${PASSWORD}' | chpasswd"
            incus exec "$NAME" -- sh -c "rc-update add sshd default && (rc-service sshd restart || rc-service sshd start)"
        fi

        # ---- 端口分配: 每台 PORTS_PER(5)个端口 ----
        # PORT_START            : ssh端口 (tcp)
        # PORT_START+1..+2      : 额外 tcp 端口 (共3个tcp,含ssh)
        # PORT_START+3..+4      : udp 端口 (共2个udp)
        SSH_PORT=$PORT_START
        incus config device add "$NAME" sshport proxy \
            listen=tcp:0.0.0.0:${SSH_PORT} \
            connect=tcp:127.0.0.1:22 >/dev/null

        for p in $(seq $((PORT_START+1)) $((PORT_START+2))); do
            incus config device add "$NAME" "tcp-$p" proxy \
                listen=tcp:0.0.0.0:${p} \
                connect=tcp:127.0.0.1:${p} >/dev/null
        done

        for p in $(seq $((PORT_START+3)) $((PORT_START+4))); do
            incus config device add "$NAME" "udp-$p" proxy \
                listen=udp:0.0.0.0:${p} \
                connect=udp:127.0.0.1:${p} >/dev/null
        done

        echo -e "${NAME}\t${IP}\t${SSH_PORT}\t${PORT_START}-${PORT_END}\t${PASSWORD}\t${CPU}\t${MEM}\t${DISK}" >> "$LOG_FILE"
        echo "$NAME 完成: SSH端口=${SSH_PORT} 密码=${PASSWORD} CPU=${CPU} 内存=${MEM} 磁盘=${DISK}"
        ) || echo "!! 第 $n 台创建过程中出错,已跳过,继续创建下一台"
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
    if [ -f "$LOG_FILE" ] && awk -F'\t' -v n="$NAME" '$1==n{found=1} END{exit !found}' "$LOG_FILE"; then
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

    echo "删除容器 $NAME(会自动清理其端口转发规则)..."
    incus delete "$NAME" --force

    if [ -f "$LOG_FILE" ]; then
        awk -F'\t' -v n="$NAME" 'BEGIN{OFS="\t"} $1!=n{print}' "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
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
    ROW=$(awk -F'\t' -v n="$NAME" '$1==n{print; exit}' "$LOG_FILE")
    if [ -z "$ROW" ]; then
        echo "在 $LOG_FILE 中找不到 $NAME 的记录"
        exit 1
    fi

    local SSH_PORT PASSWORD
    SSH_PORT=$(echo "$ROW" | cut -f3)
    PASSWORD=$(echo "$ROW" | cut -f5)

    echo "===== 自检 $NAME (本机SSH端口 ${SSH_PORT}) ====="
    echo "1) 端口本机是否在监听:"
    if ss -tln 2>/dev/null | grep -q ":${SSH_PORT} "; then
        echo "   OK - 本机确实在监听 ${SSH_PORT}"
    else
        echo "   !! 本机没有监听 ${SSH_PORT},proxy device 可能没生效,检查: incus config device list ${NAME}"
        return
    fi

    echo "2) 用密码尝试SSH登录(通过 127.0.0.1,验证转发链路本身是否通):"
    if ! command -v sshpass &>/dev/null; then
        apt install -y -qq sshpass >/dev/null
    fi

    if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        root@127.0.0.1 -p "$SSH_PORT" 'echo 本机内部连接成功' 2>/dev/null; then
        echo "   OK - 本机内部能连通,说明 Incus 转发链路没问题"
        echo "   若外部(比如你自己电脑)连不上,问题基本可以定位在: OCI控制台Security List 没放行"
    else
        echo "   !! 本机内部都连不上,问题在 Incus/容器内sshd本身,检查: incus exec ${NAME} -- rc-service sshd status"
    fi

    echo "3) 当前资源限制:"
    echo "   CPU: $(incus config get "$NAME" limits.cpu.allowance 2>/dev/null || echo '未设置(不限)')"
    echo "   内存: $(incus config get "$NAME" limits.memory 2>/dev/null || echo '未设置(不限)')"
    echo "   磁盘: $(incus config device get "$NAME" root size 2>/dev/null || echo '未设置(不限)')"
}

# ================= 交互式菜单 =================

# 列出当前已记录的小鸡名称,方便菜单里选择时参考
menu_list_names() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 1 ]; then
        echo "当前小鸡列表:"
        awk -F'\t' 'NR>1{print "  - "$1"  (SSH端口:"$3")"}' "$LOG_FILE"
    else
        echo "(当前还没有任何小鸡记录)"
    fi
}

# 按任意键返回菜单
menu_pause() {
    echo ""
    read -rp "按回车键返回菜单..." _
}

# 包一层子shell执行,防止 cmd_* 内部的 exit 1 把整个交互菜单进程带崩掉
# (脚本顶部开了 set -e,子shell失败只会让这条 if 判断为假,不会终止父进程)
menu_run() {
    if ( "$@" ); then
        :
    else
        echo ""
        echo "!! 操作未完成(输入有误或执行中出错),已返回菜单"
    fi
}

menu_do_create() {
    read -rp "创建几台? [默认1]: " count
    count=${count:-1}
    read -rp "CPU百分比,如 5% [默认${DEFAULT_CPU}]: " cpu
    cpu=${cpu:-$DEFAULT_CPU}
    read -rp "内存,如 128MiB [默认${DEFAULT_MEM}]: " mem
    mem=${mem:-$DEFAULT_MEM}
    read -rp "磁盘,如 512MiB [默认${DEFAULT_DISK}]: " disk
    disk=${disk:-$DEFAULT_DISK}
    menu_run cmd_create "$count" "$cpu" "$mem" "$disk"
}

menu_do_resize() {
    menu_list_names
    echo ""
    read -rp "输入要调整的小鸡名称: " name
    [ -z "$name" ] && { echo "名称不能为空"; return; }
    read -rp "新CPU百分比(留空不改): " cpu
    read -rp "新内存(留空不改): " mem
    read -rp "新磁盘(留空不改): " disk
    menu_run cmd_resize "$name" "$cpu" "$mem" "$disk"
}

menu_do_delete() {
    menu_list_names
    echo ""
    read -rp "输入要删除的小鸡名称: " name
    [ -z "$name" ] && { echo "名称不能为空"; return; }
    read -rp "!! 确认删除 [$name] ? 此操作不可恢复,输入 yes 确认: " confirm
    if [ "$confirm" = "yes" ]; then
        menu_run cmd_delete "$name"
    else
        echo "已取消,未做任何改动"
    fi
}

menu_do_check() {
    menu_list_names
    echo ""
    read -rp "输入要自检的小鸡名称: " name
    [ -z "$name" ] && { echo "名称不能为空"; return; }
    menu_run cmd_check "$name"
}

cmd_menu() {
    while true; do
        clear
        echo "================================================"
        echo "          chicken.sh 交互菜单"
        echo "================================================"
        local total
        total=$(incus list -c n --format csv 2>/dev/null | grep -c "^${NAME_PREFIX}" || echo 0)
        echo " 当前小鸡数量: ${total}"
        if incus image list -c l --format csv 2>/dev/null | grep -qx "$CUSTOM_IMAGE"; then
            echo " 自定义基础镜像: 已构建 [$CUSTOM_IMAGE]"
        else
            echo " 自定义基础镜像: 未构建(create会用原始镜像现装,较慢)"
        fi
        echo "------------------------------------------------"
        echo "  1) 初始化环境           (init)"
        echo "  2) 构建加速基础镜像     (build-image)"
        echo "  3) 删除基础镜像         (delete-image)"
        echo "  4) 批量创建小鸡         (create)"
        echo "  5) 查看所有小鸡         (list)"
        echo "  6) 调整某台资源限制     (resize)"
        echo "  7) 删除某台小鸡         (delete)"
        echo "  8) 自检某台小鸡SSH      (check)"
        echo "  0) 退出"
        echo "------------------------------------------------"
        read -rp "请选择操作 [0-8]: " choice
        echo ""
        case "$choice" in
            1) menu_run cmd_init; menu_pause ;;
            2) menu_run cmd_build_image; menu_pause ;;
            3) menu_run cmd_delete_image; menu_pause ;;
            4) menu_do_create; menu_pause ;;
            5) menu_run cmd_list; menu_pause ;;
            6) menu_do_resize; menu_pause ;;
            7) menu_do_delete; menu_pause ;;
            8) menu_do_check; menu_pause ;;
            0) echo "已退出"; exit 0 ;;
            *) echo "无效选择,请输入 0-8 之间的数字"; sleep 1 ;;
        esac
    done
}

# ================= 主入口 =================
require_root

case "$1" in
    init)
        cmd_init
        ;;
    build-image)
        cmd_build_image
        ;;
    delete-image)
        cmd_delete_image
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
    menu|"")
        cmd_menu
        ;;
    *)
        echo "用法:"
        echo "  sudo ./chicken.sh                               不带任何参数 = 进入交互菜单,数字选操作,不用记命令"
        echo "  sudo ./chicken.sh menu                          同上,显式进入交互菜单"
        echo "  sudo ./chicken.sh init                          初始化环境(装Incus+自动init+放开防火墙,只需跑一次)"
        echo "  sudo ./chicken.sh build-image                   构建自定义基础镜像(预装sshd),建议先跑一次以加速批量创建"
        echo "  sudo ./chicken.sh delete-image                  删除自定义基础镜像,退回用原始镜像现装sshd"
        echo "  sudo ./chicken.sh create [N] [CPU%] [MEM] [DISK] 批量创建N台小鸡(默认1台,资源限制用脚本顶部默认值)"
        echo "                                                   示例: sudo ./chicken.sh create 50 5% 128MiB 512MiB"
        echo "  sudo ./chicken.sh resize <名称> [CPU%] [MEM] [DISK]  调整已存在小鸡的资源限制(留空项不改)"
        echo "  sudo ./chicken.sh list                           查看所有小鸡状态和账号信息/资源限制"
        echo "  sudo ./chicken.sh delete <名称>                  删除指定小鸡"
        echo "  sudo ./chicken.sh check <名称>                   自检该小鸡SSH是否真的通,并显示资源限制"
        exit 1
        ;;
esac
