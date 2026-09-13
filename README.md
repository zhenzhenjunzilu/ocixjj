# chicken.sh

ARM / AMD 主机 Incus 容器批量分发管理脚本。

适用场景:Oracle Cloud (Ampere A1 / AMD) + Incus 容器 + 单公网 IP 按端口区分多台"小鸡"(独立 SSH 环境)。

---

## 功能概览

- 一键安装并初始化 Incus
- 批量创建容器,自动分配端口段、装好 SSH、生成随机密码
- 每台容器可独立设置 CPU / 内存 / 磁盘限制,后续可随时调整
- 自定义基础镜像加速:提前把 openssh / bash / curl 装好并 publish 成镜像,后续批量创建不用每台重复走网络安装
- 端口自动避让本机已占用端口,不会误分配冲突端口
- 自检工具:一条命令区分"是 Incus 转发链路的问题"还是"OCI 安全组没放行"
- **交互式菜单**:不用记命令,数字选操作即可

---

## 前置条件(脚本做不到,必须手动去 Oracle Cloud 控制台操作一次)

进入 **VCN → Security Lists(或你用的 NSG)→ Ingress Rules → Add Ingress Rules**,添加:

| 字段 | 值 |
|---|---|
| Source CIDR | `0.0.0.0/0` |
| IP Protocol | `All Protocols` |

**不放行这条,本机端口再怎么开都连不进来** —— OCI 安全组和本机防火墙是两道独立的墙,脚本只能帮你开后面这一道。

跑 `init` 时脚本会打印本机公网 IP,方便你去控制台核对是不是同一台机器。

---

## 安装

```bash
chmod +x chicken.sh
```

建议用 root 账号操作,或者所有命令前加 `sudo`。

---

## 快速开始

```bash
sudo ./chicken.sh init          # 1. 初始化环境(只需跑一次)
sudo ./chicken.sh build-image   # 2. 构建加速用的基础镜像(强烈建议,后续create会快很多)
sudo ./chicken.sh create 1      # 3. 创建一台测试
sudo ./chicken.sh list          # 4. 查看状态和账号信息
sudo ./chicken.sh check ck1     # 5. 自检SSH是否真的通
```

之后批量创建 50 台,每台限制 CPU 5%、内存 128MiB、磁盘 512MiB:

```bash
sudo ./chicken.sh create 50 5% 128MiB 512MiB
```

---

## 交互式菜单(推荐,不用记命令)

```bash
sudo ./chicken.sh
```

不带任何参数,直接弹出菜单:

```
================================================
          chicken.sh 交互菜单
================================================
 当前小鸡数量: 2
 自定义基础镜像: 已构建 [chicken-base]
------------------------------------------------
  1) 初始化环境           (init)
  2) 构建加速基础镜像     (build-image)
  3) 删除基础镜像         (delete-image)
  4) 批量创建小鸡         (create)
  5) 查看所有小鸡         (list)
  6) 调整某台资源限制     (resize)
  7) 删除某台小鸡         (delete)
  8) 自检某台小鸡SSH      (check)
  9) 重启某台/全部小鸡    (restart)
  0) 退出
------------------------------------------------
请选择操作 [0-9]:
```

- 选 `4` 创建时会依次询问台数、CPU、内存、磁盘,直接回车即用默认值
- 选 `7` 删除前必须输入 `yes` 二次确认,避免手滑删错
- 任何一步执行出错都会提示原因并返回菜单,不会导致整个程序崩溃退出
- `sudo ./chicken.sh menu` 效果等同于不带参数

命令行用法和交互菜单可以混用,写自动化脚本时仍然用命令行参数的方式调用(见下方"命令参考")。

---

## 命令参考

### `init` —— 初始化环境

```bash
sudo ./chicken.sh init
```

做的事:装 curl/iptables → 安装 Incus → `incus admin init --auto` 自动配置存储池和网络 → 放开本机 iptables(全部放行,防火墙统一交给 OCI 控制台管)。只需要跑一次,重复跑会自动检测已完成的步骤并跳过。

### `build-image` —— 构建加速用的基础镜像

```bash
sudo ./chicken.sh build-image
```

起一个临时容器,装好 `openssh` / `bash` / `curl` 并配置好 sshd(允许密码登录、允许 root 登录),然后 `incus publish` 成本地镜像 `chicken-base`,删掉临时容器。

之后 `create` 会自动检测这个镜像是否存在:存在就优先使用(每台只需设置随机密码,省掉重复的网络安装步骤,速度明显更快);不存在则自动回退到原始镜像现装的流程。

> 基础镜像发布时**不会**启动 sshd(不生成 host key)。Alpine 的 sshd 在真正启动时会自动补全缺失的 host key,所以每台新容器首次开机都会各自生成独立的 host key,不会出现"所有小鸡共用同一个 SSH 指纹"的问题。

### `delete-image` —— 删除自定义基础镜像

```bash
sudo ./chicken.sh delete-image
```

删除后 `create` 会退回使用原始镜像现装 sshd 的流程。想更新基础镜像(比如想加装新的软件包)时,先 `delete-image` 再重新 `build-image`。

### `create` —— 批量创建

```bash
sudo ./chicken.sh create [N] [CPU%] [MEM] [DISK]
```

| 参数 | 说明 | 默认值 |
|---|---|---|
| N | 创建台数 | 1 |
| CPU% | CPU 时间片百分比(不是核数),对应 `limits.cpu.allowance`,如 `5%` / `10%` | 脚本顶部 `DEFAULT_CPU` |
| MEM | 内存上限,对应 `limits.memory`,如 `128MiB` / `1GiB` | 脚本顶部 `DEFAULT_MEM` |
| DISK | 根盘大小,如 `512MiB` / `10GiB` | 脚本顶部 `DEFAULT_DISK` |

示例:

```bash
sudo ./chicken.sh create 50 5% 128MiB 512MiB
```

每台会:
1. 用自定义基础镜像(如果有)或原始镜像启动容器
2. 设置随机 16 位密码
3. 分配一个 5 端口的端口段(自动避开本机已占用的端口)
4. 打印并记录到 `/root/chicken_accounts.txt`

单台失败(比如网络抖动)不会中断整批创建,会跳过继续下一台。

### `list` —— 查看状态

```bash
sudo ./chicken.sh list
```

显示 Incus 容器实时状态(含 CPU/内存用量)+ 账号信息表(名称/IP/SSH端口/端口段/密码/CPU/内存/磁盘)。

### `resize` —— 调整已存在小鸡的资源限制

```bash
sudo ./chicken.sh resize <名称> [CPU%] [MEM] [DISK]
```

留空的参数表示不修改该项,例如只改内存:

```bash
sudo ./chicken.sh resize ck1 '' 256MiB
```

### `delete` —— 删除

```bash
sudo ./chicken.sh delete <名称>
```

会自动清理该容器占用的端口转发规则。**注意:已删除小鸡占用的端口段不会自动回收复用**,新建的小鸡会继续往后分配,避免端口冲突。

### `check` —— 自检

```bash
sudo ./chicken.sh check <名称>
```

依次验证:
1. 本机是否真的在监听对应端口
2. 用密码通过 `127.0.0.1` 回环连接 SSH,验证 Incus 端口转发链路本身是否通
3. 打印当前的 CPU / 内存 / 磁盘限制

如果第 2 步显示 OK,但你自己电脑连不上外部 IP,问题基本可以锁定在 **OCI 控制台 Security List 没放行**,不用再怀疑脚本或 Incus。

### `restart` —— 重启

```bash
sudo ./chicken.sh restart <名称>     # 重启单台
sudo ./chicken.sh restart all        # 重启全部小鸡
```

用 `incus restart`(优雅重启),失败则自动退化为 `incus start`。重启后建议隔几秒跑一下 `check` 确认 SSH 恢复正常。

---

## 端口分配规则

每台小鸡分配 5 个连续端口(`PORTS_PER=5`,可在脚本顶部调整):

| 端口偏移 | 协议 | 用途 |
|---|---|---|
| +0 | TCP | SSH |
| +1, +2 | TCP | 额外 TCP 端口 |
| +3, +4 | UDP | UDP 端口 |

端口池从 `POOL_START=21000` 开始按段分配,分配前会检测本机是否已有服务占用该端口段,冲突则自动跳到下一段。

---

## 资源限制说明

- **CPU**:用百分比(`limits.cpu.allowance`)而不是整数核数,可以设置得很小(如 `5%`),适合高密度切换多台容器,不受"最少占用1核"的限制。
- **磁盘配额是否真正生效取决于存储池驱动**:`zfs` / `btrfs` 支持强制配额;`dir` 驱动(`incus admin init --auto` 的默认选择)不支持真正限制,`size=` 设置会被记录但不会强制生效,磁盘用量需要自己用 `df -h` 监控。如需强制配额,建议在 `incus admin init` 时手动选择存储池为 `zfs` 或 `btrfs`。

---

## 文件位置

| 文件 | 用途 |
|---|---|
| `/root/chicken_accounts.txt` | 账号信息记录(名称/IP/SSH端口/端口段/密码/CPU/内存/磁盘),权限已设为 `600` 仅 root 可读 |
| `/root/chicken_port_pool.state` | 端口池分配进度 |

---

## 常见问题排查

**Q: `incus launch` 报错 `Failed getting root disk: No root device could be found`**

说明 `incus admin init` 没有真正把存储池挂到 default profile 上。检查:

```bash
incus storage list
incus profile show default
```

如果都是空的,手动补跑:

```bash
incus admin init --auto
```

**Q: 提示 `You don't have the needed permissions to talk to the incus daemon`**

普通用户直接执行 `incus` 命令没有权限,前面加 `sudo`,或者把当前用户加入 `incus-admin` 组后重新登录:

```bash
sudo usermod -aG incus-admin $(whoami)
```

**Q: `check` 显示本机内部连接成功,但外部连不上**

99% 是 OCI 控制台 Security List 没放行 `0.0.0.0/0, All Protocols`,回到最前面"前置条件"章节确认。

**Q: 宿主机重启后,之前建的小鸡都没跟着起来**

Incus 容器默认不会跟着宿主机重启自动拉起,需要显式设置 `boot.autostart=true`。新版脚本创建的容器已自动带上这个配置;如果是旧版脚本建的容器,手动补一下:

```bash
for name in $(incus list -c n --format csv); do
    incus config set "$name" boot.autostart true
    incus start "$name"
done
```

**Q: 想清空重来**

```bash
sudo ./chicken.sh delete-image
rm -f /root/chicken_accounts.txt /root/chicken_port_pool.state
```
(不会删除已创建的容器,容器需要用 `sudo ./chicken.sh delete <名称>` 逐个清理,或者 `incus delete <名称> --force` 手动清)

---

## 安全提示

- 每台容器默认允许 root 密码 SSH 登录,密码为随机 16 位字符串,记录在 `/root/chicken_accounts.txt` 中(文件权限已设为仅 root 可读)。
- 该文件包含明文密码,注意不要把它提交到 git 仓库或暴露给无关人员。
- 如果长期对公网开放大量端口,建议额外考虑在容器内加装 `fail2ban` 或改用密钥登录,降低被爆破的风险。

---

## 版本变更记录

- 新增 `restart` 命令,支持重启单台或全部(`all`)小鸡,命令行和交互菜单均可用
- 新创建的容器自动设置 `boot.autostart=true`,宿主机重启后容器会自动拉起(此前需要手动 `incus start`)
- 修复 `init` 误判已初始化的问题(原来用 `incus info` 是否成功判断,现在直接检查 `default profile` 是否挂了 `root` 存储设备)
- `build-image` 现在会预装 `bash` / `curl`,构建出的容器开箱即用
- 端口从每台 20 个精简为每台 5 个(3 TCP 含 SSH + 2 UDP)
- 新增交互式菜单(`sudo ./chicken.sh` 不带参数即可)
- 新增 CPU / 内存 / 磁盘资源限制及 `resize` 命令
- 批量创建单台失败不再中断整批任务
