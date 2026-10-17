#!/bin/sh
# 由 /koolshare/bin/ks-nat-start.sh（nat-start 钩子：防火墙/NAT 重启）调用，
# 参数为 start_nat，用于在防火墙重启后补回组播放行规则。
/koolshare/scripts/igmpproxy_config.sh $1
