#!/system/bin/sh

# 日志文件路径
LOG_FILE="/data/adb/box/run/tool.log"
mkdir -p "$(dirname "$LOG_FILE")"

# 将标准输出和标准错误重定向到日志文件，每次运行时覆盖
exec > "$LOG_FILE" 2>&1
echo "box.tool 脚本启动于: $(date)"
echo "执行命令: $0 $@"
echo "----------------------------------------"

scripts_dir="${0%/*}"

# --- 默认变量 ---
# user agent
user_agent="box_for_root"
# 是否使用 ghproxy 加速 GitHub 下载
url_ghproxy="https://ghfast.top"
use_ghproxy="false"
# 启用/禁用下载稳定的 mihomo 内核
mihomo_stable="enable"
singbox_stable="enable"

# --- 加载用户配置 ---
# 这会覆盖上面设置的默认值
source /data/adb/box/settings.ini

# --- 本地日志函数 ---
# 覆盖 settings.ini 中的 log 函数，以实现更简洁、统一的日志格式，
# 并且只输出到 tool.log 文件，避免干扰 runs.log。
log() {
    level="$1"
    shift
    message="$@"
    current_time_simple=$(date +"%H:%M:%S")
    echo "[$current_time_simple] [$level] $message"
}
# --- 日志函数结束 ---

rev1="busybox wget --no-check-certificate -qO-"
if which curl > /dev/null 2>&1; then
  rev1="curl --insecure -sL"
fi

# 更新文件
upfile() {
  file="$1"
  update_url="$2"
  file_bak="${file}.bak"
  [ -f "${file}" ] && mv "${file}" "${file_bak}"

  # 使用 ghproxy
  if [ "${use_ghproxy}" = "true" ] && [[ "${update_url}" == @(https://github.com/*|https://raw.githubusercontent.com/*|https://gist.github.com/*|https://gist.githubusercontent.com/*) ]]; then
    update_url="${url_ghproxy}/${update_url}"
  fi
  
  log Info "开始下载: ${update_url}"
  log Debug "保存到: ${file}"

  if which curl > /dev/null 2>&1; then
    # -sSL: 静默模式但仍然显示错误
    if ! curl -sSL --insecure --user-agent "${user_agent}" -o "${file}" "${update_url}"; then
      log Error "使用 curl 下载失败"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi
  else
    # -q: 完全静默, 使用 || 判断错误
    if ! busybox wget -q --no-check-certificate --user-agent "${user_agent}" -O "${file}" "${update_url}"; then
      log Error "使用 wget 下载失败"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi
  fi
  
  log Info "下载成功"
  rm -f "${file_bak}" 2>/dev/null
  return 0
}

# 重启核心进程
restart_box() {
  local core_to_restart=${1:-$bin_name}
  if [ -z "$core_to_restart" ]; then
    log Error "restart_box: 未指定需要重启的核心"
    return 1
  fi
  
  "${scripts_dir}/box.service" restart "$core_to_restart"
  
  local pid
  pid=$(busybox pidof "$core_to_restart")

  if [ -n "$pid" ]; then
    log Info "$core_to_restart 重启完成 [$(date +"%F %R")]"
  else
    log Error "重启 $core_to_restart 失败."
    "${scripts_dir}/box.iptables" disable >/dev/null 2>&1
  fi
}

# 检查配置
check() {
  case "${bin_name}" in
    sing-box)
      if ${bin_path} check -D "${box_dir}/${bin_name}" --config-directory "${box_dir}/sing-box" > "${box_run}/${bin_name}_report.log" 2>&1; then
        log Info "${sing_config} 检查通过"
      else
        log Debug "${sing_config}"
        log Error "$(<"${box_run}/${bin_name}_report.log")" >&2
      fi
      ;;
    mihomo)
      if ${bin_path} -t -d "${box_dir}/mihomo" -f "${mihomo_config}" > "${box_run}/${bin_name}_report.log" 2>&1; then
        log Info "${mihomo_config} 检查通过"
      else
        log Debug "${mihomo_config}"
        log Error "$(<"${box_run}/${bin_name}_report.log")" >&2
      fi
      ;;
    xray)
      export XRAY_LOCATION_ASSET="${box_dir}/xray"
      if ${bin_path} -test -confdir "${box_dir}/${bin_name}" > "${box_run}/${bin_name}_report.log" 2>&1; then
        log Info "配置检查通过"
      else
        echo "$(ls ${box_dir}/${bin_name})"
        log Error "$(<"${box_run}/${bin_name}_report.log")" >&2
      fi
      ;;
    v2fly)
      export V2RAY_LOCATION_ASSET="${box_dir}/v2fly"
      if ${bin_path} test -d "${box_dir}/${bin_name}" > "${box_run}/${bin_name}_report.log" 2>&1; then
        log Info "配置检查通过"
      else
        echo "$(ls ${box_dir}/${bin_name})"
        log Error "$(<"${box_run}/${bin_name}_report.log")" >&2
      fi
      ;;
    hysteria)
      true
      ;;
    *)
      log Error "<${bin_name}> 未知的二进制文件."
      exit 1
      ;;
  esac
}

# 重载基础配置
reload() {
  ip_port=$(if [ "${bin_name}" = "mihomo" ]; then busybox awk '/external-controller:/ {print $2}' "${mihomo_config}"; else find /data/adb/box/sing-box/ -type f -name 'config.json' -exec busybox awk -F'[:,]' '/"external_controller"/ {print $2":"$3}' {} \; | sed 's/^[ \t]*//;s/"//g'; fi;)
  secret=$(if [ "${bin_name}" = "mihomo" ]; then busybox awk '/^secret:/ {print $2}' "${mihomo_config}" | sed 's/"//g'; else find /data/adb/box/sing-box/ -type f -name 'config.json' -exec busybox awk -F'"' '/"secret"/ {print $4}' {} \; | head -n 1; fi;)

  curl_command="curl"
  if ! command -v curl >/dev/null 2>&1; then
    if [ ! -e "${bin_dir}/curl" ]; then
      log Debug "$bin_dir/curl 文件未找到, 无法重载配置"
      log Debug "开始从 GitHub 下载"
      upcurl || exit 1
    fi
    curl_command="${bin_dir}/curl"
  fi

  check

  case "${bin_name}" in
    "mihomo")
      endpoint="http://${ip_port}/configs?force=true"

      if ${curl_command} -X PUT -H "Authorization: Bearer ${secret}" "${endpoint}" -d '{"path": "", "payload": ""}' 2>&1; then
        log Info "${bin_name} 配置重载成功"
        return 0
      else
        log Error "${bin_name} 配置重载失败 !"
        return 1
      fi
      ;;
    "sing-box")
      endpoint="http://${ip_port}/configs?force=true"
      if ${curl_command} -X PUT -H "Authorization: Bearer ${secret}" "${endpoint}" -d '{"path": "", "payload": ""}' 2>&1; then
        log Info "${bin_name} 配置重载成功."
        return 0
      else
        log Error "${bin_name} 配置重载失败 !"
        return 1
      fi
      ;;
    "xray"|"v2fly"|"hysteria")
      if [ -f "${box_pid}" ]; then
        if kill -0 "$(<"${box_pid}" 2>/dev/null)"; then
          restart_box
        fi
      fi
      ;;
    *)
      log Warning "${bin_name} 不支持使用 API 重载配置."
      return 1
      ;;
  esac
}

# 获取最新的 curl
upcurl() {
  local arch
  case $(uname -m) in
    "aarch64") arch="aarch64" ;;
    "armv7l"|"armv8l") arch="armv7" ;;
    "i686") arch="i686" ;;
    "x86_64") arch="amd64" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac

  mkdir -p "${bin_dir}/backup"
  [ -f "${bin_dir}/curl" ] && cp "${bin_dir}/curl" "${bin_dir}/backup/curl.bak" >/dev/null 2>&1

  local latest_version=$($rev1 "https://api.github.com/repos/stunnel/static-curl/releases" | grep "tag_name" | busybox grep -oE "[0-9.]*" | head -1)
  local download_link="https://github.com/stunnel/static-curl/releases/download/${latest_version}/curl-linux-${arch}-glibc-${latest_version}.tar.xz"
  local temp_archive="${box_dir}/curl.tar.xz"
  local temp_extract_dir="${box_dir}/curl_temp"

  log Debug "下载 ${download_link}"
  if ! upfile "${temp_archive}" "${download_link}"; then
    log Error "下载 curl 失败"
    return 1
  fi
  
  rm -rf "${temp_extract_dir}"
  mkdir -p "${temp_extract_dir}"

  if ! busybox tar -xJf "${temp_archive}" -C "${temp_extract_dir}" >&2; then
    log Error "解压 ${temp_archive} 失败" >&2
    cp "${bin_dir}/backup/curl.bak" "${bin_dir}/curl" >/dev/null 2>&1 && log Info "已恢复 curl"
    rm -f "${temp_archive}"
    rm -rf "${temp_extract_dir}"
    return 1
  fi

  # 查找并移动 curl 二进制文件
  local curl_binary=$(find "${temp_extract_dir}" -type f -name "curl")
  if [ -n "${curl_binary}" ]; then
    mv "${curl_binary}" "${bin_dir}/curl"
    log Info "curl 已成功更新到 ${bin_dir}/curl"
  else
    log Error "在解压的存档中未找到 curl 二进制文件"
    rm -f "${temp_archive}"
    rm -rf "${temp_extract_dir}"
    return 1
  fi
  
  chown "${box_user_group}" "${box_dir}/bin/curl"
  chmod 0755 "${bin_dir}/curl"

  rm -f "${temp_archive}"
  rm -rf "${temp_extract_dir}"
}

# 获取最新的 yq
upyq() {
  local arch platform
  case $(uname -m) in
    "aarch64") arch="arm64"; platform="android" ;;
    "armv7l"|"armv8l") arch="arm"; platform="android" ;;
    "i686") arch="386"; platform="android" ;;
    "x86_64") arch="amd64"; platform="android" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac

  local download_link="https://github.com/taamarin/yq/releases/download/prerelease/yq_${platform}_${arch}"

  log Debug "下载 ${download_link}"
  upfile "${box_dir}/bin/yq" "${download_link}"

  chown "${box_user_group}" "${box_dir}/bin/yq"
  chmod 0755 "${box_dir}/bin/yq"
}

# 检查并更新 geoip 和 geosite
upgeox() {
  geodata_mode=$(busybox awk '!/^ *#/ && /geodata-mode:*./{print $2}' "${mihomo_config}")
  [ -z "${geodata_mode}" ] && geodata_mode=false
  case "${bin_name}" in
    mihomo)
      geoip_file="${box_dir}/mihomo/Country.mmdb"
      geoip_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/country-lite.mmdb"
      geosite_file="${box_dir}/mihomo/GeoSite.dat"
      geosite_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/geosite.dat"
      ;;
    sing-box)
      geoip_file="${box_dir}/sing-box/geoip.db"
      geoip_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/geoip-lite.db"
      geosite_file="${box_dir}/sing-box/geosite.db"
      geosite_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/geosite.db"
      ;;
    *)
      geoip_file="${box_dir}/${bin_name}/geoip.dat"
      geoip_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/geoip-lite.dat"
      geosite_file="${box_dir}/${bin_name}/geosite.dat"
      geosite_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/geosite.dat"
      ;;
  esac
  if [ "${update_geo}" = "true" ] && { log Info "每日更新 GeoX" && log Debug "正在下载 ${geoip_url}"; } && upfile "${geoip_file}" "${geoip_url}" && { log Debug "正在下载 ${geosite_url}" && upfile "${geosite_file}" "${geosite_url}"; }; then

    find "${box_dir}/${bin_name}" -maxdepth 1 -type f -name "*.db.bak" -delete
    find "${box_dir}/${bin_name}" -maxdepth 1 -type f -name "*.dat.bak" -delete
    find "${box_dir}/${bin_name}" -maxdepth 1 -type f -name "*.mmdb.bak" -delete

    log Debug "更新 GeoX 于 $(date "+%F %R")"
    return 0
  else
   return 1
  fi
}

upgeox_all() {
  local original_bin_name=$bin_name
  for core in mihomo sing-box xray v2fly; do
      bin_name=$core
      upgeox
  done
  bin_name=$original_bin_name
}

# 检查并更新订阅
upsubs() {
  enhanced=false
  update_file_name="${mihomo_config}"
  if [ "${renew}" != "true" ]; then
    yq="yq"
    if ! command -v yq &>/dev/null; then
      if [ ! -e "${box_dir}/bin/yq" ]; then
        log Debug "yq 文件未找到, 开始从 GitHub 下载"
        ${scripts_dir}/box.tool upyq
      fi
      yq="${box_dir}/bin/yq"
    fi
    enhanced=true
    update_file_name="${update_file_name}.subscription"
  fi

  case "${bin_name}" in
    "mihomo")
      if [ -n "${subscription_url_mihomo}" ]; then
        if [ "${update_subscription}" = "true" ]; then
          log Info "每日更新订阅"
          log Debug "正在下载 ${update_file_name}"
          if upfile "${update_file_name}" "${subscription_url_mihomo}"; then
            log Info "${update_file_name} 已保存"
            if [ "${enhanced}" = "true" ]; then
              if ${yq} 'has("proxies")' "${update_file_name}" | grep -q "true"; then
                mkdir -p "$(dirname "${mihomo_provide_config}")"
                if ${yq} '.proxies' "${update_file_name}" > "${mihomo_provide_config}" && \
                   ${yq} -i '{"proxies": .}' "${mihomo_provide_config}"; then

                  if [ "${mihomo_replace_proxies}" = "true" ]; then
                    if ${yq} 'has("proxy-providers")' "${mihomo_config}" | grep -q "true"; then
                      ${yq} -i 'del(.proxy-providers)' "${mihomo_config}"
                    fi
                    # remove old proxies before appending proxies from subscription
                    ${yq} -i 'del(.proxies)' "${mihomo_config}"
                    cat "${mihomo_provide_config}" >> "${mihomo_config}"
                  fi

                  if [ "${custom_rules_subs}" = "true" ]; then
                    # remove rule-providers when use custom rules from subscription
                    if ${yq} 'has("rule-providers")' "${mihomo_config}" | grep -q "true"; then
                      ${yq} -i 'del(.rule-providers)' "${mihomo_config}"
                    fi
                    if ${yq} '.rules' "${update_file_name}" >/dev/null 2>&1; then
                      mkdir -p "$(dirname "${mihomo_provide_rules}")"
                      ${yq} '.rules' "${update_file_name}" > "${mihomo_provide_rules}"
                      ${yq} -i '{"rules": .}' "${mihomo_provide_rules}"
                      ${yq} -i 'del(.rules)' "${mihomo_config}"
                      cat "${mihomo_provide_rules}" >> "${mihomo_config}"
                    fi
                  fi

                  if [ "${custom_proxy_groups_subs}" = "true" ]; then
                    if ${yq} '.proxy-groups' "${update_file_name}" >/dev/null 2>&1; then
                      ${yq} '.proxy-groups' "${update_file_name}" > "${mihomo_provide_proxy_groups}"
                      ${yq} -i '{"proxy-groups": .}' "${mihomo_provide_proxy_groups}"
                      ${yq} -i 'del(.proxy-groups)' "${mihomo_config}"
                      cat "${mihomo_provide_proxy_groups}" >> "${mihomo_config}"
                    fi
                  fi

                  log Info "订阅成功"
                  log Info "更新订阅于 $(date +"%F %R")"
                  rm -f "${update_file_name}.bak" 2>/dev/null
                  rm -f "${update_file_name}"
                else
                  log Error "从 ${update_file_name} 提取 'proxies' 失败"
                  return 1
                fi
              elif ${yq} '.. | select(tag == "!!str")' "${update_file_name}" | grep -qE "vless://|vmess://|ss://|hysteria://|trojan://"; then
                mkdir -p "$(dirname "${mihomo_provide_config}")"
                mv "${update_file_name}" "${mihomo_provide_config}"
              else
                log Error "${update_file_name} 更新订阅失败"
                return 1
              fi
            fi
            return 0
          else
            log Error "更新订阅失败"
            return 1
          fi
        else
          log Warning "更新订阅: $update_subscription"
          return 1
        fi
      else
        log Warning "${bin_name} 订阅链接为空..."
        return 0
      fi
      ;;
    "xray"|"v2fly"|"sing-box"|"hysteria")
      log Warning "${bin_name} 不支持订阅功能.."
      return 1
      ;;
    *)
      log Error "<${bin_name}> 未知的二进制文件."
      return 1
      ;;
  esac
}

upkernel() {
  local core_to_update="$1"
  if [ -z "$core_to_update" ]; then
    log Error "upkernel: 未提供核心名称"
    return 1
  fi

  mkdir -p "${bin_dir}/backup"
  if [ -f "${bin_dir}/${core_to_update}" ]; then
    cp "${bin_dir}/${core_to_update}" "${bin_dir}/backup/${core_to_update}.bak" >/dev/null 2>&1
  fi
  case $(uname -m) in
    "aarch64") 
      if [ "$core_to_update" = "mihomo" ]; then 
        arch="arm64-v8"
      else 
        arch="arm64"
      fi
      platform="android"
      ;;
    "armv7l"|"armv8l") arch="armv7"; platform="linux" ;;
    "i686") arch="386"; platform="linux" ;;
    "x86_64") arch="amd64"; platform="linux" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac
  
  local file_kernel="${core_to_update}-${arch}"
  case "${core_to_update}" in
    "mihomo_smart")
      log Info "正在更新 mihomo-smart 核心 (来自 vernesong/mihomo)"
      local arch_smart
      case $(uname -m) in
        "aarch64") arch_smart="arm64-v8" ;;
        *) log Error "mihomo-smart 当前仅支持 aarch64 架构"; return 1 ;;
      esac

      local release_page_url="https://github.com/vernesong/mihomo/releases/expanded_assets/Prerelease-Alpha"
      [ "${use_ghproxy}" = "true" ] && release_page_url="${url_ghproxy}/${release_page_url}"
      
      # 从发布页面动态解析 smart-xxxxxxx 版本
      local smart_version_tag=$($rev1 "${release_page_url}" | busybox grep -oE "smart-[a-f0-9]+" | head -1)

      if [ -z "$smart_version_tag" ]; then
        log Error "获取 mihomo-smart 最新版本标签失败"
        return 1
      fi

      local download_link="https://github.com/vernesong/mihomo/releases/download/Prerelease-Alpha/mihomo-android-${arch_smart}-alpha-${smart_version_tag}.gz"
      local file_kernel="${core_to_update}-${arch_smart}"
      
      log Debug "下载 ${download_link}"
      upfile "${box_dir}/${file_kernel}.gz" "${download_link}" && xkernel "$core_to_update" "" "" "" "$file_kernel"
      ;;
    "sing-box")
      api_url="https://api.github.com/repos/SagerNet/sing-box/releases"
      url_down="https://github.com/SagerNet/sing-box/releases"

      if [ "${singbox_stable}" = "disable" ]; then
        log Debug "下载 ${core_to_update} 预发行版"
        latest_version=$($rev1 "${api_url}" | grep "tag_name" | busybox grep -oE "v[0-9].*" | head -1 | cut -d'"' -f1)
      else
        log Debug "下载 ${core_to_update} 最新稳定版"
        latest_version=$($rev1 "${api_url}/latest" | grep "tag_name" | busybox grep -oE "v[0-9.]*" | head -1)
      fi

      if [ -z "$latest_version" ]; then
        log Error "获取 sing-box 最新 稳定版/测试版/Alpha版 失败"
        return 1
      fi

      download_link="${url_down}/download/${latest_version}/sing-box-${latest_version#v}-${platform}-${arch}.tar.gz"
      log Debug "下载 ${download_link}"
      upfile "${box_dir}/${file_kernel}.tar.gz" "${download_link}" && xkernel "$core_to_update" "$platform" "$arch" "$latest_version" "$file_kernel"
      ;;
    "mihomo")
      download_link="https://github.com/MetaCubeX/mihomo/releases"

      if [ "${mihomo_stable}" = "enable" ]; then
        latest_version=$($rev1 "https://api.github.com/repos/MetaCubeX/mihomo/releases" | grep "tag_name" | busybox grep -oE "v[0-9.]*" | head -1)
        tag="$latest_version"
      else
        if [ "$use_ghproxy" == true ]; then
          download_link="${url_ghproxy}/${download_link}"
        fi
        tag="Prerelease-Alpha"
        latest_version=$($rev1 "${download_link}/expanded_assets/${tag}" | busybox grep -oE "alpha-[0-9a-z]+" | head -1)
      fi

      # Android uses zip, other platforms use gz
      local extension="gz"
      if [ "${platform}" = "android" ]; then
        extension="zip"
      fi

      filename="mihomo-${platform}-${arch}-${latest_version}"
      log Debug "下载 ${download_link}/download/${tag}/${filename}.gz"
      upfile "${box_dir}/${file_kernel}.gz" "${download_link}/download/${tag}/${filename}.gz" && xkernel "$core_to_update" "" "" "" "$file_kernel"
      ;;
    "xray"|"v2fly")
      [ "${core_to_update}" = "xray" ] && bin='Xray' || bin='v2ray'
      api_url="https://api.github.com/repos/$(if [ "${core_to_update}" = "xray" ]; then echo "XTLS/Xray-core/releases"; else echo "v2fly/v2ray-core/releases"; fi)"
      latest_version=$($rev1 ${api_url} | grep "tag_name" | busybox grep -oE "v[0-9.]*" | head -1)

      case $(uname -m) in
        "i386") download_file="$bin-linux-32.zip" ;;
        "x86_64") download_file="$bin-linux-64.zip" ;;
        "armv7l"|"armv8l") download_file="$bin-linux-arm32-v7a.zip" ;;
        "aarch64") download_file="$bin-android-arm64-v8a.zip" ;;
        *) log Error "不支持的架构: $(uname -m)" >&2; return 1 ;;
      esac
      download_link="https://github.com/$(if [ "${core_to_update}" = "xray" ]; then echo "XTLS/Xray-core/releases"; else echo "v2fly/v2ray-core/releases"; fi)"
      log Debug "正在下载 ${download_link}/download/${latest_version}/${download_file}"
      upfile "${box_dir}/${file_kernel}.zip" "${download_link}/download/${latest_version}/${download_file}" && xkernel "$core_to_update" "" "" "" "$file_kernel"
      ;;
    "hysteria")
      local arch
      case $(uname -m) in
        "aarch64") arch="arm64" ;;
        "armv7l" | "armv8l") arch="armv7" ;;
        "i686") arch="386" ;;
        "x86_64") arch="amd64" ;;
        *)
          log Warning "不支持的架构: $(uname -m)"
          return 1
          ;;
      esac
      mkdir -p "${bin_dir}/backup"
      if [ -f "${bin_dir}/hysteria" ]; then
        cp "${bin_dir}/hysteria" "${bin_dir}/backup/hysteria.bak" >/dev/null 2>&1
      fi
      local latest_version=$($rev1 "https://api.github.com/repos/apernet/hysteria/releases" | grep "tag_name" | grep -oE "[0-9.].*" | head -1 | sed 's/,//g' | cut -d '"' -f 1)

      local download_link="https://github.com/apernet/hysteria/releases/download/app%2Fv${latest_version}/hysteria-android-${arch}"

      log Debug "正在下载 ${download_link}"
      upfile "${bin_dir}/hysteria" "${download_link}" && xkernel "$core_to_update"
      ;;
    *)
      log Error "<${core_to_update}> 未知的二进制文件."
      return 1
      ;;
  esac
}

upkernels() {
  for core in "$@"; do
    upkernel "$core"
  done
}

# 解压并处理核心
xkernel() {
  local core_to_process="$1"
  local platform="$2"
  local arch="$3"
  local latest_version="$4"
  local file_kernel="$5"
  
  local original_bin_name=$bin_name
  # 确定最终的二进制文件名。mihomo_smart 只是一个别名，实际更新的是 mihomo。
  local target_bin_name="$core_to_process"
  if [ "$core_to_process" = "mihomo_smart" ]; then
    target_bin_name="mihomo"
  fi
  
  bin_name=$core_to_process

  case "${core_to_process}" in
    "mihomo"|"mihomo_smart")
      gunzip_command="gunzip"
      if ! command -v gunzip >/dev/null 2>&1; then
        gunzip_command="busybox gunzip"
      fi

      if ${gunzip_command} -f "${box_dir}/${file_kernel}.gz" >&2 && mv "${box_dir}/${file_kernel}" "${bin_dir}/${target_bin_name}"; then
        log Info "${target_bin_name} 已成功更新 (来自: ${core_to_process})"
      else
        log Error "解压或移动 ${target_bin_name} 核心失败."
        bin_name=$original_bin_name # 恢复原始的bin_name
        return 1
      fi
      ;;
    "sing-box")
      tar_command="tar"
      if ! command -v tar >/dev/null 2>&1; then
        tar_command="busybox tar"
      fi
      log Info "正在解压 Sing-Box 核心..."
      if ${tar_command} -xf "${box_dir}/${file_kernel}.tar.gz" -C "${bin_dir}" >/dev/null; then
        mv "${bin_dir}/sing-box-${latest_version#v}-${platform}-${arch}/sing-box" "${bin_dir}/${core_to_process}"
        if [ -f "${box_pid}" ]; then
          rm -rf /data/adb/box/sing-box/cache.db
          restart_box "$core_to_process"
        else
          log Debug "${core_to_process} 无需重启."
        fi
      else
        log Error "解压 ${box_dir}/${file_kernel}.tar.gz 失败."
      fi
      [ -d "${bin_dir}/sing-box-${latest_version#v}-${platform}-${arch}" ] && \
        rm -r "${bin_dir}/sing-box-${latest_version#v}-${platform}-${arch}"
      ;;
    "v2fly"|"xray")
      bin="xray"
      if [ "${core_to_process}" != "xray" ]; then
        bin="v2ray"
      fi
      unzip_command="unzip"
      if ! command -v unzip >/dev/null 2>&1; then
        unzip_command="busybox unzip"
      fi

      mkdir -p "${bin_dir}/update"
      log Info "正在解压 ${bin} 核心..."
      if ${unzip_command} -oq "${box_dir}/${file_kernel}.zip" "${bin}" -d "${bin_dir}/update"; then
        if mv "${bin_dir}/update/${bin}" "${bin_dir}/${core_to_process}"; then
          true # 成功
        else
          log Error "移动核心失败."
          rm -rf "${bin_dir}/update"
          return 1
        fi
      else
        log Error "解压 ${box_dir}/${file_kernel}.zip 失败."
        rm -rf "${bin_dir}/update"
        return 1
      fi
      rm -rf "${bin_dir}/update"
      ;;
    "hysteria")
      # Hysteria 是单个二进制文件，upfile 直接下载完成，这里无需额外操作
      true
      ;;
    *)
      log Error "<${core_to_process}> 未知的二进制文件."
      bin_name=$original_bin_name
      return 1
      ;;
  esac

  # 清理下载的临时文件
  find "${box_dir}" -maxdepth 1 -type f -name "${file_kernel}.*" -delete

  # 为最终的二进制文件设置正确的权限
  chown ${box_user_group} "${bin_dir}/${target_bin_name}"
  chmod 0755 "${bin_dir}/${target_bin_name}"
  
  # 如果更新的核心就是当前正在运行的核心，则重启服务
  if [ -f "${box_pid}" ]; then
    if [ "$original_bin_name" = "$target_bin_name" ]; then
      log Info "检测到正在运行的核心已被更新，将自动重启服务..."
      restart_box "$target_bin_name"
    else
      log Info "${target_bin_name} 已更新，但当前运行的是 ${original_bin_name}，无需重启。"
    fi
  else
    log Info "服务未在运行，无需重启。"
  fi
  
  bin_name=$original_bin_name
}

# 更新 yacd
upxui() {
  xdashboard="${bin_name}/dashboard"
  if [[ "${bin_name}" == @(mihomo|sing-box) ]]; then
    file_dashboard="${box_dir}/${xdashboard}.zip"
    url="https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
    dir_name="dist"
    
    # 使用 upfile for download
    if upfile "${file_dashboard}" "${url}"; then
      if [ ! -d "${box_dir}/${xdashboard}" ]; then
        log Info "面板文件夹不存在, 正在创建"
        mkdir "${box_dir}/${xdashboard}"
      else
        rm -rf "${box_dir}/${xdashboard}/"*
      fi
      if command -v unzip >/dev/null 2>&1; then
        unzip_command="unzip"
      else
        unzip_command="busybox unzip"
      fi
      log Info "正在解压 Dashboard..."
      # Use -oq for quiet unzip
      if "${unzip_command}" -oq "${file_dashboard}" "${dir_name}/*" -d "${box_dir}/${xdashboard}"; then
        mv -f "${box_dir}/${xdashboard}/$dir_name"/* "${box_dir}/${xdashboard}/"
        rm -f "${file_dashboard}"
        rm -rf "${box_dir}/${xdashboard}/${dir_name}"
        log Info "Dashboard 更新成功"
      else
         log Error "解压 Dashboard 失败"
         rm -f "${file_dashboard}"
         return 1
      fi
    else
      log Error "下载 Dashboard 失败"
      return 1
    fi
    return 0
  else
    log Debug "${bin_name} 不支持面板"
    return 1
  fi
}

cgroup_blkio() {
  local pid_file="$1"
  local fallback_weight="${2:-900}"

  if [ -z "$pid_file" ] || [ ! -f "$pid_file" ]; then
    log Warning "PID 文件丢失或无效: $pid_file"
    return 1
  fi

  local PID=$(<"$pid_file" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    log Warning "PID 无效或已停止: $PID"
    return 1
  fi

  if [ -z "$blkio_path" ]; then
    blkio_path=$(mount | busybox awk '/blkio/ {print $3}' | head -1)
    if [ -z "$blkio_path" ] || [ ! -d "$blkio_path" ]; then
      log Warning "blkio_path 未找到"
      return 1
    fi
  fi

  local target
  if [ -d "${blkio_path}/foreground" ]; then
    target="${blkio_path}/foreground"
    log Info "使用已存在的 blkio 组: foreground"
  else
    target="${blkio_path}/box"
    mkdir -p "$target"
    echo "$fallback_weight" > "${target}/blkio.weight"
    log Info "已创建 blkio 组: box, 权重 $fallback_weight"
  fi

  echo "$PID" > "${target}/cgroup.procs" \
    && log Info "已分配 PID $PID 到 $target"

  return 0
}

cgroup_memcg() {
  local pid_file="$1"
  local raw_limit="$2"

  if [ -z "$pid_file" ] || [ ! -f "$pid_file" ]; then
    log Warning "PID 文件丢失或无效: $pid_file"
    return 1
  fi

  if [ -z "$raw_limit" ]; then
    log Warning "未指定 memcg 限制"
    return 1
  fi

  local limit
  case "$raw_limit" in
    *[Mm])
      limit=$(( ${raw_limit%[Mm]} * 1024 * 1024 ))
      ;;
    *[Gg])
      limit=$(( ${raw_limit%[Gg]} * 1024 * 1024 * 1024 ))
      ;;
    *[Kk])
      limit=$(( ${raw_limit%[Kk]} * 1024 ))
      ;;
    *[0-9])
      limit=$raw_limit
      ;;
    *)
      log Warning "无效的 memcg 限制格式: $raw_limit"
      return 1
      ;;
  esac

  local PID
  PID=$(<"$pid_file" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    log Warning "PID 无效或已停止: $PID"
    return 1
  fi

  if [ -z "$memcg_path" ]; then
    memcg_path=$(mount | grep cgroup | busybox awk '/memory/{print $3}' | head -1)
    if [ -z "$memcg_path" ] || [ ! -d "$memcg_path" ]; then
      log Warning "无法确定 memcg 路径"
      return 1
    fi
  fi

  local name="${bin_name:-app}"
  local target="${memcg_path}/${name}"
  mkdir -p "$target"

  echo "$limit" > "${target}/memory.limit_in_bytes" \
    && log Info "已为 $name 设置内存限制: ${limit} 字节"

  echo "$PID" > "${target}/cgroup.procs" \
    && log Info "已分配 PID $PID 到 ${target}"

  return 0
}

cgroup_cpuset() {
  local pid_file="${1}"
  local cores="${2}"

  if [ -z "${pid_file}" ] || [ ! -f "${pid_file}" ]; then
    log Warning "PID 文件丢失或无效: ${pid_file}"
    return 1
  fi

  local PID
  PID=$(<"${pid_file}" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    log Warning "来自 ${pid_file} 的 PID $PID 无效或未运行"
    return 1
  fi

  if [ -z "${cores}" ]; then
    local total_core
    total_core=$(nproc --all 2>/dev/null)
    if [ -z "$total_core" ] || [ "$total_core" -le 0 ]; then
      log Warning "检测 CPU 核心失败"
      return 1
    fi
    cores="0-$((total_core - 1))"
  fi

  if [ -z "${cpuset_path}" ]; then
    cpuset_path=$(mount | grep cgroup | busybox awk '/cpuset/{print $3}' | head -1)
    if [ -z "${cpuset_path}" ] || [ ! -d "${cpuset_path}" ]; then
      log Warning "cpuset_path 未找到"
      return 1
    fi
  fi

  local cpuset_target="${cpuset_path}/top-app"
  if [ ! -d "${cpuset_target}" ]; then
    cpuset_target="${cpuset_path}/apps"
    [ ! -d "${cpuset_target}" ] && log Warning "cpuset 目标未找到" && return 1
  fi

  echo "${cores}" > "${cpuset_target}/cpus"
  echo "0" > "${cpuset_target}/mems"

  echo "${PID}" > "${cpuset_target}/cgroup.procs" \
    && log Info "已分配 PID $PID 到 ${cpuset_target}，CPU 核心 [$cores]"

  return 0
}

webroot() {
  ip_port=$(if [ "${bin_name}" = "mihomo" ]; then busybox awk '/external-controller:/ {print $2}' "${mihomo_config}"; else find /data/adb/box/sing-box/ -type f -name 'config.json' -exec busybox awk -F'[:,]' '/"external_controller"/ {print $2":"$3}' {} \; | sed 's/^[ \t]*//;s/"//g'; fi;)
  secret=$(if [ "${bin_name}" = "mihomo" ]; then busybox awk '/^secret:/ {print $2}' "${mihomo_config}" | sed 's/"//g'; else find /data/adb/box/sing-box/ -type f -name 'config.json' -exec busybox awk -F'"' '/"secret"/ {print $4}' {} \; | head -n 1; fi;)
  path_webroot="/data/adb/modules/box_for_root/webroot/index.html"
  touch "$path_webroot"
  if [[ "${bin_name}" = @(mihomo|sing-box) ]]; then
    echo -e '
  <!DOCTYPE html>
  <script>
      document.location = 'http://127.0.0.1:9090/ui/'
  </script>
  </html>
  ' > $path_webroot
    sed -i "s#document\.location =.*#document.location = 'http://$ip_port/ui/'#" $path_webroot
  else
   echo -e '
  <!DOCTYPE html>
  <html lang="zh-CN">
  <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>不支持WebUI</title>
      <style>
          body {
              font-family: Arial, sans-serif;
              text-align: center;
              padding: 50px;
          }
          h1 {
              color: red;
          }
      </style>
  </head>
  <body>
      <h1>不支持WebUI</h1>
      <p>抱歉，xray/v2ray 不支持所需的WebUI功能。</p>
  </body>
  </html>' > $path_webroot
  fi
}

bond0() {
  sysctl -w net.ipv4.tcp_low_latency=0 >/dev/null 2>&1
  log Debug "tcp 低延迟: 0"

  for dev in /sys/class/net/wlan*; do ip link set dev $(basename $dev) txqueuelen 3000; done
  log Debug "wlan* 传输队列长度: 3000"

  for txqueuelen in /sys/class/net/rmnet_data*; do txqueuelen_name=$(basename $txqueuelen); ip link set dev $txqueuelen_name txqueuelen 1000; done
  log Debug "rmnet_data* 传输队列长度: 1000"

  for mtu in /sys/class/net/rmnet_data*; do mtu_name=$(basename $mtu); ip link set dev $mtu_name mtu 1500; done
  log Debug "rmnet_data* MTU: 1500"
}

bond1() {
  sysctl -w net.ipv4.tcp_low_latency=1 >/dev/null 2>&1
  log Debug "tcp 低延迟: 1"

  for dev in /sys/class/net/wlan*; do ip link set dev $(basename $dev) txqueuelen 4000; done
  log Debug "wlan* 传输队列长度: 4000"

  for txqueuelen in /sys/class/net/rmnet_data*; do txqueuelen_name=$(basename $txqueuelen); ip link set dev $txqueuelen_name txqueuelen 2000; done
  log Debug "rmnet_data* 传输队列长度: 2000"

  for mtu in /sys/class/net/rmnet_data*; do mtu_name=$(basename $mtu); ip link set dev $mtu_name mtu 9000; done
  log Debug "rmnet_data* MTU: 9000"
}

case "$1" in
  check)
    check
    ;;
  memcg|cpuset|blkio)
    case "$1" in
      memcg)
        memcg_path=""
        cgroup_memcg "${box_pid}" ${memcg_limit}
        ;;
      cpuset)
        cpuset_path=""
        cgroup_cpuset "${box_pid}" ${allow_cpu}
        ;;
      blkio)
        blkio_path=""
        cgroup_blkio "${box_pid}" "${weight}"
        ;;
    esac
    ;;
  bond0|bond1)
    $1
    ;;
  geosub)
    upsubs
    upgeox
    if [ -f "${box_pid}" ]; then
      kill -0 "$(<"${box_pid}" 2>/dev/null)" && reload
    fi
    ;;
  geox|subs)
    if [ "$1" = "geox" ]; then
      upgeox
    else
      upsubs
      [ "${bin_name}" != "mihomo" ] && exit 1
    fi
    if [ -f "${box_pid}" ]; then
      kill -0 "$(<"${box_pid}" 2>/dev/null)" && reload
    fi
    ;;
  upkernel)
    upkernel "$2"
    ;;  
  upkernels)
    shift
    upkernels "$@"
    ;;
  upgeox_all)
    upgeox_all
    ;;
  upxui)
    upxui
    ;;
  upyq|upcurl)
    $1
    ;;
  reload)
    reload
    ;;
  webroot)
    webroot
    ;;
  all)
    upyq
    upcurl
    upgeox_all
    upkernels sing-box mihomo xray v2fly hysteria
    for bin_name in "${bin_list[@]}"; do
      upsubs
      upxui
    done
    ;;
  *)
    log Error "$0 $1 未找到"
    log Info "用法: $0 {check|memcg|cpuset|blkio|geosub|geox|subs|upkernel [name]|upkernels [name...]|upgeox_all|upxui|upyq|upcurl|reload|webroot|bond0|bond1|all}"
    log Info "upkernel 支持的核心: sing-box, mihomo, mihomo_smart, xray, v2fly, hysteria"
    ;;
esac