#!/bin/sh
#===============================================================================
# igmpproxy-takeover.sh
#
# 目标机型: 华硕 TX-AX6000 / 天选游戏路由 (硬件 TUF-AX6000, MT798X 平台, 非 HND)
# 作用    : 在路由器上用「脚本自己生成的 igmpproxy.conf」接管 IGMP 代理服务。
#
# 需求对应关系:
#   1) 用户启用了路由器自带的 igmpproxy 功能 -> 不抢，只提示去设置页面把对应选项关掉;
#   2) 未启用                               -> 脚本在工作目录生成 igmpproxy.conf,
#                                              并拉起使用该配置的 igmpproxy 服务;
#   3) 上游(upstream)接口可由用户通过 --upstream 指定, 不指定时自动探测。
#
# 源码依据 (release/src/router):
#   rc/wan.c      start_igmpproxy(): 生成 /tmp/igmpproxy.conf, 然后
#                 eval("/usr/sbin/igmpproxy", igmpproxy_conf)
#                 ==> 配置文件是「位置参数」, 不是 -c 选项!
#                 (igmpproxy/src/igmpproxy.c:42 Usage: igmpproxy [-h] [-d] [-v] <configfile>)
#                 前置判断: !mr_enable_x 直接 return (非 HND 平台走 igmpproxy 分支);
#                 switch_stb_x>6 且 iptv_ifname!=WAN 接口时直接 return。
#   rc/firewall.c 只有 mr_enable_x 或 udpxy_enable_x 非 0 时才放行组播:
#                   -A INPUT   -p 2 -d 224.0.0.0/4 -j <logaccept>          (协议 2 = IGMP)
#                   -A INPUT   -p udp -d 224.0.0.0/4 ! --dport 1900 -j <logaccept>
#                   -A FORWARD -p udp -d 224.0.0.0/4 -j ACCEPT
#                 并且只对「非默认 WAN 接口」关 rp_filter (firewall.c:7414)。
#                 所以脚本自己拉起 igmpproxy 后, 需要补上这几条规则(可用 --no-firewall 关闭)。
#   www/Advanced_IPTV_Content.asp + www/CN.dict:3447
#                 页面选项「启动组播路由」= nvram mr_enable_x (RouterConfig_GWMulticastEnable)
#                 页面提示: 此功能仅在首选 WAN 下运行 / IGMP proxy 不能与 IPTV 功能共存
#
# 配置格式 (与 rc/wan.c 生成的完全一致, 见 igmpproxy/src/config.c):
#   quickleave                                                    <- mr_qleave_x 非 0 时
#   phyint <上游> upstream   ratelimit 0 threshold 1 altnet <网段>  <- mr_altnet_x 为空则 0.0.0.0/0
#   phyint <下游> downstream ratelimit 0 threshold 1
#   注意: igmpproxy 只允许一个 upstream 接口 (igmpproxy.c:193)。
#
# 用法: sh igmpproxy-takeover.sh [命令] [选项]
#-------------------------------------------------------------------------------
set -u

IGMPPROXY_BIN=/usr/sbin/igmpproxy
ROUTER_CONF=/tmp/igmpproxy.conf          # 路由器自己用的配置文件
IPT=iptables
TAG=igmpproxy-takeover                   # 防火墙规则注释标记, 便于识别/回收

PROG=$(basename "$0")
SELFDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "${SELFDIR:-}" ] || SELFDIR=$(pwd)

#------------------------------- 默认参数 --------------------------------------
CMD=check
WORKDIR=$SELFDIR                         # 脚本工作目录(默认=脚本所在目录)
CONF=                                    # 默认 $WORKDIR/igmpproxy.conf
STATE_DIR=/tmp/igmpproxy-takeover        # 运行状态(pid/备份), tmpfs, 重启即清
LOG=                                     # 默认 $STATE_DIR/igmpproxy.log
UPSTREAM=                                # 空 = 自动探测
DOWNSTREAM=                              # 空 = nvram lan_ifname / br0
ALTNET=0.0.0.0/0
QUICKLEAVE=1
FIREWALL=1
RPFILTER=1
FORCE=0
DEBUG=0
DRYRUN=0
QUIET=0
RELEASE_MC=0
RUN_MIN_GAP=10
MC_HOLDER_NAMES="mcpd"

PIDFILE=
RULES_BAK=
RP_BAK=

#------------------------------- 输出工具 --------------------------------------
log()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
info() { [ "$QUIET" = 1 ] || printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR ] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
	cat <<EOF
$PROG - 用脚本自己的 igmpproxy.conf 接管 IGMP 代理 (TX-AX6000 / TUF-AX6000, MT798X)

命令:
  check            只检查/诊断, 不做任何改动 (默认命令)
  conf             只在工作目录生成 igmpproxy.conf, 不启动服务
  up               生成配置并拉起 igmpproxy (含防火墙放行/rp_filter)
  down             停止脚本拉起的 igmpproxy, 撤销脚本加的规则与 rp_filter
  restart          = down + up
  status           显示当前状态(自身功能开关/配置/进程/规则/rp_filter), 并做自检
  fwcheck          只做防火墙/rp_filter 自检(不添加规则、不改内核参数)
  rules            只补防火墙放行规则与 rp_filter(不写配置、不动 igmpproxy)
                   —— 给外部守护脚本用(例: koolcenter 插件的 start_nat 钩子)
  run              前台运行 igmpproxy 本身(exec 掉本脚本), 交给 perp 之类的
                   进程管理器看住: 挂了立刻重拉, 不需要守护脚本常驻
  help             显示本帮助

选项:
  -u, --upstream IF    上游接口(IPTV/WAN 侧), 默认自动探测
  -d, --downstream IF  下游接口(局域网侧), 默认 nvram lan_ifname 或 br0
  -a, --altnet NET     上游允许的组播源网段, 默认 0.0.0.0/0 (可空格分隔多个)
  -w, --workdir DIR    脚本工作目录, 默认脚本所在目录
  -c, --conf FILE      配置文件路径, 默认 <工作目录>/igmpproxy.conf
      --state-dir DIR  运行状态目录, 默认 $STATE_DIR
      --log FILE       日志文件(debug 模式), 默认 <状态目录>/igmpproxy.log
      --iptables FILE  iptables 路径(默认自动探测: PATH 与 /usr/sbin /sbin /usr/bin /bin)
      --no-quickleave  配置里不写 quickleave
      --no-firewall    不添加组播放行规则
      --no-rp-filter   不调整上游接口的 rp_filter
      --force          强制接管(会结束非本脚本拉起的 igmpproxy)
      --release-mc-router
                       启动前停掉固件自带的组播进程(mcpd)。Broadcom 机型
                       的 mcpd 会常驻占用 IGMP(0.0.0.0:2)，不释放就起不来
      --debug          前台调试模式(igmpproxy -d -v -v, 输出到日志)
  -n, --dry-run        只打印将要执行的操作, 不落地
  -q, --quiet          安静模式

退出码:
  0 成功 / 1 用法或环境错误 / 2 路由器自身组播路由已启用(需用户去页面关闭)
  3 已被其它 igmpproxy 占用(需 --force) / 4 启动失败
  fwcheck 专用: 0 自检通过 / 1 规则缺失或组播会被更靠前的丢弃规则拦掉

示例:
  sh $PROG check
  sh $PROG up --upstream eth1.2 --altnet 10.0.0.0/8
  sh $PROG up -u vlan2 -d br0
  sh $PROG fwcheck                         # 排查"起了但收不到流"时先跑这个
  sh $PROG run --upstream eth1.2          # 前台运行, 交给 perp/进程管理器守护
  sh $PROG down
EOF
	exit 0
}

#------------------------------- 小工具 ----------------------------------------
is_root() {
	[ "$(awk '/^Uid:/{print $2}' /proc/self/status 2>/dev/null)" = "0" ]
}

have() { command -v "$1" >/dev/null 2>&1; }

# 找一个命令的绝对路径: 先按名在 PATH 里找, 再逐个试给出的绝对路径候选。
# 为什么需要它: 部分固件(或非 root 会话)的 PATH 里没有 /usr/sbin, 有些精简 shell 的
# command -v 也不完全可靠, 但 iptables 其实就躺在 /usr/sbin 下 —— 只靠 command -v
# 会误报"找不到 iptables"(实测某 koolcenter 机型就是这样)。
find_cmd() {
	for _fc in "$@"; do
		case "$_fc" in
			*/*)
				if [ -x "$_fc" ]; then printf '%s\n' "$_fc"; return 0; fi
				;;
			*)
				_fp=$(command -v "$_fc" 2>/dev/null)
				if [ -n "$_fp" ] && [ -x "$_fp" ]; then printf '%s\n' "$_fp"; return 0; fi
				;;
		esac
	done
	return 1
}

# iptables 是否可用 (IPT 可能是名字, 也可能是绝对路径)
ipt_ok() {
	case "$IPT" in
		*/*) [ -x "$IPT" ] ;;
		*)   have "$IPT" ;;
	esac
}

NVRAM=$(command -v nvram 2>/dev/null || true)
[ -n "$NVRAM" ] || { [ -x /bin/nvram ] && NVRAM=/bin/nvram; }
nvget() {
	[ -n "$NVRAM" ] || return 0
	"$NVRAM" get "$1" 2>/dev/null
}

iface_exists() { [ -e "/sys/class/net/$1" ]; }

default_iface() {
	_d=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[ -n "$_d" ] || _d=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" && $2=="0.0.0.0"{print $8; exit}')
	printf '%s' "$_d"
}

list_ifaces() {
	ls /sys/class/net 2>/dev/null | grep -v '^lo$' | tr '\n' ' '
}

# 某个接口的 IPv4 地址(可能多个), 用 ip 优先, 退回 ifconfig
iface_addrs() {
	_a=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet /{printf "%s ", $2}')
	[ -n "$_a" ] || _a=$(ifconfig "$1" 2>/dev/null | awk '/inet /{print $2}' | sed 's/^addr://' | tr '\n' ' ')
	printf '%s' "$_a"
}

# 接口 + 地址明细: 用户报"上游该填什么"时最能说明问题
list_ifaces_detail() {
	for _i in $(list_ifaces); do
		printf '        %-14s %s\n' "$_i" "$(iface_addrs "$_i")"
	done
}

# 判断当前是不是跑在路由器固件上(而不是 PC), 用于给出不同的提示
on_router() {
	[ -n "$NVRAM" ] || return 1
	[ -d /jffs ] || [ -f /tmp/syslog.log ] || [ -x /sbin/rc ]
}

# 真·igmpproxy 进程判定: /proc/<pid>/cmdline 的第一个参数(可执行文件) basename 必须是 igmpproxy。
# 为什么不能只靠 pidof: 部分固件(实测某 koolcenter 机器)的 pidof 是按 cmdline 子串匹配的,
# 会把本脚本自己 "sh igmpproxy-takeover.sh check"、甚至同一条 ps|grep|awk 管道里的
# grep/awk 都当成 igmpproxy 列出来 —— 那样 --force 就可能误杀无关进程。
is_igmp_exec() {
	_c=$(pid_cmdline "$1")
	[ -n "$_c" ] || return 1
	set -- $_c
	case "${1##*/}" in
		igmpproxy) return 0 ;;
		*) return 1 ;;
	esac
}

list_igmp_pids() {
	for _d in /proc/[0-9]*; do
		_p=${_d#/proc/}
		[ "$_p" = "$$" ] && continue
		[ -n "${PPID:-}" ] && [ "$_p" = "$PPID" ] && continue
		is_igmp_exec "$_p" && printf '%s\n' "$_p"
	done
}

# 读取某个 pid 的命令行 (NUL 换成空格)。
# 注意: 必须用 cat 读, 不能写成 `tr ... < /proc/$1/cmdline` —— 进程若在 pidof 与本次
# 读取之间退出, 重定向是 shell 自己做的, 报错不会被命令自身的 2>/dev/null 吞掉,
# 会直接打到终端 (形如: can't open /proc/1234/cmdline: no such file)。
pid_cmdline() {
	[ -d "/proc/$1" ] || return 0
	cat "/proc/$1/cmdline" 2>/dev/null | tr '\0' ' '
}

is_ours() {
	[ -n "${CONF:-}" ] || return 1
	pid_cmdline "$1" 2>/dev/null | grep -F -q -- "$CONF"
}

# 按 argv[0] 的基名找进程。不能用 pidof: 本机 pidof 是 cmdline 子串匹配,
# 会把本脚本自己、甚至 ps|grep 管道里的字都当成目标进程。
pids_by_name() {
	for _d in /proc/[0-9]*; do
		_p=${_d#/proc/}
		[ "$_p" = "$$" ] && continue
		_c=$(pid_cmdline "$_p")
		[ -n "$_c" ] || continue
		_a0=${_c%% *}
		[ "${_a0##*/}" = "$1" ] && printf '%s\n' "$_p"
	done
}

# IGMP raw socket 是否已被占用(本地地址 0.0.0.0:0002)
igmp_raw_busy() {
	[ -f /proc/net/raw ] || return 1
	grep -q "00000000:0002" /proc/net/raw 2>/dev/null
}

# Broadcom/HND 机型(GT-AC5300 等)的固件组播转发进程 /bin/mcpd 开机就占着 IGMP
# raw socket, 即使 mr_enable_x=0 也不释放; 它和 igmpproxy 互斥, 不释放新实例
# 必然以 Errno(98) 立刻退出。只在 --release-mc-router 时才动它。
release_mc_holders() {
	[ "$RELEASE_MC" = 1 ] || return 0
	_f=""
	for _n in $MC_HOLDER_NAMES; do
		for _p in $(pids_by_name "$_n"); do _f="${_f} ${_p}"; done
	done
	[ -n "${_f}" ] || return 0
	info "释放 IGMP 占用: 停掉固件自带的组播进程(pid$(printf '%s' "${_f}" | tr '\n' ' '))"
	[ "$DRYRUN" = 1 ] && return 0
	for _p in ${_f}; do kill "$_p" 2>/dev/null; done
	_i=0
	while [ ${_i} -lt 5 ]; do
		_alive=0
		for _p in ${_f}; do [ -d "/proc/${_p}" ] && _alive=1; done
		[ "${_alive}" = 0 ] && break
		_i=$((_i + 1))
		sleep 1
	done
	for _p in ${_f}; do [ -d "/proc/${_p}" ] && kill -9 "$_p" 2>/dev/null; done
	igmp_raw_busy && warn "IGMP raw socket(0.0.0.0:2) 仍被占用, 若不是本实例请检查其它组播程序"
	return 0
}

show_pids() { # 用法: show_pids "ours"|"foreign"
	_case=$1
	for _p in $(list_igmp_pids); do
		if is_ours "$_p"; then _mine=1; else _mine=0; fi
		if { [ "$_case" = "ours" ] && [ "$_mine" = 1 ]; } || { [ "$_case" = "foreign" ] && [ "$_mine" = 0 ]; }; then
			printf '%s\n' "$_p"
		fi
	done
}

tail_logs() {
	if [ -f "$LOG" ]; then
		warn "日志尾部 ($LOG):"
		tail -n 20 "$LOG" >&2
	fi
	for _f in /tmp/syslog.log /tmp/messages; do
		if [ -f "$_f" ]; then
			_l=$(grep -i igmpproxy "$_f" 2>/dev/null | tail -n 6)
			[ -n "$_l" ] && { warn "系统日志中的 igmpproxy 记录 ($_f, 最后 6 行):"; printf '%s\n' "$_l" >&2; }
		fi
	done
}

path_setup() {
	[ -n "$CONF" ] || CONF="$WORKDIR/igmpproxy.conf"
	[ -n "$LOG" ] || LOG="$STATE_DIR/igmpproxy.log"
	PIDFILE="$STATE_DIR/igmpproxy.pid"
	RULES_BAK="$STATE_DIR/rules.added"
	RP_BAK="$STATE_DIR/rp_filter.saved"
	# iptables: 只在没给绝对路径时才自动探测(名字 + 常见位置)
	case "$IPT" in
		*/*) : ;;
		*)
			_it=$(find_cmd iptables /usr/sbin/iptables /sbin/iptables /usr/bin/iptables /bin/iptables \
				/usr/sbin/iptables-legacy /sbin/iptables-legacy 2>/dev/null)
			[ -n "$_it" ] && IPT=$_it
			;;
	esac
}

#------------------------------- 参数解析 --------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		check|conf|up|down|restart|status|fwcheck|rules|run)
			CMD=$1; shift ;;
		help|-h|--help)
			CMD=help; shift ;;
		-u|--upstream)   UPSTREAM=$2; shift 2 ;;
		--upstream=*)    UPSTREAM=${1#*=}; shift ;;
		-d|--downstream) DOWNSTREAM=$2; shift 2 ;;
		--downstream=*)  DOWNSTREAM=${1#*=}; shift ;;
		-a|--altnet)     ALTNET=$2; shift 2 ;;
		--altnet=*)      ALTNET=${1#*=}; shift ;;
		-w|--workdir)    WORKDIR=$2; shift 2 ;;
		--workdir=*)     WORKDIR=${1#*=}; shift ;;
		-c|--conf)       CONF=$2; shift 2 ;;
		--conf=*)        CONF=${1#*=}; shift ;;
		--state-dir)     STATE_DIR=$2; shift 2 ;;
		--state-dir=*)   STATE_DIR=${1#*=}; shift ;;
		--log)           LOG=$2; shift 2 ;;
		--log=*)         LOG=${1#*=}; shift ;;
		--iptables)      IPT=$2; shift 2 ;;
		--iptables=*)    IPT=${1#*=}; shift ;;
		--no-quickleave) QUICKLEAVE=0; shift ;;
		--no-firewall)   FIREWALL=0; shift ;;
		--no-rp-filter)  RPFILTER=0; shift ;;
		--force)         FORCE=1; shift ;;
		--release-mc-router) RELEASE_MC=1; shift ;;
		--debug)         DEBUG=1; shift ;;
		-n|--dry-run)    DRYRUN=1; shift ;;
		-q|--quiet)      QUIET=1; shift ;;
		--)              shift; break ;;
		-*)              err "未知选项: $1"; usage ;;
		*)               err "未知命令: $1"; usage ;;
	esac
done

path_setup

#===============================================================================
# 1) 路由器自身功能检测 —— 本脚本只做提示, 绝不替用户改 nvram
#===============================================================================
check_router_feature() {
	_mr=$(nvget mr_enable_x)
	_ud=$(nvget udpxy_enable_x)
	_stb=$(nvget switch_stb_x)
	_want=$(nvget switch_wantag)

	if [ -z "$NVRAM" ]; then
		warn "未找到 nvram, 跳过“路由器自身组播路由”检测(仅适合在 PC 上做语法验证)"
		return 0
	fi
	[ -n "$_mr" ] || _mr=0

	if [ "$_mr" != "0" ]; then
		err "路由器自身的 IGMP 代理(组播路由)已启用: mr_enable_x=$_mr"
		cat >&2 <<EOF

  ==> 请先到设置页面把对应选项关掉, 然后重新运行本脚本:

      页面: 高级设置 → 局域网(LAN) → IPTV 标签页   (Advanced_IPTV_Content.asp)
      选项: 「启动组播路由」                       → 选择「关闭」→ 应用

      为什么必须关闭:
        * 只要 mr_enable_x 非 0, rc/wan.c 的 start_igmpproxy() 就会自己生成
          $ROUTER_CONF 并以 /usr/sbin/igmpproxy 启动一份实例; IGMP 代理只能有一个,
          两个实例抢 IGMP/mroute 会互相踢掉。
        * 该页面原文提示也说明了: “此功能仅在首选 WAN 下运行。” 以及
          “Due to hardware limitation, IGMP proxy cannot co-exist with IPTV function.”
        * 现网状态: switch_stb_x=${_stb:-?}, switch_wantag=${_want:-?}
          如果这个下拉框被当前 ISP 配置文件顶掉(看不见/点不动), 可在终端执行:
              nvram set mr_enable_x=0 ; nvram commit ; reboot
          或先把 ISP 配置改成「无 / 手动设置」再关闭该项。
        * 另外 udpxy_enable_x=${_ud:-0}; udpxy 非 0 时同样会占用上游接口, 建议在同一页面一并关掉。
        * 关闭后 rc 不会再拉起 igmpproxy(wan.c 里 !mr_enable_x 直接 return), 脚本接管才不会打架;
          关闭后重新运行:  sh $PROG up

EOF
		return 2
	fi
	info "路由器自身组播路由未启用 (mr_enable_x=0), 可以接管"
	[ "${_ud:-0}" != "0" ] && warn "udpxy_enable_x=$_ud 非 0: udpxy 会占用上游接口, 可能与脚本的 igmpproxy 争用, 建议关闭"
	if [ -n "${_stb:-}" ] && [ "$_stb" -gt 6 ] 2>/dev/null; then
		info "switch_stb_x=$_stb (>6): IPTV 配置生效, rc 自身不会拉起 igmpproxy (wan.c start_igmpproxy 里直接 return)"
	fi
	return 0
}

#===============================================================================
# 2) 占用检测 —— 已有别人拉起的 igmpproxy
#===============================================================================
check_foreign() {
	_f=$(show_pids foreign)
	[ -n "$_f" ] || return 0
	if [ "$FORCE" != 1 ]; then
		err "已存在非本脚本拉起的 igmpproxy 进程(配置不是 $CONF):"
		_router=0
		for _p in $_f; do
			_cl=$(pid_cmdline "$_p")
			printf '        pid %-6s %s\n' "$_p" "$_cl" >&2
			case "$_cl" in *"$ROUTER_CONF"*) _router=1 ;; esac
		done
		if [ "$_router" = 1 ]; then
			cat >&2 <<EOF

  ==> 有一个实例用的是路由器自己的配置 $ROUTER_CONF, 说明 mr_enable_x 大概率仍非 0:
      请先去设置页面关闭「启动组播路由」, 再运行:
             sh $PROG up --force

EOF
		else
			cat >&2 <<EOF

  ==> 这些实例都不是路由器 rc 用 $ROUTER_CONF 拉起的
      (常见: 你之前手工执行过 /usr/sbin/igmpproxy <配置>, 或某个插件拉起的)。
      确认可以停掉后, 二选一:
        a) 先手工停掉: kill $(printf '%s' "$_f" | tr '\n' ' ')
        b) 或让脚本强制接管: sh $PROG up --force

EOF
		fi
		return 3
	fi
	warn "--force: 结束已存在的 igmpproxy 进程: $(printf '%s' "$_f" | tr '\n' ' ')"
	if [ "$DRYRUN" != 1 ]; then
		kill $_f 2>/dev/null
		sleep 1
		for _p in $_f; do kill -9 "$_p" 2>/dev/null; done
	fi
	return 0
}

#===============================================================================
# 3) 接口解析
#===============================================================================
# 上游选成 PPPoE 虚接口时的一个高频坑：很多省份的 IPTV 组播并不在 PPPoE 会话里，
# 而在 WAN 以太口/VLAN 上。这段提示既要在生成配置时打，也要出现在诊断日志里
# (插件弹窗现在只在失败时展开细节，用户平时靠「诊断日志」看现场)，所以抽出来共用。
pppoe_hint() {
	_pu=$1
	_wan=$(nvget wan0_ifname); [ -n "$_wan" ] || _wan=$(nvget wan_ifname)
	warn "上游接口 $_pu 是 PPPoE 虚接口: 只有当运营商把组播/IGMP 也封装在这个 PPPoE 会话里时, 它才是对的;"
	warn "  多数省份的 IPTV 组播走 WAN 以太口/VLAN, 那种情况应改成 -u ${_wan:-<下层以太口>}"
	if [ -n "$_wan" ] && iface_exists "$_wan"; then
		warn "  本机下层 WAN 口是 $_wan, 可先用 -u $_wan 试; 若不通再换回 -u $_pu"
	fi
	warn "  判断方法(有 tcpdump 时): 播放一个频道, 看 $_pu 与 ${_wan:-下层口} 哪个口有 IGMP/224.x 流量"
	warn "  不看抓包也行: 播放频道后跑 iptables -L -n -v | grep $TAG —— 计数在增长的那个口才是对的"
}

resolve_ifaces() {
	_explicit=0
	[ -n "$UPSTREAM" ] && _explicit=1
	if [ -z "$UPSTREAM" ]; then
		# 运营商专网模式(switch_stb_x>6): IPTV 组播走单独的 iptv_ifname,
		# 组播源只挂在这个口上(见 rc/wan.c:525-529 与 rc/sysdeps/init-ralink.c:1120-1133),
		# 所以优先把它当上游, 而不是默认路由口(PPPoE 下就是 ppp0)。
		_stb=$(nvget switch_stb_x)
		_iptv=$(nvget iptv_ifname)
		if [ -n "$_stb" ] && [ "$_stb" -gt 6 ] 2>/dev/null && [ -n "$_iptv" ] && iface_exists "$_iptv"; then
			UPSTREAM=$_iptv
			info "switch_stb_x=$_stb (运营商专网模式), 上游自动选为 iptv_ifname=$_iptv"
		fi
	fi
	if [ -z "$UPSTREAM" ]; then
		_u=$(nvget wan_ifname)
		if [ -z "$_u" ] || ! iface_exists "$_u"; then
			_u2=$(nvget wan0_ifname)
			if [ -n "$_u2" ] && iface_exists "$_u2"; then _u=$_u2; fi
		fi
		if [ -z "$_u" ] || ! iface_exists "$_u"; then
			_u=$(default_iface)
		fi
		UPSTREAM=$_u
	fi
	if [ -z "$DOWNSTREAM" ]; then
		_d=$(nvget lan_ifname)
		[ -n "$_d" ] || _d=br0
		DOWNSTREAM=$_d
	fi

	if [ -z "$UPSTREAM" ]; then
		err "无法自动确定上游接口, 请用 --upstream IF 指定"
		warn "当前可用接口: $(list_ifaces)"
		return 1
	fi
	if ! iface_exists "$UPSTREAM"; then
		err "上游接口不存在: $UPSTREAM"
		warn "当前可用接口: $(list_ifaces)"
		return 1
	fi
	if ! iface_exists "$DOWNSTREAM"; then
		err "下游接口不存在: $DOWNSTREAM"
		warn "当前可用接口: $(list_ifaces)"
		return 1
	fi
	if [ "$UPSTREAM" = "$DOWNSTREAM" ]; then
		err "上游和下游不能是同一个接口: $UPSTREAM"
		return 1
	fi
	case "$UPSTREAM" in
		ppp*|pppoe*) pppoe_hint "$UPSTREAM" ;;
	esac
	# 自动探测时补一句: 默认路由是 PPPoE 虚接口, 而脚本选的是它的下层以太口, 两者都可能是对的
	if [ "$_explicit" != 1 ]; then
		_def=$(default_iface)
		case "$_def" in
			ppp*|pppoe*)
				[ "$UPSTREAM" = "$_def" ] || info "提示         : 默认路由是 $_def (PPPoE), 脚本自动选的是 $UPSTREAM; 若运营商把组播封装在 PPPoE 会话里, 请用 -u $_def (播放频道后看规则计数是否增长)" ;;
		esac
	fi
	info "上游(upstream)=$UPSTREAM   下游(downstream)=$DOWNSTREAM"
	return 0
}

#===============================================================================
# 4) 生成配置文件
#===============================================================================
conf_write() {
	_tmp="$CONF.tmp.$$"
	mkdir -p "$WORKDIR" 2>/dev/null
	{
		printf '# igmpproxy.conf - 由 %s 生成, %s\n' "$PROG" "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '# 上游: %s   下游: %s   格式与 rc/wan.c start_igmpproxy() 一致\n' "$UPSTREAM" "$DOWNSTREAM"
		if [ "$QUICKLEAVE" = 1 ]; then printf 'quickleave\n'; fi
		printf 'phyint %s upstream ratelimit 0 threshold 1 altnet %s\n' "$UPSTREAM" "$ALTNET"
		printf 'phyint %s downstream ratelimit 0 threshold 1\n' "$DOWNSTREAM"
	} > "$_tmp" 2>/dev/null || { err "无法写入临时配置: $_tmp"; return 1; }

	if [ "$DRYRUN" = 1 ]; then
		info "[dry-run] 将写入 $CONF:"
		[ "$QUIET" = 1 ] || sed 's/^/        /' "$_tmp"
		rm -f "$_tmp"
		return 0
	fi
	chmod 644 "$_tmp" 2>/dev/null
	mv "$_tmp" "$CONF" || { err "无法生成配置: $CONF"; return 1; }
	info "已生成配置: $CONF"
	return 0
}

#===============================================================================
# 5) 上游 rp_filter —— 与 rc/firewall.c:7414 同策略: 只对「非默认 WAN 接口」关掉
#===============================================================================
rp_apply() {
	if [ "$RPFILTER" != 1 ]; then info "--no-rp-filter: 跳过 rp_filter 调整"; return 0; fi
	_def=$(default_iface)
	if [ -n "$_def" ] && [ "$UPSTREAM" = "$_def" ]; then
		info "上游即默认 WAN 接口($UPSTREAM), 按 rc 的做法不关 rp_filter"
		return 0
	fi
	_f="/proc/sys/net/ipv4/conf/$UPSTREAM/rp_filter"
	[ -f "$_f" ] || return 0
	_cur=$(cat "$_f" 2>/dev/null)
	if [ "$_cur" = "0" ]; then info "$UPSTREAM 的 rp_filter 已是 0, 无需调整"; return 0; fi
	if [ "$DRYRUN" = 1 ]; then info "[dry-run] echo 0 > $_f   (原值 $_cur)"; return 0; fi
	mkdir -p "$STATE_DIR" 2>/dev/null
	grep -q "^$UPSTREAM " "$RP_BAK" 2>/dev/null || printf '%s %s\n' "$UPSTREAM" "$_cur" >> "$RP_BAK"
	if printf '0' > "$_f" 2>/dev/null; then
		info "$UPSTREAM 的 rp_filter: $_cur -> 0 (已记录原值, down 时恢复)"
	else
		warn "无法将 $UPSTREAM 的 rp_filter 改为 0 (可能权限不足)"
	fi
	return 0
}

rp_restore() {
	[ -f "$RP_BAK" ] || return 0
	while read -r _if _v; do
		[ -n "$_if" ] && [ -n "$_v" ] || continue
		_f="/proc/sys/net/ipv4/conf/$_if/rp_filter"
		if [ -f "$_f" ]; then
			if [ "$DRYRUN" = 1 ]; then info "[dry-run] echo $_v > $_f"
			else printf '%s' "$_v" > "$_f" 2>/dev/null && info "$_if 的 rp_filter 已恢复为 $_v"; fi
		fi
	done < "$RP_BAK"
	[ "$DRYRUN" = 1 ] || rm -f "$RP_BAK"
	return 0
}

# rp_filter 自检 (只读)。
# 内核里 IN_DEV_RPFILTER = max(conf/<if>/rp_filter, conf/all/rp_filter):
#   linux-5.4.x/include/linux/inetdevice.h:99 `IN_DEV_MAXCONF((in_dev), RP_FILTER)`,
#   所以 conf/all/rp_filter 非 0 时, 即使接口值是 0, 有效值仍可能非 0 (严格反查)。
# rc/firewall.c:7443-7457 把 all 写 -1、只给组播接口写 0, 正是按这个"取最大"语义来的。
rp_check() {
	_f="/proc/sys/net/ipv4/conf/$UPSTREAM/rp_filter"
	_ifv=$(cat "$_f" 2>/dev/null)
	if [ -z "$_ifv" ]; then
		warn "rp_filter 自检: 读不到 $_f (接口不存在或无权限), 跳过"
		return 0
	fi
	_allv=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)
	[ -n "$_allv" ] || _allv=0
	case "$_ifv$_allv" in
		*[!0-9-]*) warn "rp_filter 自检: 值异常 (iface=$_ifv all=$_allv), 跳过"; return 0 ;;
	esac
	_eff=$(awk -v a="$_ifv" -v b="$_allv" 'BEGIN{m=(a>b)?a:b; if(m<0)m=0; print m}')
	if [ "$_eff" = "0" ]; then
		info "rp_filter 自检: OK ($UPSTREAM=$_ifv, all=$_allv, 有效值 0)"
		return 0
	fi
	_def=$(default_iface)
	warn "rp_filter 自检: 上游 $UPSTREAM 的有效值 = max(iface=$_ifv, all=$_allv) = $_eff (非 0)"
	warn "  说明: 组播报文本身一般不做反向路径检查, 但非对称路径上的单播(IPTV 单播流/回程)会被丢;"
	warn "        ASUS 自己在启用组播路由时会把组播接口置 0(rc/firewall.c:7443-7457), 脚本按同一策略提示"
	warn "  若没遇到'上游有流、下游不通', 可以不管这一条"
	[ "$UPSTREAM" = "$_def" ] && warn "  (上游就是默认路由接口 $_def, 脚本按 rc/firewall.c:7453 的做法没有动它)"
	warn "  可执行: echo 0 > $_f"
	if [ "$_allv" -gt 0 ] 2>/dev/null; then
		warn "  注意 conf/all/rp_filter=$_allv 也参与取最大值, 需一并: echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter"
	fi
	return 1
}

#===============================================================================
# 6) 防火墙放行 —— 复刻 rc/firewall.c 里被 mr_enable_x 门控的那几条
#===============================================================================
fw_present() {
	_chain=$1; shift
	"$IPT" -C "$_chain" "$@" >/dev/null 2>&1
}

fw_add() {
	_chain=$1; shift
	if fw_present "$_chain" "$@"; then info "防火墙规则已存在: $_chain $*"; return 0; fi
	if [ "$DRYRUN" = 1 ]; then info "[dry-run] $IPT -I $_chain 1 $*"; return 0; fi
	if "$IPT" -I "$_chain" 1 "$@"; then
		info "已放行: -I $_chain $*"
		printf '%s %s\n' "$_chain" "$*" >> "$RULES_BAK"
	else
		warn "添加防火墙规则失败: $_chain $*"
		return 1
	fi
	return 0
}

fw_del() {
	_chain=$1; shift
	_n=0
	while [ "$_n" -lt 5 ]; do
		fw_present "$_chain" "$@" || break
		if [ "$DRYRUN" = 1 ]; then info "[dry-run] $IPT -D $_chain $*"; break; fi
		"$IPT" -D "$_chain" "$@" || break
		_n=$((_n + 1))
	done
	[ "$_n" -gt 0 ] && info "已删除: -D $_chain $*"
	return 0
}

fw_apply() {
	if [ "$FIREWALL" != 1 ]; then info "--no-firewall: 跳过组播放行规则"; return 0; fi
	if ! ipt_ok && [ "$DRYRUN" != 1 ]; then
		warn "找不到 iptables ($IPT), 跳过防火墙放行(上游组播/IGMP 可能被丢弃)"
		warn "  已试过: PATH 里的 iptables 与 /usr/sbin /sbin /usr/bin /bin 下的 iptables"
		warn "  可用 --iptables /绝对路径 手工指定"
		return 0
	fi
	if ! is_root && [ "$DRYRUN" != 1 ]; then warn "非 root, 防火墙规则可能添加失败"; fi
	mkdir -p "$STATE_DIR" 2>/dev/null
	_fwrc=0
	fw_add INPUT   -p 2   -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:in-igmp"     || _fwrc=1
	fw_add INPUT   -p udp -d 224.0.0.0/4 ! --dport 1900 -j ACCEPT -m comment --comment "$TAG:in-mcast" || _fwrc=1
	fw_add FORWARD -p udp -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:fwd-mcast"  || _fwrc=1
	return $_fwrc
}

fw_remove() {
	if ! ipt_ok && [ "$DRYRUN" != 1 ]; then return 0; fi
	fw_del INPUT   -p 2   -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:in-igmp"
	fw_del INPUT   -p udp -d 224.0.0.0/4 ! --dport 1900 -j ACCEPT -m comment --comment "$TAG:in-mcast"
	fw_del FORWARD -p udp -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:fwd-mcast"
	[ "$DRYRUN" = 1 ] || rm -f "$RULES_BAK"
	return 0
}

# 三条规则是否都还在 (防火墙重载会被清掉, 需要重新补上)
fw_rules_ok() {
	[ "$FIREWALL" = 1 ] || return 0
	ipt_ok || return 0
	fw_present INPUT   -p 2   -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:in-igmp"   || return 1
	fw_present INPUT   -p udp -d 224.0.0.0/4 ! --dport 1900 -j ACCEPT -m comment --comment "$TAG:in-mcast" || return 1
	fw_present FORWARD -p udp -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:fwd-mcast"  || return 1
	return 0
}

# 取一条链里「第一条允许 224.0.0.0/4 的规则」与「第一条丢弃类规则」的行号。
# 丢弃类 = 目标以 DROP/REJECT 结尾(含 rc/firewall.c 自定义的 logdrop/logreject)。
# 只有放行排在丢弃之前, 组播才真的过得去 (rc/firewall.c 的默认策略是 DROP)。
fw_chain_lines() {
	"$IPT" -L "$1" -n --line-numbers 2>/dev/null | awk '
		$1 ~ /^[0-9]+$/ {
			if ($2 ~ /(DROP|REJECT|drop|reject)$/) { if (drop == 0) drop = $1 }
			else if ($2 ~ /(ACCEPT|accept)$/ && index($0, "224.0.0.0/4")) { if (allow == 0) allow = $1 }
		}
		END { print allow + 0, drop + 0 }'
}

# 规则计数器 (仅提示): 规则上有没有流量经过。pkts 一直是 0 说明流没上来。
# iptables -L -n -v 的原始行很长(约 130 列), 日志框放不下会被裁掉, 只挑三样印出来。
fw_counters() {
	"$IPT" -L -n -v 2>/dev/null | grep -F -- "$TAG" | while read -r _p _b _rest; do
		_t=$(printf '%s' "$_rest" | sed -n "s#.*${TAG}:\([^ ]*\).*#\1#p")
		printf '    %-12s pkts %-10s bytes %s\n' "${_t:-?}" "$_p" "$_b"
	done
}

# 防火墙 / rp_filter 自检。只读, 不改动任何东西。检查:
#   1) 脚本那三条放行规则是否都在 (防火墙重载 iptables-restore 会整表刷掉)
#   2) INPUT/FORWARD 里组播放行是否排在第一个丢弃类规则之前
#   3) rp_filter 有效值 (见 rp_check)
# 返回 0 = 通过, 1 = 有问题。
fw_verify() {
	if [ "$DRYRUN" = 1 ]; then
		info "自检: [dry-run] 本次没有真正改规则, 跳过(真实执行 up 后再看)"
		return 0
	fi
	_rc=0
	if [ "$FIREWALL" != 1 ]; then
		info "自检: --no-firewall 模式, 跳过防火墙检查"
	elif ! ipt_ok; then
		warn "自检: 找不到 iptables ($IPT), 无法检查防火墙"
		warn "  已试过: PATH 里的 iptables 与 /usr/sbin /sbin /usr/bin /bin 下的 iptables"
		warn "  当前 PATH=$PATH"
		warn "  若 iptables 在别处: sh $PROG fwcheck --iptables /绝对路径/iptables"
		_rc=1
	else
		_i=0
		fw_present INPUT   -p 2   -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:in-igmp"   && _i=$((_i + 1))
		fw_present INPUT   -p udp -d 224.0.0.0/4 ! --dport 1900 -j ACCEPT -m comment --comment "$TAG:in-mcast" && _i=$((_i + 1))
		fw_present FORWARD -p udp -d 224.0.0.0/4 -j ACCEPT -m comment --comment "$TAG:fwd-mcast"  && _i=$((_i + 1))
		if [ "$_i" = 3 ]; then
			info "自检: 本脚本的 3 条放行规则都在位"
		else
			warn "自检: 本脚本的放行规则只有 $_i/3 条在位 (可能被防火墙重载清掉了)"
			warn "  修: sh $PROG up    (守护进程下次重拉时也会自动补规则)"
			_rc=1
		fi
		for _chain in INPUT FORWARD; do
			set -- $(fw_chain_lines "$_chain")
			_allow=$1
			_drop=$2
			if [ "$_allow" = 0 ]; then
				if [ "$_drop" != 0 ]; then
					warn "自检: $_chain 里没有允许 224.0.0.0/4 的规则, 第 $_drop 行起就是丢弃类规则 -> 组播会被丢"
				else
					warn "自检: $_chain 里没读到允许 224.0.0.0/4 的规则 -> 组播可能被默认策略丢掉"
				fi
				warn "  看: $IPT -L $_chain -n --line-numbers"
				_rc=1
			elif [ "$_drop" != 0 ] && [ "$_drop" -lt "$_allow" ]; then
				warn "自检: $_chain 里第 $_drop 行是丢弃类规则, 排在组播放行(第 $_allow 行)之前 -> 组播可能被拦"
				warn "  看: $IPT -L $_chain -n --line-numbers"
				_rc=1
			else
				info "自检: $_chain 组播放行在第 $_allow 行, 首个丢弃类规则在第 $_drop 行 (顺序 OK)"
			fi
		done
		_cnt=$(fw_counters)
		if [ -n "$_cnt" ]; then
			info "自检: 规则计数(pkts/bytes, 长期为 0 说明流量没到):"
			printf '%s\n' "$_cnt"
		fi
	fi
	rp_check || _rc=1
	return $_rc
}

#===============================================================================
# 7) 启动 / 停止 igmpproxy
#===============================================================================
ours_running() {
	[ -n "$(show_pids ours)" ]
}

stop_ours() {
	_f=$(show_pids ours)
	[ -n "$_f" ] || { [ -f "$PIDFILE" ] && [ "$DRYRUN" != 1 ] && rm -f "$PIDFILE"; return 0; }
	info "停止脚本拉起的 igmpproxy: $(printf '%s' "$_f" | tr '\n' ' ')"
	if [ "$DRYRUN" != 1 ]; then
		kill $_f 2>/dev/null
		sleep 1
		for _p in $_f; do
			if [ -d "/proc/$_p" ]; then kill -9 "$_p" 2>/dev/null; fi
		done
		rm -f "$PIDFILE"
	fi
	return 0
}

# 启动失败时的一个高频成因: 上游口没有 IPv4 地址(挂在内网桥里的交换口, 或者还没拨上号的
# PPPoE 口)。igmpproxy 只会甩一句 "There must be at least 2 Vif's where one is upstream."
# 就退出, 看着和 IGMP 毫无关系, 这里把它点破。
diag_upstream_hint() {
	_u=$(awk '/^phyint /{for(i=2;i<=NF;i++) if($i=="upstream"){print $2; exit}}' "$CONF" 2>/dev/null)
	[ -n "$_u" ] || return 0
	if ! iface_exists "$_u"; then
		warn "上游接口 $_u 在本机不存在; 当前可用: $(list_ifaces | tr '\n' ' ')"
		return 0
	fi
	if [ -z "$(iface_addrs "$_u")" ]; then
		warn "上游接口 $_u 没有 IPv4 地址: igmpproxy 建不出上游 Vif, 于是报"
		warn "  'There must be at least 2 Vif's where one is upstream.' 然后立刻退出。"
		warn "  请选 WAN 侧已经有地址的接口; 用 PPPoE 拨号口要等拨上号再启动。"
	fi
}

start_proxy() {
	if [ ! -x "$IGMPPROXY_BIN" ] && [ "$DRYRUN" != 1 ]; then
		err "找不到 igmpproxy 可执行文件: $IGMPPROXY_BIN"
		return 4
	fi
	if [ "$DRYRUN" = 1 ]; then info "[dry-run] $IGMPPROXY_BIN $CONF"; return 0; fi
	mkdir -p "$STATE_DIR" 2>/dev/null

	# 固件自带的组播进程(mcpd)会占着 IGMP raw socket, 先按需释放
	release_mc_holders

	if [ "$DEBUG" = 1 ]; then
		# -d: Log2Stderr=true, 不 fork, 前台运行; 交给 nohup 放后台并留日志
		: > "$LOG"
		nohup "$IGMPPROXY_BIN" -d -v -v "$CONF" >> "$LOG" 2>&1 &
		sleep 2
	else
		# 默认模式: igmpproxy 自己 fork 成守护进程(igmpproxy.c:129),
		# 注意配置文件是「位置参数」而不是 -c 选项
		"$IGMPPROXY_BIN" "$CONF"
		sleep 2
	fi

	_pids=$(show_pids ours)
	if [ -z "$_pids" ]; then
		err "igmpproxy 启动失败或启动后立即退出 (conf=$CONF)"
		diag_upstream_hint
		tail_logs
		return 4
	fi
	printf '%s\n' "$_pids" > "$PIDFILE"
	info "igmpproxy 已启动: pid=$(printf '%s' "$_pids" | tr '\n' ' ')  conf=$CONF"
	return 0
}

#===============================================================================
# 命令实现
#===============================================================================
do_check() {
	path_setup
	info "== 检查: 本脚本配置 =="
	info "脚本目录 : $SELFDIR"
	info "工作目录 : $WORKDIR"
	info "配置文件 : $CONF"
	info "状态目录 : $STATE_DIR"
	[ -n "$NVRAM" ] && info "nvram    : $NVRAM" || warn "未找到 nvram"
	info "igmpproxy: $IGMPPROXY_BIN $([ -x "$IGMPPROXY_BIN" ] && echo '(存在)' || echo '(不存在, 在 PC 上运行时正常)')"
	info "iptables : $IPT $(ipt_ok && echo '(可用)' || echo '(找不到! 用 --iptables 指定)')"
	log ""

	info "== 检查: 路由器自身开关 =="
	if [ -n "$NVRAM" ]; then
		for _k in mr_enable_x mr_qleave_x mr_altnet_x udpxy_enable_x switch_stb_x switch_wantag iptv_ifname lan_ifname wan_ifname wan0_ifname; do
			printf '  %-18s = %s\n' "$_k" "$(nvget "$_k")"
		done
		log ""
	fi

	check_router_feature
	_rc=$?
	if [ "$_rc" = 2 ]; then return 2; fi

	info "== 检查: 进程占用 =="
	_all=$(list_igmp_pids)
	if [ -z "$_all" ]; then
		info "当前没有 igmpproxy 在运行"
	else
		for _p in $_all; do
			if is_ours "$_p"; then _tag="[本脚本]"; else _tag="[其它来源]"; fi
			printf '  pid %-6s %s %s\n' "$_p" "$_tag" "$(pid_cmdline "$_p")"
		done
	fi
	log ""

	info "== 检查: 上游探测 =="
	info "默认路由接口 : $(default_iface)"
	info "可用接口     : $(list_ifaces)"
	[ -n "$UPSTREAM" ] || { info "接口地址明细 :"; list_ifaces_detail; }
	resolve_ifaces || return 1
	if [ -f "$CONF" ]; then
		log ""
		info "== 当前配置文件内容 ($CONF) =="
		sed 's/^/        /' "$CONF"
	fi
	return $?
}

do_conf() {
	resolve_ifaces || return 1
	mkdir -p "$WORKDIR" 2>/dev/null
	conf_write || return 1
	[ "$DRYRUN" = 1 ] || { log ""; sed 's/^/        /' "$CONF"; }
	log ""
	info "配置文件路径: $CONF  (启动命令: $IGMPPROXY_BIN $CONF)"
	return 0
}

do_rules() {
	# 只做配置文件的"配套动作": 防火墙放行 + rp_filter + 自检。
	# 给外部守护脚本用(koolcenter 的 perp 插件、start_nat 钩子等): 它们负责把
	# igmpproxy 前台拉起/看住, 本命令负责它需要的内核与防火墙环境。
	# 注意: 不写配置文件, 也不启动/停止 igmpproxy。
	if [ "$DRYRUN" != 1 ] && ! is_root; then
		err "需要 root 权限才能改防火墙/rp_filter (请在路由器上以管理员运行)"
		return 1
	fi
	resolve_ifaces || return 1
	log "[1/3] 防火墙放行 (INPUT/FORWARD 组播)"
	fw_apply || warn "有防火墙规则没加上, 见上面的告警"
	log "[2/3] 上游 rp_filter"
	rp_apply
	log "[3/3] 自检"
	fw_verify || warn "自检发现问题(组播可能不通), 见上面的告警; 可用 'sh $PROG fwcheck' 单独复查"
	return 0
}

do_up() {
	# 只读检查在前: 即使当前不是 root, 也要先把“该去页面关掉什么”告诉用户
	log "[1/6] 检查路由器自身功能"
	check_router_feature || return 2

	log "[2/6] 检查进程占用"
	check_foreign || return $?

	if [ "$DRYRUN" != 1 ] && ! is_root; then
		err "需要 root 权限才能生成配置/改防火墙/启动 igmpproxy (请在路由器上以管理员运行)"
		return 1
	fi

	log "[3/6] 解析接口"
	resolve_ifaces || return 1

	log "[4/6] 生成配置文件"
	mkdir -p "$WORKDIR" "$STATE_DIR" 2>/dev/null
	conf_write || return 1

	log "[5/6] 防火墙放行 / rp_filter / 自检"
	fw_apply || warn "有防火墙规则没加上, 见上面的告警"
	rp_apply
	fw_verify || warn "自检发现问题(组播可能不通), 见上面的告警; 可用 'sh $PROG fwcheck' 单独复查"

	log "[6/6] 启动 igmpproxy"
	stop_ours
	start_proxy || return $?

	log ""
	info "完成: 已用脚本自己的配置接管 IGMP 代理"
	info "  配置文件 : $CONF"
	info "  上游/下游: $UPSTREAM / $DOWNSTREAM"
	info "  altnet   : $ALTNET  quickleave=$QUICKLEAVE firewall=$FIREWALL rp_filter=$RPFILTER"
	info "  提示     : 路由器在 WAN 重连时会调用 stop_igmpproxy() 把本实例杀掉,"
	info "             长期运行请交给 perp 之类的进程管理器: rc.main 里直接"
	info "             'exec sh $PROG run ...' 即可, 不需要守护脚本常驻。"
	return 0
}

do_down() {
	stop_ours
	if [ "$FORCE" = 1 ]; then
		_f=$(list_igmp_pids)
		if [ -n "$_f" ]; then
			warn "--force: 结束剩余 igmpproxy: $(printf '%s' "$_f" | tr '\n' ' ')"
			[ "$DRYRUN" = 1 ] || kill $_f 2>/dev/null
		fi
	fi
	fw_remove
	rp_restore
	info "已停止脚本拉起的 igmpproxy 并撤销脚本添加的规则 (配置文件保留: $CONF)"
	return 0
}

do_status() {
	path_setup
	# 排版: 和插件的诊断日志共用一套网格 —— 正文缩进 2 格, 字段名占 13 个显示列
	# (中文按 2 列算), 冒号才对得齐。中文用 printf '%-13s' 会按字节补, 只能手工空格。
	printf '  配置文件     : %s %s\n' "$CONF" "$([ -f "$CONF" ] && echo '(存在)' || echo '(不存在)')"
	if [ -n "$NVRAM" ]; then
		printf '  固件开关     : mr_enable_x=%s  udpxy_enable_x=%s\n' "$(nvget mr_enable_x)" "$(nvget udpxy_enable_x)"
		printf '                 switch_stb_x=%s  switch_wantag=%s\n' "$(nvget switch_stb_x)" "$(nvget switch_wantag)"
	fi
	printf '  默认路由     : %s\n' "$(default_iface)"
	_all=$(list_igmp_pids)
	if [ -z "$_all" ]; then
		printf '  igmpproxy    : 未运行\n'
		# 没在跑的时候顺手点破最常见的原因（上游口不存在 / 没有 IPv4 地址），
		# 用户在弹窗里看到 ❌ 再点「诊断日志」，要的就是这一眼
		diag_upstream_hint
	else
		printf '  igmpproxy    : %s 个\n' "$(printf '%s\n' "$_all" | wc -l | tr -d ' ')"
		for _p in $_all; do
			if is_ours "$_p"; then _tag="[本脚本]"; else _tag="[其它来源]"; fi
			printf '    pid %-6s %s %s\n' "$_p" "$_tag" "$(pid_cmdline "$_p")"
		done
	fi
	_mc=""
	for _n in $MC_HOLDER_NAMES; do
		for _p in $(pids_by_name "$_n"); do _mc="${_mc} ${_p}"; done
	done
	if [ -n "$_mc" ]; then
		printf '  固件组播进程 : %s 正在运行(PID%s)，会占用 IGMP\n' "$MC_HOLDER_NAMES" "$_mc"
	else
		printf '  固件组播进程 : 无 %s 占用\n' "$MC_HOLDER_NAMES"
	fi
	if ipt_ok; then
		_n=$("$IPT" -S 2>/dev/null | grep -c -- "$TAG" || true)
		if [ "${_n:-0}" = "0" ]; then
			printf '  本脚本规则   : 无（点「开启」时会自动补上）\n'
		else
			printf '  本脚本规则   : %s 条\n' "$_n"
			"$IPT" -S 2>/dev/null | grep -- "$TAG" \
				| sed -e 's/^ *-A //' -e "s/ -m comment --comment \"${TAG}:/  /" -e 's/" -j /  /' -e 's/^/    /'
		fi
	fi
	_used=$(nvget wan_ifname)
	[ -f "$CONF" ] && _up=$(awk '/^phyint .* upstream/{print $2}' "$CONF") || _up=""
	[ -n "$_up" ] || _up="$_used"
	if [ -n "$_up" ] && [ -f "/proc/sys/net/ipv4/conf/$_up/rp_filter" ]; then
		printf '  rp_filter    : %s = %s   (all = %s)\n' \
			"$_up" "$(cat /proc/sys/net/ipv4/conf/$_up/rp_filter 2>/dev/null)" \
			"$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)"
	fi
	log ""
	# 上游选了 PPPoE 口时的提醒: 原来只在 conf/rules/up 的输出里出现, 而
	# 「诊断日志」跑的是 status —— 于是弹窗里那句「详点诊断日志」看不到原文。
	# 这里按已生成的配置补一次, 保证提醒在报告里能找到。
	if [ -f "$CONF" ]; then
		_cfup=$(awk '/^phyint .* upstream/{print $2}' "$CONF" 2>/dev/null)
		case "$_cfup" in
			ppp*|pppoe*) pppoe_hint "$_cfup" ;;
		esac
	fi
	log ""
	log "== 自检: 防火墙 / rp_filter =="
	[ -n "$UPSTREAM" ] || UPSTREAM="$_up"
	[ -n "$UPSTREAM" ] || UPSTREAM=$(default_iface)
	fw_verify
	return 0
}

# perp 之类的进程管理器专用: 把本脚本 exec 掉, 让它守护的就是 igmpproxy 本身。
# 配置文件和防火墙规则由调用方先跑 `conf` / `rules` 准备好, 这里只负责
# 「释放 IGMP 占用」并以前台方式启动 igmpproxy(前台 perp 才能看到真正的服务进程)。
do_run() {
	path_setup
	if [ "$DRYRUN" != 1 ] && ! is_root; then
		err "run 需要 root 权限才能启动 igmpproxy"
		return 1
	fi
	if [ "$DRYRUN" != 1 ] && [ ! -f "$CONF" ]; then
		err "配置文件不存在: $CONF (先跑: sh $PROG conf 用同样的参数生成)"
		sleep 5
		return 1
	fi
	if [ "$DRYRUN" != 1 ] && [ ! -x "$IGMPPROXY_BIN" ]; then
		err "找不到可执行的 igmpproxy: $IGMPPROXY_BIN"
		sleep 5
		return 4
	fi
	mkdir -p "$STATE_DIR" 2>/dev/null
	# Broadcom 机型的固件组播进程(mcpd)会占着 IGMP(0.0.0.0:2): 每次拉起前都
	# 确认释放一次 —— 开机自启时它可能比我们起得晚, 或者被固件重新拉起来
	if [ "$RELEASE_MC" = 1 ]; then
		release_mc_holders
	fi
	if [ "$DRYRUN" = 1 ]; then
		info "[dry-run] exec $IGMPPROXY_BIN -d $CONF"
		return 0
	fi
	# exec 之后进程就是 igmpproxy 本身, perp 只能按它退出的快慢决定何时重拉。
	# 还没拨上号/组播口没地址这类原因会让 igmpproxy 秒退, 于是 perp 一秒一次地
	# 反复拉起(日志狂刷、白耗 CPU)。这里用「上次启动时间」自我节流: 距上次启动
	# 不足 RUN_MIN_GAP 秒就先等一会儿再拉起, 正常起了很久再挂掉则不受影响。
	_gap=${RUN_MIN_GAP}
	_ts="${STATE_DIR}/last_start"
	if [ -f "$_ts" ]; then
		_last=$(cat "$_ts" 2>/dev/null)
		_now=$(date +%s)
		case "${_last}" in
			''|*[!0-9]*) : ;;
			*)
				_d=$((_now - _last))
				if [ "${_d}" -ge 0 ] && [ "${_d}" -lt "${_gap}" ]; then
					info "上次启动在 ${_d}s 前(启动失败得太快), ${_gap}s 后再重试, 避免 perp 高频重拉"
					sleep $((_gap - _d))
				fi
				;;
		esac
	fi
	date +%s > "$_ts" 2>/dev/null
	# -d = 前台(不 fork), 进程即服务本身, 交给 perp 看住
	info "前台运行 igmpproxy(由 perp 守护): $IGMPPROXY_BIN -d $CONF"
	exec "$IGMPPROXY_BIN" -d "$CONF"
}

#===============================================================================
case "$CMD" in
	check)   do_check ;;
	run)     do_run ;;
	conf)    do_conf ;;
	up)      do_up ;;
	down)    do_down ;;
	restart) do_down; do_up ;;
	status)  do_status ;;
	fwcheck)
		path_setup
		[ -n "$UPSTREAM" ] || UPSTREAM=$(nvget wan_ifname)
		[ -n "$UPSTREAM" ] || UPSTREAM=$(default_iface)
		info "自检只读: 按上游接口 $UPSTREAM 判定 rp_filter, 不改任何规则/内核参数"
		fw_verify
		;;
	rules)   do_rules ;;
	help)    usage ;;
	*)       usage ;;
esac
exit $?
