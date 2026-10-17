#!/bin/sh
#===============================================================================
# igmpproxy_config.sh —— koolshare 软件中心插件「IGMP Proxy」主控脚本
#
# 调用约定（软件中心插件的通用写法）：
#   软件中心 httpdb :  igmpproxy_config.sh <请求id> <命令>
#                      命令 = web_submit | status | version | ifaces | log | mr_off
#   init.d 钩子     :  igmpproxy_config.sh <动作>   动作 = start | boot_up | start_nat | stop
#   perp 守护进程   :  perp 直接守护 igmpproxy 二进制本身（rc.main 里 "exec ... run"）
#
# 真正的接管逻辑在 igmpproxy-base.sh（配置生成 / 防火墙 / 反向路径过滤 / 进程守护），
# 本脚本只负责读写 dbus、拼参数、配合软件中心与 perp；两个脚本只依赖本目录下的文件。
#===============================================================================

source /koolshare/scripts/base.sh
eval $(dbus export igmpproxy_)
alias echo_date='echo 【$(TZ=UTC-8 date -R +%Y年%m月%d日\ %X)】:'

MODULE=igmpproxy
BASE=/koolshare/scripts/${MODULE}-base.sh
WORKDIR=/koolshare/configs/${MODULE}
CONF=${WORKDIR}/${MODULE}.conf
# 运行态目录必须是 /tmp/igmpproxy 之外的路径！软件中心离线安装时会把压缩包解到
# /tmp/igmpproxy（顶层目录名就是插件名），装完再 rm -rf 掉那个目录；用同名目录会
# 让安装过程顺手删掉正在运行的实例的日志、防火墙原始备份(rules.added/rp_filter.saved)。
STATE_DIR=/tmp/${MODULE}-run
PERP_HOME=/koolshare/perp
PERP_DIR=${PERP_HOME}/${MODULE}
LOG_FILE=/tmp/upload/${MODULE}_log.txt
LOCK_FILE=/var/lock/${MODULE}.lock
TERM_STR="IG01P05X"
PLUGIN_VER="1.0.0"

#-------------------------------------------------------------------------------
# 通用工具
#-------------------------------------------------------------------------------
set_lock(){
	if [ -x "$(which flock 2>/dev/null)" ]; then
		exec 999>${LOCK_FILE}
		flock -n 999 || { http_response "$ACTION"; exit 1; }
	else
		[ -f ${LOCK_FILE} ] && { http_response "$ACTION"; exit 1; }
		: > ${LOCK_FILE}
	fi
}

unset_lock(){
	[ -x "$(which flock 2>/dev/null)" ] && flock -u 999
	rm -rf ${LOCK_FILE}
}

# dbus 里的值可能是空的（首次安装），统一补默认值
apply_defaults(){
	[ -z "${igmpproxy_enable}" ]     && igmpproxy_enable="0"
	[ -z "${igmpproxy_watchdog}" ]   && igmpproxy_watchdog="1"
	[ -z "${igmpproxy_quickleave}" ] && igmpproxy_quickleave="1"
	[ -z "${igmpproxy_firewall}" ]   && igmpproxy_firewall="1"
	[ -z "${igmpproxy_rpfilter}" ]   && igmpproxy_rpfilter="1"
	[ -z "${igmpproxy_force}" ]      && igmpproxy_force="0"
	[ -z "${igmpproxy_upstream}" ]   && igmpproxy_upstream=""
	[ -z "${igmpproxy_downstream}" ] && igmpproxy_downstream=""
	[ -z "${igmpproxy_altnet}" ]     && igmpproxy_altnet="0.0.0.0/0"
	return 0
}

# 只在用户真的填了内容时才写 dbus；留空则删除该键，
# 这样页面重新加载时输入框仍是空的（不会出现“用户没配却显示已配置”）
dbus_put(){
	_k="$1"; _v="$2"
	if [ -z "${_v}" ]; then
		dbus remove "${_k}" >/dev/null 2>&1
	else
		dbus set "${_k}"="${_v}"
	fi
}

# 网页提交上来的值会被拼进 rc.main，先做白名单清洗，避免破坏引号
sanitize_web_fields(){
	_UP=$(echo "${_RAW_UP}" | sed 's/[^A-Za-z0-9._:-]//g')
	_DN=$(echo "${_RAW_DN}" | sed 's/[^A-Za-z0-9._:-]//g')
	_AN=$(echo "${_RAW_AN}" | sed 's/[^A-Za-z0-9./ ]//g' | tr -s ' ' | sed 's/^ *//;s/ *$//')
	dbus_put igmpproxy_upstream   "${_UP}"
	dbus_put igmpproxy_downstream "${_DN}"
	dbus_put igmpproxy_altnet     "${_AN}"
	igmpproxy_upstream=${_UP}
	igmpproxy_downstream=${_DN}
	igmpproxy_altnet=${_AN}
	return 0
}

# 开关值(1/0) → 诊断日志里的「开 / 关」
onoff(){
	[ "$1" = "1" ] && echo "开" || echo "关"
}

# 诊断日志正文折行。
# 网页上的日志框不能横向滚动(overflow-x:hidden)，超出可见宽度的行会被直接裁掉，
# 所以长行由后端折开。中文一个字 3 字节、占 2 列，直接数字节会折歪，这里按显示宽度
# 算；断行只落在空格处，所以不会把一个汉字切成两半。
wrap_text(){
	awk -v w=84 -v ind=6 '
		# 显示宽度: 汉字/全角(3 字节)算 2 列, 其余算 1 列, UTF-8 续字节不重复计
		function wid(s,   i, n, c, wd) {
			n = length(s); wd = 0
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1)
				if (c ~ /[\200-\277]/) continue
				wd += (c ~ /[\340-\377]/) ? 2 : 1
			}
			return wd
		}
		# 折点: 宽度不超过 lim 的最后一个空格; 没有空格就退回最后一个完整字符
		function cutpos(s, lim,   i, n, c, wd, best) {
			n = length(s); wd = 0; best = 0
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1)
				if (c !~ /[\200-\277]/) wd += (c ~ /[\340-\377]/) ? 2 : 1
				if (wd > lim) break
				if (c == " ") best = i - 1
			}
			return (best > 0) ? best : i - 1
		}
		{
			sub(/[ \t]+$/, "")
			if (wid($0) <= w) { print; next }
			_pad = substr("                    ", 1, ind)
			_s = $0
			for (_i = 0; _i < 100 && wid(_s) > w; _i++) {
				_o = length(_s)
				_c = cutpos(_s, w)
				if (_c <= 0) break
				print substr(_s, 1, _c)
				_t = substr(_s, _c + 1)
				sub(/^[ \t]+/, "", _t)
				if (length(_t) >= _o) break
				_s = _pad _t
			}
			print _s
		}'
}

# 调用 igmpproxy-base.sh，逐项引用，值里带空格也不会被拆开
igmp_base(){
	_cmd="$1"; shift
	set -- "${_cmd}" \
		--workdir "$WORKDIR" \
		--conf "$CONF" \
		--state-dir "$STATE_DIR" \
		--release-mc-router
	# 没配置上游时优先可用的 PPPoE 接口（见 preferred_upstream）
	_up_use=$(upstream_final)
	[ -n "${_up_use}" ]               && set -- "$@" --upstream "${_up_use}"
	[ -n "${igmpproxy_downstream}" ] && set -- "$@" --downstream "${igmpproxy_downstream}"
	[ -n "${igmpproxy_altnet}" ]     && set -- "$@" --altnet "${igmpproxy_altnet}"
	[ "${igmpproxy_quickleave}" = "0" ] && set -- "$@" --no-quickleave
	[ "${igmpproxy_firewall}" = "0" ]   && set -- "$@" --no-firewall
	[ "${igmpproxy_rpfilter}" = "0" ]   && set -- "$@" --no-rp-filter
	[ "${igmpproxy_force}" = "1" ]      && set -- "$@" --force
	sh "$BASE" "$@"
}

# 生成 perp 用的一行参数（值自带双引号，dbus 里的值已清洗过）
perp_opts(){
	OPTS=""
	# 与 igmp_base 保持一致：没配置上游时优先可用的 PPPoE 接口
	_up_use=$(upstream_final)
	[ -n "${_up_use}" ]               && OPTS="${OPTS} --upstream \"${_up_use}\""
	[ -n "${igmpproxy_downstream}" ] && OPTS="${OPTS} --downstream \"${igmpproxy_downstream}\""
	[ -n "${igmpproxy_altnet}" ]     && OPTS="${OPTS} --altnet \"${igmpproxy_altnet}\""
	[ "${igmpproxy_quickleave}" = "0" ] && OPTS="${OPTS} --no-quickleave"
	[ "${igmpproxy_firewall}" = "0" ]   && OPTS="${OPTS} --no-firewall"
	[ "${igmpproxy_rpfilter}" = "0" ]   && OPTS="${OPTS} --no-rp-filter"
	[ "${igmpproxy_force}" = "1" ]      && OPTS="${OPTS} --force"
	OPTS="${OPTS} --release-mc-router"
	return 0
}

# perp 的 rc.main —— 不常驻脚本, 直接 exec 服务本身, 由软件中心的后台守护看住进程。
#   rules : perp 每次重拉时顺手续一遍防火墙放行 / rp_filter(WAN 重连会冲掉规则)
#   run   : 释放 IGMP 占用后以前台方式 exec igmpproxy, perp 守护的就是它
make_perp(){
	rm -rf ${PERP_DIR}
	mkdir -p ${PERP_DIR}
	perp_opts
	cat > ${PERP_DIR}/rc.main <<-EOF
	#!/bin/sh
	. /koolshare/scripts/base.sh
	if test "\${1}" = 'start' ; then
	mkdir -p "${STATE_DIR}" 2>/dev/null
	sh "${BASE}" rules --workdir "${WORKDIR}" --conf "${CONF}" --state-dir "${STATE_DIR}"${OPTS} >> "${STATE_DIR}/igmpproxy.log" 2>&1
	exec sh "${BASE}" run --workdir "${WORKDIR}" --conf "${CONF}" --state-dir "${STATE_DIR}"${OPTS}
	fi
	exit 0
	EOF
	chmod +x ${PERP_DIR}/rc.main
	chmod +t ${PERP_DIR}
	sync
}

#-------------------------------------------------------------------------------
# 弹窗里的输出：只留「好看的那几行」
#
# 网页上的「开启/关闭」是以日志弹窗的形式回报的，用户要看的是结果和结果里最要紧
# 的一两句；接管脚本(igmpproxy-base.sh)的输出是给命令行/排查用的，逐行铺开会把
# 弹窗淹掉。所以这里统一成：
#   * 成功 → 不打印，细节留给「诊断日志」按钮
#   * 失败 → 缩进打出来，这种时候细节正是用户要的
#   * [WARN] 只统计条数，末尾给一句「点诊断日志查看详情」
#-------------------------------------------------------------------------------
_WARNS=0
base_run(){
	_OUT=$(igmp_base "$@" 2>&1)
	_rc=$?
	_w=$(printf '%s\n' "${_OUT}" | grep -c '^\[WARN\] [^ ]')
	_WARNS=$((_WARNS + _w))
	[ ${_rc} -ne 0 ] && printf '%s\n' "${_OUT}" | sed 's/^/      /'
	return ${_rc}
}
base_warn_sum(){
	if [ "${_WARNS}" -gt 0 ]; then
		echo_date "⚠️ 有 ${_WARNS} 处提醒，点「诊断日志」查看详情"
	fi
	return 0
}
# 弹窗里补一行接口流向：读的是接管脚本刚生成的那份配置，所以和 igmpproxy 实际
# 用的接口一致（自动探测时它就是真正选中的口，不是页面上的空值）
show_iface_flow(){
	_u=$(awk '/^phyint .* upstream/{print $2}' ${CONF} 2>/dev/null)
	_d=$(awk '/^phyint .* downstream/{print $2}' ${CONF} 2>/dev/null)
	if [ -n "${_u}" ] && [ -n "${_d}" ]; then
		echo "    上游 → 下游: ${_u} → ${_d}"
	fi
	return 0
}

# 检查 igmpproxy 是否真的起来了（固件自带二进制，名字固定）
detect_running_status(){
	_i=0
	while [ -z "$(pidof igmpproxy)" ]; do
		_i=$((${_i}+1))
		[ ${_i} -ge 5 ] && break
		sleep 1
	done
	if [ -n "$(pidof igmpproxy)" ]; then
		echo_date "✅ IGMP 代理启动成功！PID：$(pidof igmpproxy | awk '{print $1}')"
		return 0
	fi
	echo_date "❌ IGMP 代理启动失败，请点「诊断日志」查看原因！"
	return 1
}

#-------------------------------------------------------------------------------
# 页面下拉框用的可选接口列表，返回 "上游候选|下游候选"（空格分隔）
#
#   这里列的是「有可能」承担该角色的**接口类型**——不判断它现在有没有 IPv4
#   地址、也不判断它上面有没有 IPTV 组播（这些只能用户实测，选错不会弄坏配置，
#   最多是不通）。所以候选给得宽一点，用户不用手打接口名。
#     上游候选（WAN / IPTV 侧）：ppp*/pppoe*、eth*、vlan*、wwan*/rmnet*/mbim*、
#                                usb*/cdc*/ncm*、apcli*（无线 STA）、隧道/VPN
#     下游候选（LAN / 内网侧）：br*、lan*、eth*、vlan*、ra*/rax*（无线 AP）
#   再补上 nvram 里登记过的 IPTV / WAN 接口名（拨号还没建立时也允许选）。
#-------------------------------------------------------------------------------

# 接口当前的 IPv4 地址；取不到就是空（说明这个口还没起来 / 没有地址）
iface_addr(){
	ifconfig "$1" 2>/dev/null | sed -n 's/.*inet addr:\([0-9][0-9.]*\).*/\1/p' | head -n 1
}

# 上游没配置时的优先选择：**当前可用的 PPPoE 接口**（ppp*/pppoe* 里有 IPv4 的那个）。
# 运营商 IPTV 的组播通常封装在 PPPoE 会话里，而固件自带的探测顺序先挑 WAN 以太口
# （nvram wan0_ifname，本机是 eth1）——两者都能收到组播时，用 PPPoE 口更贴近实际线路。
# 只认「已经拿到地址」的 PPPoE 口：没拨上号就不算可用，此时返回空，
# 仍旧交回 igmpproxy-base.sh 按固件逻辑（IPTV 接口 → WAN 接口）探测。
preferred_upstream(){
	for _i in $(ls /sys/class/net 2>/dev/null | grep -E '^ppp' | sort); do
		if [ -n "$(iface_addr ${_i})" ]; then
			echo "${_i}"
			return 0
		fi
	done
	return 0
}

# 最终上游接口：用户显式配置的最优先；没配置才优先可用的 PPPoE 口
upstream_final(){
	if [ -n "${igmpproxy_upstream}" ]; then
		echo "${igmpproxy_upstream}"
	else
		preferred_upstream
	fi
}

iface_candidates(){
	_lan=$(nvram get lan_ifname)
	[ -z "${_lan}" ] && _lan="br0"

	_up=""
	_down=""

	for _i in $(ls /sys/class/net 2>/dev/null); do
		case "${_i}" in
			# 恒排除：环回口与内核中间层虚拟设备，不可能做 IGMP 上下游
			lo|bonding_masters|imq*|ifb*|dummy*|teql*|gre*|gretap*|erspan*|sit*|ip_vti*|ip6_*|ip6tnl*|ip6gre*|docker*|veth*|br-*|kube*)
				continue
				;;
		esac
		_addr=$(iface_addr "${_i}")
		# 下游候选：面向内网的口，只列已经有 IPv4 地址的（一般就是 br0）。
		# 挂在 br0 里的 lan1/ra0 交换口没有自己的地址，列出来只会让人选错。
		case "${_i}" in
			br*|lan*|eth*|vlan*|ra*|rax*|rai*|wl*|wlan*)
				[ -n "${_addr}" ] && _down="${_down} ${_i}"
				;;
		esac
		# 上游候选：WAN 侧（PPPoE / WAN 以太口 / VLAN / 无线 STA / 蜂窝 / USB 网卡 / 隧道），
		# 同样只列有 IPv4 的；ppp/pppoe 例外——还没拨上号时也该能选，等它拨上来即可。
		case "${_i}" in
			ppp*|pppoe*)
				_up="${_up} ${_i}"
				;;
			eth*|vlan*|wwan*|ww*|rmnet*|mbim*|qmi*|cdc*|ncm*|usb*|mii*|apcli*|cl*|tailscale*|tun*|tap*|wg*|vpn*)
				[ -n "${_addr}" ] && _up="${_up} ${_i}"
				;;
		esac
	done

	# 排序：越可能用到的口越靠前（上游：可用的 ppp → 其它 ppp → eth → vlan，
	# 下游 lan_ifname→br→lan→eth），并去重
	_up=$(echo ${_up} | tr ' ' '\n' | while read -r _n; do
		[ -z "${_n}" ] && continue
		_addr=$(iface_addr "${_n}")
		case "${_n}" in
			# 越可能用到的口越靠前：拨上号的 ppp → 其它 ppp（还没拨号）→ 以太口/VLAN → 其余
			ppp*|pppoe*) [ -n "${_addr}" ] && _r=1 || _r=4 ;;
			eth*|vlan*)  _r=2 ;;
			*)           _r=3 ;;
		esac
		echo "${_r} ${_n}"
	done | sort -k1,1n -k2,2 | awk '!seen[$2]++ {printf "%s ", $2}')

	_down=$(echo "${_lan} ${_down}" | tr ' ' '\n' | while read -r _n; do
		[ -z "${_n}" ] && continue
		case "${_n}" in
			${_lan}) _r=1 ;;
			br*)     _r=2 ;;
			lan*)    _r=3 ;;
			eth*)    _r=4 ;;
			*)       _r=9 ;;
		esac
		echo "${_r} ${_n}"
	done | sort -k1,1n -k2,2 | awk '!seen[$2]++ {printf "%s ", $2}')

	# 第 3 段是「上游留空时实际会用哪个口」，页面用它给「自动探测」加上注解
	echo "${_up}|${_down}|$(preferred_upstream)"
}

# 上游候选里「已经有 IPv4 地址」的那些口(空格分隔):
# 只有它们能被 igmpproxy 建成上游 Vif。用来在用户选错口时把真正能用的口列给他。
upstream_with_addr(){
	for _n in $(iface_candidates | cut -d'|' -f1); do
		[ -n "$(iface_addr ${_n})" ] && printf '%s ' "${_n}"
	done
	return 0
}

#-------------------------------------------------------------------------------
# igmpproxy 进程清点 / 清理
# 为什么不能只用 pidof：本固件的 pidof 是 cmdline 子串匹配，会把本脚本自己、
# 甚至 ps|grep 管道里的字都算成 igmpproxy。这里按 argv[0] 的基名判断。
#-------------------------------------------------------------------------------
igmp_argv0(){
	_c=$(cat "/proc/$1/cmdline" 2>/dev/null | tr '\0' ' ')
	_a0=${_c%% *}
	[ -n "${_a0}" ] && echo "${_a0##*/}"
}

list_igmp_pids(){
	for _d in /proc/[0-9]*; do
		_p=${_d#/proc/}
		[ "${_p}" = "$$" ] && continue
		[ "$(igmp_argv0 ${_p})" = "igmpproxy" ] && echo ${_p}
	done
}

# 只列出「本插件拉起的」：命令行里带着本插件的配置或状态目录
list_ours_igmp(){
	for _p in $(list_igmp_pids); do
		_c=$(cat "/proc/${_p}/cmdline" 2>/dev/null | tr '\0' ' ')
		case "${_c}" in
			*"${CONF}"*|*"${STATE_DIR}"*) echo ${_p} ;;
		esac
	done
}

# 结束指定 pid 并等到进程真的消失。IGMP 是独占的 raw socket(端口 4022)，
# 上一个实例没退干净就拉新的，新实例会立刻以 98(Address already in use) 退出。
kill_igmp_pids(){
	[ -n "$1" ] || return 0
	for _p in $1; do kill ${_p} 2>/dev/null; done
	_i=0
	while [ ${_i} -lt 10 ]; do
		_left=""
		for _p in $1; do
			[ -d "/proc/${_p}" ] && _left="${_left} ${_p}"
		done
		[ -z "${_left}" ] && { sleep 1; return 0; }
		_i=$((_i+1))
		sleep 1
	done
	echo_date "   ⚠️ 仍有进程不响应 TERM，用 KILL 结束：${_left}"
	for _p in ${_left}; do kill -9 ${_p} 2>/dev/null; done
	sleep 1
	return 0
}

# 固件自带的组播转发进程（Broadcom 机型是 /bin/mcpd）。它和 igmpproxy 都要求
# 独占 IGMP raw socket，先停掉它并等进程退出，再让引擎启动。
mc_holder_pids(){
	for _d in /proc/[0-9]*; do
		_p=${_d#/proc/}
		[ "${_p}" = "$$" ] && continue
		[ "$(igmp_argv0 ${_p})" = "mcpd" ] && echo ${_p}
	done
}

release_mc_holder(){
	_p=$(mc_holder_pids)
	[ -n "${_p}" ] || return 0
	echo_date "🟠 固件自带的组播进程 mcpd(PID $(echo ${_p} | tr '\n' ' ')) 占着 IGMP，先停掉它..."
	kill_igmp_pids "${_p}"
	return 0
}

# perp 里有没有本插件这个服务。
# perpls 认 PERP_BASE（base.sh 会 export，这里为保险显式再指一次），
# 输出形如 "[+ +++ ---]  igmpproxy  uptime: 487s/-s  pids: 16941/-"。
perp_service_up(){
	_ls=""
	for _d in /koolshare/bin /usr/bin /usr/sbin /bin /sbin; do
		[ -x "${_d}/perpls" ] && { _ls="${_d}/perpls"; break; }
	done
	if [ -n "${_ls}" ]; then
		PERP_BASE="${PERP_HOME}" "${_ls}" 2>/dev/null | grep -q "[[:space:]]${MODULE}[[:space:]]"
		return $?
	fi
	# 没有 perpls 时的兜底：服务目录里有 rc.main 就算在守护
	[ -f "${PERP_DIR}/rc.main" ]
	return $?
}

start_service(){
	apply_defaults
	if [ ! -f "${BASE}" ]; then
		echo_date "❌ 缺少 ${BASE}，插件文件不完整，请卸载后重新安装！"
		return 1
	fi
	if [ ! -x /usr/sbin/igmpproxy ]; then
		echo_date "❌ 本机固件里没有 /usr/sbin/igmpproxy，无法接管！"
		echo_date "   本插件只接管固件自带的 IGMP 代理二进制，不内置任何二进制。"
		return 1
	fi

	# 路由器自身的组播路由必须先关掉，否则会和本插件抢 4022 端口
	_MR=$(nvram get mr_enable_x)
	if [ -n "${_MR}" ] && [ "${_MR}" != "0" ]; then
		echo_date "❌ 路由器自身的组播路由仍处于开启状态 (mr_enable_x=${_MR})，无法接管！"
		echo_date "   请先点页面上的「关闭路由器自身组播路由」按钮，"
		echo_date "   或者到 高级设置 → 局域网 → IPTV 关闭「启动组播路由」。"
		return 2
	fi

	# 清掉旧的 perp 服务，避免重复拉起；目录不清干净，perp 可能拿旧 rc.main 反复拉起
	perpctl -b ${PERP_HOME} d ${MODULE} >/dev/null 2>&1
	rm -rf ${PERP_DIR}

	# 显式指定的接口必须先真的存在，否则 igmpproxy 会直接退出，用户看到的报错毫无头绪
	_chk=""
	[ -n "${igmpproxy_upstream}" ] && [ ! -e "/sys/class/net/${igmpproxy_upstream}" ] && _chk="${_chk} 上游=${igmpproxy_upstream}"
	[ -n "${igmpproxy_downstream}" ] && [ ! -e "/sys/class/net/${igmpproxy_downstream}" ] && _chk="${_chk} 下游=${igmpproxy_downstream}"
	if [ -n "${_chk}" ]; then
		echo_date "❌ 接口不存在：${_chk}"
		echo_date "   请到「IGMP Proxy - 设置」重新选择；留空则由插件自动探测。"
		echo_date "   当前可用接口：$(iface_candidates | cut -d'|' -f1)"
		return 1
	fi

	# 上游口必须是「已经有 IPv4 地址」的口。eth1/eth2 这类挂在 br0 里的交换口没有自己的
	# 地址, igmpproxy 解析配置时建不出上游 Vif, 只会甩一句
	# "There must be at least 2 Vif's where one is upstream." 然后秒退
	# (守护模式下就是反复重拉、永远起不来)。这里提前拦住并说清原因。
	if [ -n "${igmpproxy_upstream}" ] && [ -z "$(iface_addr ${igmpproxy_upstream})" ]; then
		_alt=$(upstream_with_addr)
		case "${igmpproxy_upstream}" in
			ppp*|pppoe*)
				# PPPoE 口没地址多半只是还没拨上号, 不能拦, 交给守护重试
				echo_date "⚠️ 上游接口 ${igmpproxy_upstream} 现在还没有 IPv4 地址，" 
				echo_date "   若还没拨上号，igmpproxy 会启动失败；拨上号后守护会自动重拉。"
				;;
			*)
				if [ -n "${_alt}" ]; then
					echo_date "❌ 上游接口 ${igmpproxy_upstream} 没有 IPv4 地址，不能做组播上游。"
					echo_date "   igmpproxy 会报「There must be at least 2 Vif's where one is upstream.」立刻退出，" 
					echo_date "   守护进程会反复重拉、永远起不来。"
					echo_date "   本机有地址、能当上游的口：${_alt}"
					echo_date "   （PPPoE 拨号就留空，插件会自动挑已经拨上号的 ppp 口）"
					return 1
				fi
				echo_date "⚠️ 上游接口 ${igmpproxy_upstream} 目前没有 IPv4 地址，启动可能失败。"
				;;
		esac
	fi

	# 还有一个 igmpproxy 活着就一定会占着 IGMP raw socket，新实例必然启动失败，
	# 所以先把本插件拉起的残留清干净并等它退出，再启动。
	_left=$(list_ours_igmp)
	if [ -n "${_left}" ]; then
		echo_date "🟠 清理残留的 igmpproxy：$(echo ${_left} | tr '\n' ' ')"
		kill_igmp_pids "${_left}"
	fi

	# Broadcom 机型的 mcpd 常驻占用 IGMP，不清掉 igmpproxy 永远起不来
	release_mc_holder

	# 非本插件拉起的 igmpproxy 只提示，交给用户决定是否勾选「强制接管」
	_other=$(list_igmp_pids)
	for _p in ${_left}; do
		_other=$(printf '%s\n' ${_other} | grep -v -x "${_p}" | tr '\n' ' ')
	done
	_other=$(echo ${_other} | tr -d ' ')
	if [ -n "${_other}" ]; then
		echo_date "⚠️ 还有其它来源的 igmpproxy 在运行（PID $(echo ${_other} | tr ' ' ',')），"
		echo_date "   它会占用 IGMP(raw socket 4022)；若本插件因此启动失败，可勾选「强制接管」。"
	fi

	if [ "${igmpproxy_watchdog}" = "1" ]; then
		echo_date "🟠 准备配置和防火墙规则，并交给软件中心后台守护（不需要常驻脚本）..."
		# 配置文件和防火墙/rp_filter 这里先准备一次；之后 perp 每次重拉 igmpproxy
		# 都会在 rc.main 里先补一遍规则（WAN 重连会冲掉脚本加的放行规则）。
		_WARNS=0
		base_run conf
		_rc=$?
		if [ ${_rc} -ne 0 ]; then
			echo_date "❌ 生成配置文件失败（返回码 ${_rc}），原因见上"
			return ${_rc}
		fi
		base_run rules
		make_perp
		perpctl -b ${PERP_HOME} A ${MODULE} >/dev/null 2>&1
		perpctl -b ${PERP_HOME} u ${MODULE} >/dev/null 2>&1
		sleep 3
		# 若被别的 igmpproxy 占了 IGMP，perp 会一直重拉失败，
		# 这里清一次再让 perp 立刻重新拉起
		if [ -z "$(pidof igmpproxy)" ] && [ -n "$(list_igmp_pids)" ]; then
			echo_date "🟠 仍有 igmpproxy 占用 IGMP，结束它们后重新拉起..."
			kill_igmp_pids "$(list_igmp_pids)"
			perpctl -b ${PERP_HOME} d ${MODULE} >/dev/null 2>&1
			perpctl -b ${PERP_HOME} A ${MODULE} >/dev/null 2>&1
			perpctl -b ${PERP_HOME} u ${MODULE} >/dev/null 2>&1
			sleep 3
		fi
		show_iface_flow
		detect_running_status
		_rc=$?
		base_warn_sum
		return ${_rc}
	fi

	echo_date "🟠 以单次方式启动 IGMP 代理..."
	_WARNS=0
	base_run up
	_rc=$?

	# 接管脚本是靠「命令行里有没有自己的配置路径」认自己的进程的；万一它对不上
	# （历史上出现过），只要确实有 igmpproxy 在跑就按成功处理，不要误报失败。
	if [ ${_rc} -eq 4 ] && [ -n "$(pidof igmpproxy)" ]; then
		echo_date "ℹ️ 接管脚本报告启动失败，但检测到 igmpproxy 已在运行，按成功处理。"
		_rc=0
	fi

	# 确实没起来：几乎都是别的 igmpproxy 还占着 IGMP，全部结束掉再试一次
	if [ ${_rc} -eq 4 ]; then
		_all=$(list_igmp_pids)
		if [ -n "${_all}" ]; then
			echo_date "🟠 检测到仍有 igmpproxy 占用 IGMP（$(echo ${_all} | tr '\n' ' ')），结束它们后重试一次..."
			kill_igmp_pids "${_all}"
			base_run up
			_rc=$?
		fi
	fi
	show_iface_flow
	detect_running_status
	base_warn_sum
	if [ ${_rc} -ne 0 ]; then
		case ${_rc} in
		2) echo_date "❌ 路由器自身的组播路由没关，原因见上" ;;
		3) echo_date "❌ 已有其它来源的 igmpproxy 在跑，可勾选「强制接管」后重试" ;;
		4) echo_date "❌ igmpproxy 启动失败，原因见上" ;;
		*) echo_date "❌ igmpproxy-base.sh 返回码 ${_rc}" ;;
		esac
	fi
	return ${_rc}
}

stop_service(){
	apply_defaults
	echo_date "🟠 停止 igmpproxy 并回收防火墙规则..."
	perpctl -b ${PERP_HOME} d ${MODULE} >/dev/null 2>&1
	rm -rf ${PERP_DIR}
	_WARNS=0
	base_run down
	rm -rf ${STATE_DIR}
	if [ -z "$(pidof igmpproxy)" ]; then
		echo_date "✅ IGMP 代理已停止，防火墙规则已回收"
	else
		echo_date "⚠️ 仍有 igmpproxy 进程存活：$(pidof igmpproxy)"
	fi
	base_warn_sum
	return 0
}

#===============================================================================
# 主流程
#===============================================================================

# 网页提交上来的原始值先留底。apply_defaults 会给空值补上默认值，但“用户留空”
# 必须保持留空——否则默认值会被写进 dbus，页面下次加载就显示成“已配置”，
# 正是要避免的现象。
_RAW_UP="${igmpproxy_upstream}"
_RAW_DN="${igmpproxy_downstream}"
_RAW_AN="${igmpproxy_altnet}"

apply_defaults

case "$1" in

#------------------------------- init.d 钩子 ----------------------------------
start)
	if [ "${igmpproxy_enable}" = "1" ]; then
		logger "[软件中心-开机自启]: IGMP Proxy 自启动开启！"
		echo_date "[软件中心-开机自启]: IGMP Proxy 自启动开启！"
		start_service
	else
		logger "[软件中心-开机自启]: IGMP Proxy 未开启，不自动启动！"
	fi
	;;

boot_up)
	if [ "${igmpproxy_enable}" = "1" ]; then
		start_service
	fi
	;;

start_nat)
	# NAT / 防火墙重启之后把组播放行规则补回来（此时不碰配置文件与进程）
	if [ "${igmpproxy_enable}" = "1" ]; then
		logger "[软件中心]-[${0##*/}]: NAT 重启，补回 IGMP 组播防火墙规则！"
		echo_date "🔁 NAT 重启，补回 IGMP 组播防火墙规则..."
		igmp_base rules 2>&1 | sed 's/^/    /'
	fi
	;;

stop)
	stop_service
	;;

#------------------------------- 软件中心接口 --------------------------------
*)
	case "$2" in

	web_submit)
		set_lock
		: > ${LOG_FILE}
		http_response "$1"
		sanitize_web_fields
		apply_defaults
		case "${igmpproxy_enable}" in
		1)
			echo_date "▶️ 开启 IGMP 代理" >> ${LOG_FILE}
			start_service >> ${LOG_FILE} 2>&1
			;;
		2)
			echo_date "🔁 重启 IGMP 代理" >> ${LOG_FILE}
			dbus set igmpproxy_enable=1
			igmpproxy_enable=1
			start_service >> ${LOG_FILE} 2>&1
			;;
		*)
			echo_date "⏹ 关闭 IGMP 代理" >> ${LOG_FILE}
			stop_service >> ${LOG_FILE} 2>&1
			;;
		esac
		echo ${TERM_STR} >> ${LOG_FILE}
		unset_lock
		;;

	# 关闭路由器自身的组播路由（改 nvram，一键操作）
	mr_off)
		set_lock
		: > ${LOG_FILE}
		http_response "$1"
		echo_date "🚫 关闭路由器自身的组播路由..." >> ${LOG_FILE}
		_OLD_MR=$(nvram get mr_enable_x)
		nvram set mr_enable_x=0
		nvram commit
		echo "    mr_enable_x: ${_OLD_MR:-空} → $(nvram get mr_enable_x)" >> ${LOG_FILE}
		killall igmpproxy >/dev/null 2>&1
		sleep 1
		if [ -n "$(pidof igmpproxy)" ]; then
			echo "    ⚠️ 仍有进程没退出，已强制结束" >> ${LOG_FILE}
			killall -9 igmpproxy >/dev/null 2>&1
		fi
		echo "    ✅ 完成，现在可以点「开启」接管路由器的组播路由了" >> ${LOG_FILE}
		echo ${TERM_STR} >> ${LOG_FILE}
		unset_lock
		;;

	# 诊断日志：给用户一键收集全部现场
	# 排版约定（网页上的日志框不能横向滚动，超长的行会被直接裁掉）：
	#   * 正文不再逐行打时间戳，时间只在报告头出现一次
	#   * 每节 = 节标题 + 一条分隔线，字段统一缩进 2 格
	#   * 字段名手工补空格到 13 显示列（中文按 2 列算），冒号才对得齐
	#   * 仍然过长的行由 wrap_text 折行
	log)
		: > ${LOG_FILE}
		http_response "$1"
		apply_defaults
		{
			echo "===================================================================================="
			echo "  IGMP Proxy 诊断报告"
			echo "  生成时间     : $(TZ=UTC-8 date +'%Y-%m-%d %H:%M:%S')"
			echo "  插件版本     : v${PLUGIN_VER}"
			echo "===================================================================================="
			echo ""
			echo "[1/3] 插件设置"
			echo "------------------------------------------------------------------------------------"
			echo "  接管脚本     : ${BASE}"
			echo "  配置文件     : ${CONF}"
			if [ -n "${igmpproxy_upstream}" ]; then
				echo "  上游接口     : ${igmpproxy_upstream}（手动指定）"
			else
				_pu=$(preferred_upstream)
				if [ -n "${_pu}" ]; then
					echo "  上游接口     : （自动探测）→ 优先可用的 PPPoE 口 ${_pu}"
				else
					echo "  上游接口     : （自动探测）→ 按固件逻辑 iptv_ifname / wan_ifname 挑"
				fi
			fi
			echo "  下游接口     : ${igmpproxy_downstream:-（自动：nvram lan_ifname）}"
			echo "  组播源网段   : ${igmpproxy_altnet}"
			echo "  快速换台     : $(onoff ${igmpproxy_quickleave})"
			echo "  防火墙放行   : $(onoff ${igmpproxy_firewall})"
			if [ "${igmpproxy_rpfilter}" = "1" ]; then
				echo "  反向路径过滤 : 已关闭（上游接口的 rp_filter 置 0）"
			else
				echo "  反向路径过滤 : 未动（沿用固件的 rp_filter 设置）"
			fi
			echo "  强制接管     : $(onoff ${igmpproxy_force})"
			if [ "${igmpproxy_watchdog}" = "1" ]; then
				echo "  实时进程守护 : 开（perp 守护 igmpproxy 进程本身，无常驻脚本）"
			else
				echo "  实时进程守护 : 关（只在点「开启」时拉起一次）"
			fi
			echo ""
			echo "[2/3] 运行现场（igmpproxy-base.sh status）"
			echo "------------------------------------------------------------------------------------"
			igmp_base status
			echo ""
			echo "[3/3] 配置文件内容"
			echo "------------------------------------------------------------------------------------"
			if [ -f ${CONF} ]; then
				sed 's/^/  /' ${CONF}
			else
				echo "  （不存在）"
			fi
			echo ""
			echo "===================================================================================="
		} 2>&1 | wrap_text >> ${LOG_FILE}
		echo ${TERM_STR} >> ${LOG_FILE}
		;;

	# 插件版本（命令行 / API 查询用，页面标题的版本号来自 dbus 的 igmpproxy_version）
	version)
		http_response "v${PLUGIN_VER}"
		;;

	# 页面下拉框的可用接口列表：上游候选|下游候选
	ifaces)
		http_response "$(iface_candidates)"
		;;

	# 页面状态栏
	status)
		# 用 | 分成三段：运行状态 / 组播流向 / 进程守护
		# 守护一栏只回短词（未启用 / 待启动 / 正常 / 异常），详细说明放在页面标签的说明弹窗里
		_u=$(awk '/^phyint .*upstream/{print $2}' ${CONF} 2>/dev/null)
		_d=$(awk '/^phyint .*downstream/{print $2}' ${CONF} 2>/dev/null)
		if [ -n "${_u}" ] && [ -n "${_d}" ]; then
			_if="${_u} → ${_d}"
		else
			_if=""
		fi
		if [ "${igmpproxy_enable}" != "1" ]; then
			_ret="⏹ 未启用"
			_wd="未启用"
		elif [ -z "$(pidof igmpproxy)" ]; then
			_ret="❌ 未运行（可点「诊断日志」查看原因）"
			_wd="待启动"
		else
			_ret="✅ 运行中（PID $(pidof igmpproxy | awk '{print $1}')）"
			if [ "${igmpproxy_watchdog}" != "1" ]; then
				_wd="未启用"
			elif perp_service_up; then
				# perp 守护的就是 igmpproxy 本身，「守护在不在」和「进程在不在」
				# 是同一件事，不用再去另找一个常驻脚本
				_wd="正常"
			else
				_wd="异常"
			fi
		fi
		http_response "${_ret}|${_if}|${_wd}"
		;;

	esac
	;;
esac

exit 0
