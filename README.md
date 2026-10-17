# IGMP Proxy —— koolshare 软件中心插件

接管路由器固件**自带**的 `/usr/sbin/igmpproxy`，用脚本生成的配置把运营商 IPTV 的组播
流量转发进内网，内网设备上的播放器可以直接播放 IPTV 组播源。

插件本体不含 igmpproxy 二进制 —— 固件里已经有了，插件负责**配置、拉起、放行防火墙、
守护、以及提供网页界面**。

- 项目地址 / 问题反馈：<https://github.com/avman-cn/koolshare_igmpproxy>
- 更新日志：[Changelog.txt](Changelog.txt)　许可证：[MIT](LICENSE)　作者：2TimesMeta

> 本仓库是 koolshare 软件中心的**插件封装层**：igmpproxy 二进制来自路由器固件
> `/usr/sbin/igmpproxy`，本仓库**不内置任何二进制**，只提供配置生成、启停、防火墙放行、
> 进程守护和网页界面。

## 目录结构

```
.
├── config.json.js              # 软件中心插件描述（作者 / 仓库主页 / md5）
├── build.py                    # 打包脚本，生成 igmpproxy.tar.gz 并回写 md5
├── Changelog.txt               # 更新日志
├── LICENSE                     # MIT
├── README.md                   # 本文件
└── igmpproxy/                  # 插件本体，安装时整体拷贝到 /koolshare
    ├── install.sh              # 安装脚本（离线安装入口）
    ├── uninstall.sh            # 卸载脚本
    ├── version                 # 插件版本号（1.0.0）
    ├── .valid                  # 适配平台标记（mtk / hnd / qca）
    ├── init.d/                 # 开机自启 / 关机入口（S99 / N99）
    ├── scripts/                # 主控 igmpproxy_config.sh + 接管引擎 igmpproxy-base.sh
    ├── webs/                   # 网页界面 Module_igmpproxy.asp
    ├── res/                    # 插件图标
    └── README.md               # 与根目录 README 相同（插件包内自带一份）
```

---

## 一、安装

**网页离线安装（推荐）**
1. 软件中心 → 离线安装 → 选择 `igmpproxy.tar.gz` 上传。

**命令行离线安装**
```sh
# 在路由器上：
#   1) 把 igmpproxy.tar.gz 放到 /tmp/upload/
#   2) 告诉安装器包名，然后安装
dbus set soft_name=igmpproxy.tar.gz
/koolshare/scripts/ks_tar_install.sh
```

安装完成后：软件中心列表里会出现 **IGMP Proxy**，点进去就是配置页。
插件安装后默认是**关闭**状态，不会自动改动你的网络。

---

## 二、使用前必读：固件自带的「启动组播路由」必须先关掉

固件自己也会用同一个 igmpproxy 二进制去抢组播，两个 IGMP 代理同时跑会互相打架。
**路由器自身的组播路由开关必须是关的**：

- 网页位置：**高级设置 → 局域网(LAN) → IPTV → 启动组播路由** → 关闭
- 对应的 nvram：`mr_enable_x` 必须为 `0`

如果它是开着的，插件页面的「冲突」一栏会自动出现提示，并提供一个
**「一键关闭路由器自身组播路由」**按钮（等于 `nvram set mr_enable_x=0; nvram commit`）。

> 插件除了这个按钮之外**从不修改 nvram**。

### Broadcom 机型额外还有个 `mcpd` 会占 IGMP

GT-AC5300 / RT-AX88U 这类 Broadcom(HND) 机型，固件开机会跑一个自己的组播进程
`/bin/mcpd`，它**开机就占住 IGMP raw socket（`0.0.0.0:2`）**，而且和 `mr_enable_x`
无关——即使你按上面关掉了「启动组播路由」，`mcpd` 还在，igmpproxy 就会一直以

```
MC-Router API already in use; Errno(98): Address already in use
```

立刻退出（症状就是「页面显示启动成功/进程就是起不来」、syslog 里刷这一行）。

插件在每次启动前会先把它停掉，日志里能看到
「🟠 固件自带的组播进程 mcpd(PID ...) 占着 IGMP，先停掉它...」，不需要你手动处理。
这是插件唯一会去结束的固件进程（`mr_enable_x=0` 时 `mcpd` 并没有在做组播路由，
只是占着 socket 不放）。

---

## 三、设置项说明

| 设置项 | 默认 | 说明 |
| --- | --- | --- |
| 上游接口 | 自动探测 | **下拉选择**：只列**当前有 IPv4 地址**、可能做 WAN / IPTV 的口（`ppp0`、`eth0/eth1`、`vlan*`、无线 STA、蜂窝、隧道等；`ppp/pppoe` 还没拨上号也列出来）。留空 ＝ 自动探测，会**优先选当前可用的 PPPoE 接口**（见下面第四节，**这项最关键**） |
| 下游接口 | 自动探测 | **下拉选择**面向内网、且**当前有 IPv4 地址**的口（一般就是 `br0`）。igmpproxy 只支持单个下游接口 |
| 组播源网段 | 空 | 生成 `altnet`；**不填就是空**，输入框里用浅色例值提示格式，留空等于不限。多个网段用空格分隔（如 `10.0.0.0/8 192.168.0.0/16`） |
| 快速换台 | 开 | 生成 `quickleave`，换台时立刻停掉上一路节目 |
| 添加防火墙组播规则 | 开 | 放行 IGMP 与组播 UDP（见第五节） |
| 关闭反向路径过滤 | 开 | 仅对**上游接口**关闭 `rp_filter`，停止时恢复；多 WAN / 组播源与默认路由不同口时必需 |
| 实时进程守护 | 开 | 让**软件中心的后台守护直接看住 `igmpproxy` 进程本身**（不额外常驻脚本），掉线/被固件杀掉后立刻拉起 |
| 强制接管 | 关 | 仅当已有**其它来源**的 igmpproxy 在运行时才需要勾 |

按钮：**开启 / 重启 / 关闭**；页面上还有一个「诊断日志」按钮。

其余界面约定：

- **插件版本**显示在页面标题的插件名后面（如 `IGMP Proxy - 1.0.0`）。
- 「运行状态」下面拆成三行：运行状态 / 组播流向（`上游 → 下游`）/ 进程守护。
- 「进程守护」只显示 `正常` / `未启用` / `待启动` / `异常`，具体含义点标签即可看到说明。
- 「固件环境」只有两种结果：`就绪`（可以正常使用）或 `未就绪：固件自身的「启动组播路由」已开启`（会跟本插件抢 IGMP，点旁边的按钮关掉它即可）。
- 设置区每个标签名都可以点击，弹出该配置项的作用说明——和固件自带页面的呈现方式一致。
- 上下游接口的下拉框里有一项 **「其它接口（手动填写）」**，选它会出现一个输入框，用于候选列表里没有的接口名（例如自定义 VLAN）。dbus 里存的接口如果不在候选里，页面会自动落到这一项并回显原值，**不会**把你的配置悄悄改掉。
- 候选列表只看**当前状态**：上游只列出已经有 IPv4 地址的口（`ppp/pppoe` 例外，还没拨上号也列出来，
  留给自动重试），下游只列出已经有 IPv4 地址的口（一般就是 `br0`）。没有地址的口做不了 IGMP 上下游，
  索性不列，免得选错。列表**不检查**接口上有没有 IPTV 组播——这件事只能实测。
- **所有输入框在你没填过的状态下都是空的**，勾选框用后端默认值渲染。插件不会在你没配置时往 dbus 里写数据，所以不会出现"没配过却显示已配置"的情况。

---

## 四、上游接口怎么选（最容易出错的一步）

**留空（自动探测）的规则**：先看有没有**当前可用的 PPPoE 接口**——`ppp*` 里
已经拿到 IPv4 地址（也就是已经拨上号）的那个，有就用它（本机是 `ppp0`）；
没有可用 PPPoE 时才交回固件逻辑，按 `switch_stb_x > 6 且 iptv_ifname 存在` →
`iptv_ifname`，否则 `wan_ifname` → `wan0_ifname` → 默认路由接口 的顺序挑。
页面上的下拉框会把实际会用到的接口写在「自动探测」后面，例如
「自动探测（优先 ppp0）」；没有可用 PPPoE 口时就只显示「自动探测」。
（文案保持很短，否则下拉框会被最长选项撑得很长。）

**选上游先看有没有地址**：`ifconfig <口>` 里没有 `inet addr:` 的口不能做上游——那说明
它只是个二层交换口（挂在 `br0` 里的 `eth1`/`eth2` 之类），或者 PPPoE 还没拨上号。
这种口选下去，igmpproxy 只会以 `There must be at least 2 Vif's where one is upstream.`
秒退，守护模式下就是反复重拉、永远起不来——看起来就是「拉不起进程」。插件现在会直接拦住并列出能用的口
（`ppp*` 拨号口例外，只提示不拦，因为多等一会儿拨上号就好了）。

本机的情况（自动探测 = `ppp0`，但两个口都值得知道）：

- `ppp0` = PPPoE 虚拟口（默认路由，metric 0），IP 122.233.34.206
- `eth1` = 下层以太口（192.168.100.141/24，默认路由 metric 1 via 192.168.100.1）

**本机原来手动跑那个独立脚本时，上游用的是 `ppp0`；实测也是 `ppp0` 能出流**
（`phyint ppp0 upstream` 时 IPTV 正常，所以本机当前的正确设置是 `ppp0`；
固件自带的探测顺序会先挑到 `eth1`，那是不对的，所以插件改成优先可用的 PPPoE 口）。

这两种都有可能对，取决于运营商把 IPTV 组播放在哪里：

- 若运营商把组播封装在 **PPPoE 会话**里 → 上游填 `ppp0`
- 若组播走 **WAN 以太口 / 单独 VLAN** → 上游填 `eth1`（多数省份是这种）

**怎么判断**：播放一个 IPTV 频道，然后看哪条防火墙规则的计数在涨：

```sh
iptables -L INPUT -v -n | grep igmpproxy-takeover
```

或者直接看接入的电视盒子能否播放：能播就是选对了，黑屏/卡住就换成另一个口再试。
两个口来回试一次即可确定，改完点「重启」。

如果运营商用的是 IPTV 专网 VLAN，还需要先在固件里配置 IPTV
（`switch_stb_x` / `iptv_ifname`），插件会自动优先使用 `iptv_ifname`。

---

## 五、插件到底改了什么

**生成的配置** `/koolshare/configs/igmpproxy/igmpproxy.conf`（停止时保留）：

```
# igmpproxy.conf - 由 igmpproxy-base.sh 生成
quickleave
phyint eth1 upstream ratelimit 0 threshold 1 altnet 0.0.0.0/0
phyint br0 downstream ratelimit 0 threshold 1
```

**防火墙规则**（开启时添加，关闭时逐条删除，不留残留）：

```
-A INPUT   -p 2   -d 224.0.0.0/4                          -j ACCEPT   # IGMP
-A INPUT   -p udp -d 224.0.0.0/4 ! --dport 1900           -j ACCEPT   # 组播 UDP
-A FORWARD -p udp -d 224.0.0.0/4                          -j ACCEPT
```

三条规则都带 `-m comment --comment "igmpproxy-takeover:in-igmp | :in-mcast | :fwd-mcast"`，
所以随时可以这样查/清：

```sh
iptables -S | grep igmpproxy-takeover      # 查看
iptables -L INPUT -v -n | grep igmpproxy   # 看计数（判断上游对不对）
```

**rp_filter**：只把上游接口的 `net.ipv4.conf.<if>.rp_filter` 临时改成 `0`
（原值存 `/tmp/igmpproxy-run/rp_filter.saved`），关闭时恢复原值。

---

## 六、文件与排错

| 路径 | 说明 |
| --- | --- |
| `/koolshare/scripts/igmpproxy_config.sh` | 插件主控（网页后端） |
| `/koolshare/scripts/igmpproxy-base.sh` | 接管引擎，来自你原来的 `igmpproxy-takeover.sh`（见第七节：只多了一个 `--release-mc-router` 选项） |
| `/koolshare/webs/Module_igmpproxy.asp` | 网页界面 |
| `/koolshare/res/icon-igmpproxy.png` | 图标 |
| `/koolshare/init.d/{S99,N99}igmpproxy.sh` | 开机 / 拨号后自启与 start_nat 入口（软链接到主控） |
| `/koolshare/configs/igmpproxy/igmpproxy.conf` | 生成的 igmpproxy 配置 |
| `/tmp/igmpproxy-run/` | 运行态：`igmpproxy.log`、`rp_filter.saved`、`rules.added` |
| `/tmp/upload/igmpproxy_log.txt` | 网页「诊断日志」的内容 |

**接管引擎的退出码**（`igmpproxy-base.sh`）：

| 退出码 | 含义 | 处理 |
| --- | --- | --- |
| 2 | 固件自带的「启动组播路由」开着 | 按第二节关掉它（`--force` 也不能绕过这一条） |
| 3 | 已有其它来源的 igmpproxy 在跑 | 确认后勾「强制接管」 |
| 4 | 启动失败 | 看 `/tmp/igmpproxy-run/igmpproxy.log` |

**插件在启动前自动做的事**（都是为了避免「点了却没起来」）：

1. **收回上一个实例**。IGMP 用的是独占 raw socket，只要还有一个
   igmpproxy 活着，新实例就会立刻以 `MC-Router API already in use; Errno(98)` 退出。
   所以点「开启 / 重启」时，插件先结束自己拉起的残留进程并**等它真正退出**，再启动。
2. **释放固件自带的组播进程**。Broadcom 机型的 `mcpd` 常驻占用同一个 IGMP socket
   （见第二节），启动前先把它停掉并等进程退出——这是 `Errno(98)` 最常见的成因。
3. **清理 perp 残留**。切换守护/单次模式时会先 `perpctl -b /koolshare/perp d` 并删掉
   `/koolshare/perp/igmpproxy`（含旧的 `rc.main`），避免被旧配置反复拉起。
   `perpctl` 必须带 `-b` 指定 basedir，否则它会去找 `./.control/perpd.sock` 而
   **静默失败**（早期版本就踩过：perp 服务没被撤销，反复拉起多个进程抢 IGMP）。
4. **校验手填的接口名**。上游/下游如果是在下拉框里选「其它接口」手写的，插件会先检查
   `/sys/class/net/<接口>` 是否存在；不存在就直接报
   「❌ 接口不存在」并列出当前可用接口，不会再丢给 igmpproxy 变成一句看不懂的报错。
   **上游还多一道检查：必须是已经有 IPv4 地址的口**（下拉框里也只列有地址的口，
   没地址的根本不会出现）。内网交换口（`eth1`/`eth2` 这类挂在 `br0` 里的口）没有自己的地址，
   igmpproxy 建不出上游 Vif，只会报一句
   `There must be at least 2 Vif's where one is upstream.` 然后秒退——守护模式下就是
   反复重拉、永远起不来。这种情况插件会直接拦住并列出真正能用的口。
   （只对 `ppp*` 例外：拨号口没地址多半只是还没拨上号，只提示、不拦，交给守护重试。）
5. **失败自愈**。万一开始失败且确实没有 igmpproxy 在跑，插件会结束所有占用 IGMP 的
   igmpproxy 进程后重试一次；若接管引擎自己判定失败但进程其实已在运行，按成功处理。

**进程守护怎么实现的**：`/koolshare/perp/igmpproxy/rc.main` 里没有
常驻脚本——收到 `start` 时它先跑一次 `igmpproxy-base.sh rules` 补回防火墙放行（WAN 重连会
把规则冲掉），然后 `exec` 掉自己、以前台方式启动 `igmpproxy -d`。也就是说 **perp 守护的就是
igmpproxy 进程本身**：进程一退，perp 立刻重新执行 `rc.main` 把它拉起来，不需要轮询，也不会
出现「守护脚本还活着但状态显示异常」这种中间态；`perpctl` / `perpls` 也认得出它，状态栏的
「进程守护」一栏就是查 `perpls` 里有没有 `igmpproxy` 这个服务。

**开启 / 重启 / 关闭的弹窗**：只回报「结果 + 最要紧的一两句」（上游 → 下游、成功与否、
有没有要留意的提醒），接管引擎的完整输出不再逐行铺进弹窗；只有失败时才会把细节展开。
凡是弹窗里提示「有 N 处提醒」的，点「诊断日志」都能看到对应原文。

**「诊断日志」按钮**：点它会先让后端把当前现场（版本、设置、接口解析、防火墙计数、
配置文件、进程列表）重新收集进日志文件再显示；即使日志是空的，弹窗也会立刻显示
「自动关闭（N）」按钮并倒计时，不会出现关不掉的空白窗口。

**卸载**：软件中心里卸载，或

```sh
/koolshare/scripts/uninstall_igmpproxy.sh
```

---

## 七、与原来独立脚本方式的关系

插件用的是**独立路径**，不会和你原来手动跑的独立脚本互相覆盖：

- 插件配置：`/koolshare/configs/igmpproxy/igmpproxy.conf`
- 独立脚本配置：`/koolshare/igmpproxy-takeover.conf`

引擎逻辑一样，由插件来调度，并且只有一个增量：引擎多了个 `--release-mc-router`
选项（插件每次调用都带上），作用是启动前停掉 Broadcom 机型固件自带的 `mcpd`
（见第二节）。**不带这个选项时引擎的行为和 `igmpproxy-takeover.sh` 完全一致**，
所以原来手动跑独立脚本的命令行照旧可用。**不要两种方式同时启用**，否则会互相抢进程。

原来手动运行留下的两个文件（`/koolshare/igmpproxy-takeover.conf`、`/tmp/igmpproxy-takeover/`）
是惰性的，可以直接删掉，不影响插件。
