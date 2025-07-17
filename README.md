# 📦 Box for Android 模块

一个高度可定制的安卓代理模块，专为 Magisk 和 KernelSU 等设计，旨在提供稳定、灵活、透明的网络代理体验。

本项目深受 [CHIZI-0618/box4magisk](https://github.com/CHIZI-0618/box4magisk) 和 [taamarin/box_for_magisk](https://github.com/taamarin/box_for_magisk) 的启发和影响，在此向原作者们表示衷心的感谢！

---

## 📋 目录

- [目录结构](#-目录结构)
- [必要依赖](#-必要依赖)
- [安装步骤](#-安装步骤)
- [核心脚本指令](#-核心脚本指令)
- [配套管理APP](#-配套管理app)
- [致谢](#-致谢)

---

## 📁 目录结构

模块刷入后，主要工作目录位于 `/data/adb/box/`。结构如下：

```
/data/adb/box/
├── bin/                # 存放 clash, sing-box 等代理核心的可执行文件
│
├── hysteria/           # Hysteria 核心的配置文件目录 (e.g., config.yaml)
├── mihomo/             # Mihomo 核心的配置文件目录 (e.g., config.yaml)
├── sing-box/           # Sing-box 核心的配置文件目录 (e.g., config.json)
├── v2fly/              # V2Fly 核心的配置文件目录 (e.g., config.json)
├── xray/               # Xray 核心的配置文件目录 (e.g., config.json)
│
├── scripts/            # 存放模块的核心脚本
│   ├── box.service     # 主要服务管理脚本
│   ├── box.iptables    # 防火墙规则管理脚本
│   └── box.tool        # 实用工具箱脚本
│
├── run/                # 运行时目录，用于存放日志、PID等临时文件
│
├── ap.list.cfg         # [可配置] 应用列表配置
├── crontab.cfg         # [可配置] 定时任务配置
├── package.list.cfg    # [可配置] 包列表配置
└── settings.ini        # [重要] 模块总配置文件，你的主要配置区域！
```

> **注意**: `run/` 目录可能在模块首次运行时自动创建。

---

## 🔧 必要依赖

为了确保模块所有功能正常运行，系统环境中必须包含以下两个组件：

- **`yq`**: 一个轻量级的命令行 YAML, JSON, XML 处理器，用于解析和修改配置文件。
- **`curl`**: 一个强大的网络数据传输工具，用于下载订阅、更新资源等。

> **请注意**: 缺少以上任一依赖都可能导致模块无法启动或功能异常。

---

## 🚀 安装步骤

1.  从发布渠道下载最新的模块 `zip` 刷机包。
2.  打开 Magisk Manager 或 KernelSU Manager。
3.  从本地安装，选择下载好的 `zip` 文件进行刷入。
4.  根据提示完成安装并 **重启您的设备**。
5.  **核心放置**: 将您选择的代理核心可执行文件（如 `clash`, `sing-box`）放置到 `/data/adb/box/bin/` 目录下。
6.  **基础配置**: 修改 `/data/adb/box/settings.ini` 和 `conf/` 目录下的相应配置文件，至少要配置好您的代理节点信息。
7.  启动服务！(参考下一章节)

---

## ⚙️ 核心脚本指令

可使用 `su` 获取 root 权限后执行以下命令，来管理模块的运行状态。

### `box.service`

模块的主服务控制脚本，用于管理代理核心的生命周期和定时任务。

```bash
# 用法: su -c /data/adb/box/scripts/box.service {start|stop|restart|status|cron|kcron}
```

### `box.iptables`

专门用于管理透明代理所依赖的 `iptables` 防火墙规则。

```bash
# 用法: su -c /data/adb/box/scripts/box.iptables {enable|disable|renew}
```

### `box.tool`

一个多功能的工具箱，集成了多种实用功能，如更新订阅、检查配置、下载核心等。

```bash
# 用法: su -c /data/adb/box/scripts/box.tool {check|memcg|cpuset|blkio|geosub|geox|subs|upkernel [name]|upkernels [name...]|upgeox_all|upxui|upyq|upcurl|reload|webroot|bond0|bond1|all}
```

---

## 📱 配套管理APP

可通过图形化界面轻松完成切换代理、查看日志、修改配置等操作。

**获取方式**:
请访问以下 Telegram 频道获取最新版本的APP：
➡️ **[RE](https://t.me/zero_o0)**

---

## 🙏 致谢

本项目的诞生离不开以下优秀项目的启发和参考，它们为 `Box for Android` 提供了坚实的基础和宝贵的灵感。

- **[CHIZI-0618/box4magisk](https://github.com/CHIZI-0618/box4magisk)**: 一个功能全面的 Magisk 代理模块，提供了诸多核心功能的实现思路。
- **[taamarin/box_for_magisk](https://github.com/taamarin/box_for_magisk)**: 同样是一个优秀的代理模块项目，为本项目提供了重要的参考。
