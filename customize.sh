#!/system/bin/sh

# 脚本配置变量
SKIPUNZIP=1
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

# 检查安装环境
if [ "$BOOTMODE" != true ]; then
  abort "-----------------------------------------------------------"
  ui_print "! 请在 Magisk/KernelSU/APatch Manager 中安装本模块"
  ui_print "! 不支持从 Recovery 安装"
  abort "-----------------------------------------------------------"
elif [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  abort "-----------------------------------------------------------"
  ui_print "! 请升级您的 KernelSU 及其管理器"
  abort "-----------------------------------------------------------"
fi

service_dir="/data/adb/service.d"
if [ "$KSU" = "true" ]; then
  ui_print "- 检测到 KernelSU 版本: $KSU_VER ($KSU_VER_CODE)"
  [ "$KSU_VER_CODE" -lt 10683 ] && service_dir="/data/adb/ksu/service.d"
elif [ "$APATCH" = "true" ]; then
  APATCH_VER=$(cat "/data/adb/ap/version")
  ui_print "- 检测到 APatch 版本: $APATCH_VER"
else
  ui_print "- 检测到 Magisk 版本: $MAGISK_VER ($MAGISK_VER_CODE)"
fi

# 设置服务目录并清理旧安装
mkdir -p "${service_dir}"
if [ -d "/data/adb/modules/box_for_magisk" ]; then
  rm -rf "/data/adb/modules/box_for_magisk"
  ui_print "- 已删除旧模块。"
fi

# 解压文件并配置目录
ui_print "- 正在安装 Box for Magisk/KernelSU/APatch"
unzip -o "$ZIPFILE" -x 'META-INF/*' -x 'webroot/*' -d "$MODPATH" >&2
if [ -d "/data/adb/box" ]; then
  ui_print "- 备份现有 box 数据"
  temp_bak=$(mktemp -d "/data/adb/box/box.XXXXXXXXXX")
  temp_dir="${temp_bak}"
  mv /data/adb/box/* "${temp_dir}/"
  mv "$MODPATH/box/"* /data/adb/box/
  backup_box="true"
else
  mv "$MODPATH/box" /data/adb/
fi

# 创建目录并解压必要文件
ui_print "- 创建目录"
mkdir -p /data/adb/box/ /data/adb/box/run/ /data/adb/box/bin/
mkdir -p $MODPATH/system/bin

ui_print "- 提取 uninstall.sh 和 box_service.sh"
unzip -j -o "$ZIPFILE" 'uninstall.sh' -d "$MODPATH" >&2
unzip -j -o "$ZIPFILE" 'box_service.sh' -d "${service_dir}" >&2
unzip -j -o "$ZIPFILE" 'sbfr' -d "$MODPATH/system/bin" >&2

# 设置权限
ui_print "- 设置权限"
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive /data/adb/box/ 0 3005 0755 0644
set_perm_recursive /data/adb/box/scripts/ 0 3005 0755 0700
set_perm ${service_dir}/box_service.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
set_perm $MODPATH/system/bin/sbfr 0 0 0755
chmod ugo+x ${service_dir}/box_service.sh $MODPATH/uninstall.sh /data/adb/box/scripts/*

# --- Key-check functions, inspired by Flar2 and Zackptg5 ---
# 通用函数：清空事件缓冲区
clear_key_events() {
    # 读取最多9999个事件，超时0.2秒，有效清空缓冲区
    timeout 0.2 getevent -c 9999 > /dev/null 2>&1
}

# 通用函数：音量键检测 (带超时)
volume_key_detection() {
    clear_key_events
    
    START_TIME=$(date +%s)
    while true; do
        NOW_TIME=$(date +%s)
        if [ $((NOW_TIME - START_TIME)) -gt 9 ]; then
            ui_print "  => 10秒内无输入，自动选择“取消”。"
            return 1 # 1 for "No/Cancel"
        fi

        # 捕获一个按键事件
        local key_event=$(timeout 1 getevent -qlc 1 2>/dev/null | 
            awk '/KEY_VOLUMEUP.*DOWN/ {print "UP"; exit} 
                 /KEY_VOLUMEDOWN.*DOWN/ {print "DOWN"; exit}')
        
        if [ "$key_event" = "UP" ]; then
            return 0 # 0 for "Yes/Confirm"
        elif [ "$key_event" = "DOWN" ]; then
            return 1 # 1 for "No/Cancel"
        fi
    done
}

# 通用函数：处理选择
handle_choice() {
    local question="$1"
    local choice_yes="${2:-是}"
    local choice_no="${3:-否}"

    ui_print " "
    ui_print "-----------------------------------------------------------"
    ui_print "- ${question}"
    ui_print "- [ 音量加(+) ]: ${choice_yes}"
    ui_print "- [ 音量减(-) ]: ${choice_no}"
    
    if volume_key_detection; then
        ui_print "  => 您选择了: ${choice_yes}"
        return 0
    else
        ui_print "  => 您选择了: ${choice_no}"
        return 1
    fi
}

# 下载内核组件提示
ui_print " "
ui_print "==========================================================="
ui_print "==         Box for Magisk/KernelSU/APatch 安装程序         =="
ui_print "==========================================================="

if handle_choice "是否需要下载内核或数据文件？" "是，进行下载" "否，全部跳过"; then

    if handle_choice "是否使用 'ghfast.top' 镜像加速接下来的下载？" "使用加速" "直接下载"; then
        ui_print "- 已启用 ghproxy 加速。"
        sed -i 's/use_ghproxy=.*/use_ghproxy="true"/' /data/adb/box/settings.ini
    else
        ui_print "- 已禁用 ghproxy 加速。"
        sed -i 's/use_ghproxy=.*/use_ghproxy="false"/' /data/adb/box/settings.ini
    fi

    # -- 下载选择 --
    DOWNLOAD_GEOX=false
    DOWNLOAD_UTILS=false
    CORES_TO_DOWNLOAD=""
    COMPONENTS_TO_DOWNLOAD=""

    if handle_choice "是否需要自定义下载内容？" "自定义" "一键下载所有组件"; then
        ui_print "- 进入自定义下载..."
        if handle_choice "是否下载 GeoX 数据文件 (geoip/geosite)？" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD geox"
        fi
        if handle_choice "是否下载实用工具 (yq, curl)？" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD utils"
        fi
        
        ui_print " "
        ui_print "-----------------------------------------------------------"
        ui_print "- 请选择您需要下载的内核:"
        if handle_choice "  - 下载 sing-box 内核？" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD sing-box"
        fi
        if handle_choice "  - 下载 mihomo 内核？" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD mihomo"
        fi
        if handle_choice "  - 下载 mihomo_smart (带Smart策略组) 内核？（与mihomo冲突，请勿同时下载）" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD mihomo_smart"
        fi
        if handle_choice "  - 下载 xray 内核？" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD xray"
        fi
        if handle_choice "  - 下载 v2fly 内核？" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD v2fly"
        fi
        if handle_choice "  - 下载 hysteria 内核？" "下载" "跳过"; then
            COMPONENTS_TO_DOWNLOAD="$COMPONENTS_TO_DOWNLOAD hysteria"
        fi
    else
        ui_print "- 已选择一键下载所有组件。"
        COMPONENTS_TO_DOWNLOAD="geox utils sing-box mihomo xray v2fly hysteria"
    fi

    # --- 下载执行 ---
    ui_print " "
    ui_print "==========================================================="
    ui_print "- 下载任务预览"
    ui_print "-----------------------------------------------------------"
    
    if [ -z "$COMPONENTS_TO_DOWNLOAD" ]; then
        ui_print "  - 无任何下载任务。"
    else
        # 移除行首的空格
        COMPONENTS_TO_DOWNLOAD=$(echo "$COMPONENTS_TO_DOWNLOAD" | sed 's/^ *//')
        ui_print "  - 将要下载: ${COMPONENTS_TO_DOWNLOAD}"
    fi
    ui_print "==========================================================="

    if [ -n "$COMPONENTS_TO_DOWNLOAD" ]; then
        if handle_choice "是否开始执行以上下载任务？" "开始下载" "取消全部"; then
            ui_print "- 开始执行下载..."
            for component in $COMPONENTS_TO_DOWNLOAD; do
              case "$component" in
                geox)
                  ui_print "  -> 正在下载 GeoX..."
                  /data/adb/box/scripts/box.tool upgeox_all
                  ;;
                utils)
                  ui_print "  -> 正在下载 yq..."
                  /data/adb/box/scripts/box.tool upyq
                  ui_print "  -> 正在下载 curl..."
                  /data/adb/box/scripts/box.tool upcurl
                  ;;
                *)
                  ui_print "  -> 正在下载内核: $component..."
                  /data/adb/box/scripts/box.tool upkernel "$component"
                  ;;
              esac
            done
            ui_print "- 所有下载任务已完成！"
        else
            ui_print "- 已取消所有下载任务。"
        fi
    fi
else
    ui_print "- 已跳过所有下载步骤。"
fi


# 恢复备份配置
if [ "${backup_box}" = "true" ]; then
  ui_print " "
  ui_print "- 正在恢复用户配置和数据..."

  # 1. 恢复核心配置文件 (clash/xray etc.)
  restore_config_dir() {
    config_dir="$1"
    if [ -d "${temp_dir}/${config_dir}" ]; then
        ui_print "  - 恢复 ${config_dir} 目录配置"
        cp -af "${temp_dir}/${config_dir}/." "/data/adb/box/${config_dir}/"
    fi
  }
  for dir in mihomo xray v2fly sing-box hysteria; do
    restore_config_dir "$dir"
  done

  # 2. 恢复根目录的配置文件
  ui_print "  - 恢复根目录配置文件"
  for conf_file in ap.list.cfg package.list.cfg crontab.cfg; do
    if [ -f "${temp_dir}/${conf_file}" ]; then
      cp -f "${temp_dir}/${conf_file}" "/data/adb/box/${conf_file}"
    fi
  done

  # 3. 恢复内核和工具 (如果本次未下载)
  restore_binary() {
    local bin_path_fragment="$1" # e.g., "curl" or "mihomo"
    local target_path="/data/adb/box/bin/${bin_path_fragment}"
    local backup_path="${temp_dir}/bin/${bin_path_fragment}"

    if [ ! -f "${target_path}" ] && [ -f "${backup_path}" ]; then
      ui_print "  - 恢复二进制文件: ${bin_path_fragment}"
      mkdir -p "$(dirname "${target_path}")"
      cp -f "${backup_path}" "${target_path}"
    fi
  }
  for bin_item in curl yq xray sing-box v2fly hysteria mihomo; do
    restore_binary "$bin_item"
  done

  # 4. 恢复运行时数据
  if [ -d "${temp_dir}/run" ]; then
    ui_print "  - 恢复日志、pid等运行时文件"
    cp -af "${temp_dir}/run/." "/data/adb/box/run/"
  fi
fi

# 更新模块描述（如未检测到内核）
[ -z "$(find /data/adb/box/bin -type f -name '*' ! -name '*.bak')" ] && sed -Ei 's/^description=(\[.*][[:space:]]*)?/description=[ 😱 模块已安装但需手动下载内核 ] /g' $MODPATH/module.prop

# 根据环境自定义模块名称
if [ "$KSU" = "true" ]; then
  sed -i "s/name=.*/name=Box for KernelSU/g" $MODPATH/module.prop
elif [ "$APATCH" = "true" ]; then
  sed -i "s/name=.*/name=Box for APatch/g" $MODPATH/module.prop
else
  sed -i "s/name=.*/name=Box for Magisk/g" $MODPATH/module.prop
fi
unzip -o "$ZIPFILE" 'webroot/*' -d "$MODPATH" >&2

# 清理临时文件
ui_print "- 清理残留文件"
rm -rf /data/adb/box/bin/.bin $MODPATH/box $MODPATH/sbfr $MODPATH/box_service.sh

# 完成安装
ui_print "- 安装完成，请重启设备。"
ui_print "- 重启后可通过 'su -c /dev/sbfr' 命令管理服务"