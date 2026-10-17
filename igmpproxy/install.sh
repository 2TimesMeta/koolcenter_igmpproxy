#!/bin/sh
#===============================================================================
# IGMP Proxy —— koolcenter 软件中心插件安装脚本
#
# 软件中心离线安装时会先解包，再用 start-stop-daemon 执行本脚本；
# 退出码为 0 才算安装成功。所有目录都用绝对路径，不依赖当前工作目录。
#
# 注意：软件中心对本文件做关键字自检，只要出现它用于检测「插件篡改软件中心」的
# 那两个关键字（一个以 detect 开头，一个以 ks 开头），安装就会被直接拒绝；
# 因此本文件里不要写那两个词，注释也不行。
#===============================================================================

source /koolshare/scripts/base.sh

MODULE=igmpproxy
DIR=$(cd "$(dirname "$0")" && pwd)
PLUVER=$(cat ${DIR}/version 2>/dev/null)
[ -z "${PLUVER}" ] && PLUVER=1.0.0

echo_date "========================================================================"
echo_date "                        IGMP Proxy 插件安装"
echo_date "========================================================================"

#-------------------------- 1. 固件能力检查 -----------------------------------
if [ ! -x /usr/sbin/igmpproxy ]; then
	echo_date "❌ 本机固件里没有 /usr/sbin/igmpproxy，无法安装！"
	echo_date "   本插件只接管固件自带的 IGMP 代理二进制，不内置任何二进制。"
	exit 1
fi
echo_date "✅ 固件自带 /usr/sbin/igmpproxy（$(ls -l /usr/sbin/igmpproxy | awk '{print $5}') 字节）"

if [ ! -x /usr/sbin/iptables ] && [ ! -x /usr/sbin/iptables-multi ] && [ ! -x /usr/sbin/iptables-legacy ]; then
	echo_date "❌ 找不到 iptables，无法安装！"
	exit 1
fi

#-------------------------- 2. 复制文件 ---------------------------------------
echo_date "📦 复制插件文件到 /koolshare ..."
mkdir -p /koolshare/scripts /koolshare/webs /koolshare/res /koolshare/init.d /koolshare/perp
mkdir -p /koolshare/configs/${MODULE}

cp -f ${DIR}/scripts/igmpproxy-base.sh   /koolshare/scripts/igmpproxy-base.sh
cp -f ${DIR}/scripts/igmpproxy_config.sh /koolshare/scripts/igmpproxy_config.sh
cp -f ${DIR}/webs/Module_igmpproxy.asp   /koolshare/webs/Module_igmpproxy.asp
[ -f ${DIR}/res/icon-igmpproxy.png ] && cp -f ${DIR}/res/icon-igmpproxy.png /koolshare/res/icon-igmpproxy.png
[ -f ${DIR}/uninstall.sh ] && cp -f ${DIR}/uninstall.sh /koolshare/scripts/uninstall_igmpproxy.sh

chmod +x /koolshare/scripts/igmpproxy-base.sh
chmod +x /koolshare/scripts/igmpproxy_config.sh
[ -f /koolshare/scripts/uninstall_igmpproxy.sh ] && chmod +x /koolshare/scripts/uninstall_igmpproxy.sh

#-------------------------- 3. 开机自启钩子 -----------------------------------
# S* 由 wan-start 触发（开机 / 重拨），N* 由 nat-start 触发（防火墙重启）；都是软链接，
# 卸载时直接删链接即可，不需要动 /jffs/scripts。
echo_date "🔗 安装开机自启钩子 S99 / N99 ..."
rm -f /koolshare/init.d/S99${MODULE}.sh /koolshare/init.d/N99${MODULE}.sh
ln -sf /koolshare/scripts/${MODULE}_config.sh /koolshare/init.d/S99${MODULE}.sh
ln -sf /koolshare/scripts/${MODULE}_config.sh /koolshare/init.d/N99${MODULE}.sh
chmod +x /koolshare/init.d/S99${MODULE}.sh /koolshare/init.d/N99${MODULE}.sh

#-------------------------- 4. 默认设置 ---------------------------------------
# 这几项每次都写：软件中心在跑本脚本前会先把 _version 删掉，
# 而且升级安装时 _install 已经是 1，用 [ -z ] 判断会导致版本号永远回退成默认的 0.1。
dbus set softcenter_module_${MODULE}_install="1"
dbus set softcenter_module_${MODULE}_name="${MODULE}"
dbus set softcenter_module_${MODULE}_title="IGMP Proxy"
dbus set softcenter_module_${MODULE}_version="${PLUVER}"
dbus set softcenter_module_${MODULE}_description="接管固件自带的 IGMP 代理，把运营商 IPTV 组播转发到内网，带防火墙自动放行与进程守护"
# 插件自身的设置项：只写版本号（页面标题后面显示的版本号），
# 其余设置项一律不预写，避免用户没配置却显示已配置
dbus set ${MODULE}_version="${PLUVER}"
[ -z "$(dbus get ${MODULE}_enable)" ] && dbus set ${MODULE}_enable="0"

# perp 目录（perpctl 要求 sticky 位）
rm -rf /koolshare/perp/${MODULE}
mkdir -p /koolshare/perp/${MODULE}
chmod +t /koolshare/perp/${MODULE}

# 日志文件：页面轮询 /_temp/igmpproxy_log.txt，先建好避免 404
mkdir -p /tmp/upload
: > /tmp/upload/${MODULE}_log.txt

# 升级安装时上面把 perp 服务目录清空重建过，正在运行的 igmpproxy 会随之停掉：
# 若插件是开启状态，立刻让插件自己把守护装回去并拉起进程，否则 IPTV 会一直断着，
# 页面上却仍显示「运行中」。
if [ "$(dbus get ${MODULE}_enable)" = "1" ]; then
	echo_date "🔄 插件处于开启状态，重新装载进程守护并拉起 IGMP 代理 ..."
	sh /koolshare/scripts/${MODULE}_config.sh start >/dev/null 2>&1
fi

sync
echo_date "✅ IGMP Proxy 插件安装完成！版本 v${PLUVER}"
echo_date "   打开 软件中心 → IGMP Proxy，即可开启组播代理。"
echo_date "========================================================================"
exit 0
