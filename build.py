#!/usr/bin/env python3
# -*- coding:utf-8 -*-
#
# 打包脚本：读 config.json.js → 回写 igmpproxy/version → 生成 igmpproxy.tar.gz
# → 把 tar.gz 的 md5 写回 config.json.js（与 avman-cn/Koolcenter_ddns-go 的 build.py 同一套约定，
# 仅改成 Python 3 语法，可直接在没装 python2 的机器上跑）。
#
# 用法：python3 build.py
# 产物：igmpproxy.tar.gz（软件中心「离线安装」上传这个包）

import os
import json
import hashlib

parent_path = os.path.dirname(os.path.realpath(__file__))
conf_path = os.path.join(parent_path, "config.json.js")


def md5sum(full_path):
    h = hashlib.md5()
    with open(full_path, "rb") as rf:
        for chunk in iter(lambda: rf.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def get_or_create():
    conf = {}
    if not os.path.isfile(conf_path):
        print("config.json.js not found, build.py is root path. auto write config.json.js")
        module_name = os.path.basename(parent_path)
        conf["module"] = module_name
        conf["version"] = "0.0.1"
        conf["home_url"] = "Module_%s.asp" % module_name
        conf["title"] = "title of " + module_name
        conf["description"] = "description of " + module_name
    else:
        with open(conf_path, "r", encoding="utf-8") as fc:
            conf = json.loads(fc.read())
    return conf


def build_module():
    conf = get_or_create()

    if "module" not in conf:
        print("module is not in config.json.js")
        return

    module = conf["module"]
    module_path = os.path.join(parent_path, module)
    if not os.path.isdir(module_path):
        print("not found %s dir, check config.json.js is module ?" % module_path)
        return

    if not os.path.isfile(os.path.join(module_path, "install.sh")):
        print("not found %s/install.sh, check install.sh file" % module)
        return

    print("build...")

    # 版本号以 config.json.js 为准
    with open(os.path.join(module_path, "version"), "w", encoding="utf-8", newline="\n") as fv:
        fv.write(conf["version"])

    tar_path = os.path.join(parent_path, module + ".tar.gz")
    if os.path.isfile(tar_path):
        os.remove(tar_path)

    # 关掉 gzip 的时间戳，同样的内容得到同样的包，md5 才不会每次都变
    rc = os.system(
        "cd '%s' && tar --exclude='.DS_Store' -zcf '%s' '%s'"
        % (parent_path, module + ".tar.gz", module)
    )
    if rc != 0 or not os.path.isfile(tar_path):
        print("tar failed (rc=%s)" % rc)
        return

    conf["md5"] = md5sum(tar_path)
    with open(conf_path, "w", encoding="utf-8", newline="\n") as fw:
        json.dump(conf, fw, sort_keys=True, indent=4, ensure_ascii=False)
        fw.write("\n")

    print("build done: %s.tar.gz  md5=%s" % (module, conf["md5"]))


build_module()
