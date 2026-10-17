#!/bin/sh
#===============================================================================
# IGMP Proxy 卸载脚本
# 安装时被复制到 /koolshare/scripts/uninstall_igmpproxy.sh，
# 软件中心卸载时执行：停进程 → 清规则 → 删文件 → 删 dbus 记录。
#===============================================================================

source /koolshare/scripts/base.sh

MODULE=igmpproxy
PLUVER=$(dbus get softcenter_module_${MODULE}_version)

echo_date "========================================================================"
echo_date "                        IGMP Proxy 插件卸载"
echo_date "========================================================================"

#-------------------------- 1. 停服务 -----------------------------------------
echo_date "🛑 停止 IGMP Proxy 服务..."
if [ -f /koolshare/scripts/${MODULE}_config.sh ]; then
	sh /koolshare/scripts/${MODULE}_config.sh stop >/dev/null 2>&1
fi
perpctl d ${MODULE} >/dev/null 2>&1
rm -rf /koolshare/perp/${MODULE}

# 兜底：直接把插件自己拉起的 igmpproxy 结束掉（不会动固件自己的那份，除非强制）
if [ -f /koolshare/scripts/${MODULE}-base.sh ]; then
	sh /koolshare/scripts/${MODULE}-base.sh down --workdir /koolshare/configs/${MODULE} \
		--conf /koolshare/configs/${MODULE}/${MODULE}.conf --state-dir /tmp/${MODULE} >/dev/null 2>&1
fi

#-------------------------- 2. 删文件 -----------------------------------------
echo_date "🗑  删除插件文件..."
rm -f /koolshare/init.d/S99${MODULE}.sh
rm -f /koolshare/init.d/N99${MODULE}.sh
rm -f /koolshare/scripts/${MODULE}_config.sh
rm -f /koolshare/scripts/${MODULE}-base.sh
rm -f /koolshare/scripts/uninstall_${MODULE}.sh
rm -f /koolshare/webs/Module_${MODULE}.asp
rm -f /koolshare/res/icon-${MODULE}.png
rm -rf /koolshare/configs/${MODULE}
rm -rf /tmp/${MODULE}
rm -f /tmp/upload/${MODULE}_log.txt
rm -f /var/lock/${MODULE}.lock
rm -f /tmp/igmpproxy.conf
rm -f /tmp/igmpproxy.log

#-------------------------- 3. 清 dbus ----------------------------------------
echo_date "🧹 清理配置记录..."
for K in ${MODULE}_enable ${MODULE}_watchdog ${MODULE}_quickleave ${MODULE}_firewall \
         ${MODULE}_rpfilter ${MODULE}_force ${MODULE}_interval ${MODULE}_upstream \
         ${MODULE}_downstream ${MODULE}_altnet; do
	dbus remove ${K} >/dev/null 2>&1
done

for K in install version name title description; do
	dbus remove softcenter_module_${MODULE}_${K} >/dev/null 2>&1
done

sync
echo_date "✅ IGMP Proxy（v${PLUVER:-?}）已完全卸载！"
echo_date "   说明：插件不会改动你路由器的 nvram 设置（mr_enable_x 等），"
echo_date "   如需恢复路由器自身组播路由，请到 高级设置 → 局域网 → IPTV 自行打开。"
echo_date "========================================================================"
exit 0
