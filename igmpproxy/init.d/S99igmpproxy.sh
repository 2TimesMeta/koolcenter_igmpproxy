#!/bin/sh
# 由 /koolshare/bin/ks-wan-start.sh（wan-start 钩子：开机、WAN 重拨）调用，
# 参数为 start 等动作，转发给插件主控脚本处理。
/koolshare/scripts/igmpproxy_config.sh $1
