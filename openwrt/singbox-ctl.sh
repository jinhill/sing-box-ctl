#!/bin/sh
# depend on: curl nft ip ping netstat jq coreutils-base64 kmod-tun kmod-nft-tproxy
# xray/v2ray url 格式节点订阅链接
SUBSCRIBE_URL="http://192.168.6.2/proxy/node"
# sing-box 配置模板文件
TEMPLATE_URL="https://raw.githubusercontent.com/jinhill/sing-box-ctl/refs/heads/main/openwrt/singbox_template.json"
SING_BOX_BIN="/usr/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
# 防火墙规则文件（关键修复：不在 ruleset-post 目录，避免 fw4 上下文冲突）
RULESET_FILE="${CONFIG_DIR}/singbox.nft"
HOTPLUG_FILE="/etc/hotplug.d/firewall/99-singbox"
CONFIG_FILE="${CONFIG_DIR}/config.json"
TPROXY_PORT=7895  # sing-box tproxy port
# 代理流量标记
PROXY_MARK=1
# 直接出站流量标记 (sing-box 配置中的 route.default_mark 或 outbound.routing_mark)
OUTPUT_MARK=255
PROXY_ROUTE_TABLE=100
# 统计（已移除，因为在 OpenWrt 25.x 中不必要）
RULE_COUNTER=""

# $1:message
log() {
    printf "[%s]: %b\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" >&2
}

# Error handling function
# $1:error message, $2:exit code
handle_error() {
    log "Error: $1"
    exit "${2:-1}"
}

# update or add any variable in this script
# $1: var name, $2: value
update_variable() {
    key="$1"
    value=$(printf '%s' "$2" | sed 's/[&/\]/\\&/g')
    if grep -q "^${key}=" "$0"; then
        sed -i "s/^${key}=.*/${key}=\"${value}\"/" "$0"
    else
        sed -i "1 a ${key}=\"${value}\"" "$0"
    fi
    eval "$1=$2"
}

# Check if commands exist
# $1:command array list
check_commands() {
    for cmd in $1; do
        command -v "$cmd" > /dev/null 2>&1 || handle_error "$cmd is not installed. Please install it before running this script."
    done
}

# Check network connection
check_network() {
    log "Checking network connection..."
    ping -c 1 223.5.5.5 > /dev/null 2>&1 || handle_error "Network connection failed. Please check your network settings."
}

# Check if port is in use
# $1: port number
check_port() {
    netstat -tuln | grep -q ":$1 " && handle_error "Port $1 is already in use."
}

# Download file — use -f so curl fails on HTTP error responses (4xx/5xx)
# $1:url, $2:output file
download() {
    curl -sf -L --retry 3 --connect-timeout 10 --max-time 30 "$1" -o "$2"
}

# URL decode
# $1:url
url_decode() {
    hex=$(echo "$1" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;')
    printf "%b" "$hex"
}

# convert xray node URL to a sing-box outbound JSON object.
# Returns 1 (and emits nothing) for invalid/unsupported input.
# $1: node URL (vless/vmess/trojan/ss scheme)
convert_to_singbox() {
    url="$1"

    case "$url" in
        vless://*|vmess://*|trojan://*|ss://*) ;;
        *) return 1 ;;
    esac

    tag=$(echo "$url" | cut -d'#' -f2)
    tag=$(url_decode "$tag")
    protocol=$(echo "$url" | cut -d':' -f1)
    uuid=$(echo "$url" | cut -d'@' -f1 | cut -d'/' -f3)
    server=$(echo "$url" | cut -d'@' -f2 | cut -d':' -f1)
    port=$(echo "$url" | cut -d':' -f3 | cut -d'?' -f1)
    params=$(echo "$url" | cut -d'?' -f2 | cut -d'#' -f1)
    security=$(echo "$params" | grep -o 'security=[^&]*' | cut -d'=' -f2)
    sni=$(echo "$params" | grep -o 'sni=[^&]*' | cut -d'=' -f2)
    type=$(echo "$params" | grep -o 'type=[^&]*' | cut -d'=' -f2)
    host=$(echo "$params" | grep -o 'host=[^&]*' | cut -d'=' -f2)
    sid=$(echo "$params" | grep -o 'sid=[^&]*' | cut -d'=' -f2)
    pbk=$(echo "$params" | grep -o 'pbk=[^&]*' | cut -d'=' -f2)
    path=$(echo "$params" | grep -o 'path=[^&]*' | cut -d'=' -f2)
    path=$(url_decode "$path")
    flow=$(echo "$params" | grep -o 'flow=[^&]*' | cut -d'=' -f2)
    fp=$(echo "$params" | grep -o 'fp=[^&]*' | cut -d'=' -f2)

    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac

    outbound=$(jq -n \
        --arg     tag            "$tag"      \
        --arg     protocol       "$protocol" \
        --arg     server         "$server"   \
        --argjson port           "$port"     \
        --arg     uuid           "$uuid"     \
        --arg     sni            "$sni"      \
        --arg     security       "$security" \
        --arg     fp             "$fp"       \
        --arg     pbk            "$pbk"      \
        --arg     sid            "$sid"      \
        --arg     transport_type "$type"     \
        --arg     host           "$host"     \
        --arg     path           "$path"     \
        --arg     flow           "$flow"     \
        '{
            tag:         $tag,
            type:        $protocol,
            server:      $server,
            server_port: $port,
            uuid:        $uuid,
            tls: {
                enabled:     true,
                server_name: $sni,
                insecure:    false
            }
        }
        | if $security == "reality" then
            .tls.utls    = {"enabled": true, "fingerprint": $fp}
            | .tls.reality = {"enabled": true, "public_key": $pbk, "short_id": $sid}
            | .flow        = $flow
          else . end
        | if $transport_type == "ws" then
            .transport = {"type": "ws", "headers": {"Host": $host}, "path": $path}
          elif $transport_type == "grpc" then
            .transport = {"type": "grpc", "service_name": "learning"}
          else . end')

    jq_exit=$?
    if [ $jq_exit -ne 0 ] || [ -z "$outbound" ]; then
        return 1
    fi

    printf '%s' "$outbound"
}

# $1:sing-box config file
get_all_outbounds() {
    jq '.outbounds[] | select(.type | IN("direct", "block", "dns", "selector", "urltest") | not) | .tag' "$1" | sort | jq -cs '.'
}

# replace var of {all} & {include:substr1|substr2|substr3}
# $1:sing-box config file
patch_outbound_filter() {
    [ -f "$1" ] || return
    all_outbounds=$(get_all_outbounds "$1")
    [ -n "$all_outbounds" ] || return
    outbound_filter_exps=$(jq -r '
    .outbounds[]
    | select(.type | . == "selector" or . == "urltest")
    | select(any(.outbounds[]; . | contains("{all}") or contains("{include:")))
    | .outbounds[]
  ' "$1" | sort | uniq)
    echo "$outbound_filter_exps" | while IFS= read -r item; do
        case "$item" in
            '{all}')
                all_outbounds_str=$(echo "$all_outbounds" | tr -d '[]')
                sed -i "s/\"{all}\"/${all_outbounds_str}/g" "$1"
                ;;
            '{include:'*)
                include_exp=$(echo "${item}" | sed 's/^.//;s/.$//')
                key_words="${include_exp##*:}"
                filtered_outbounds=$(echo "$all_outbounds" | jq -r '.[]' | grep -E "$key_words")
                outbound_filter=$(echo "$filtered_outbounds" | jq -R -s -c 'split("\n")[:-1]' | tr -d '[]')
                sed -i "s/\"${item}\"/${outbound_filter}/g" "$1"
                ;;
        esac
    done
}

# $1: subscribe node list file, $2: sing-box config template file, $3: output config file
append_outbounds() {
    subscribe_file="$1"
    template_file="$2"
    config_file="$3"

    mv "$template_file" "$config_file"

    skipped=0
    added=0
    line_no=0

    while IFS= read -r node; do
        line_no=$((line_no + 1))
        [ -z "$node" ] && continue

        outbound=$(convert_to_singbox "${node}")
        conv_exit=$?

        if [ $conv_exit -ne 0 ] || [ -z "$outbound" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        if jq --argjson new_outbound "$outbound" '.outbounds += [$new_outbound]' "$config_file" > "$config_file.tmp"; then
            mv "$config_file.tmp" "$config_file"
            added=$((added + 1))
        else
            log "Warning: line $line_no jq merge failed, skipping node"
            rm -f "$config_file.tmp"
            skipped=$((skipped + 1))
        fi
    done < "$subscribe_file"

    log "Outbounds processed: $added added, $skipped skipped"
    patch_outbound_filter "$config_file"
}

# $1:1-need to change url, else-do not change
update_subscribe() {
    echo "Current subscribe URL: [${SUBSCRIBE_URL}]"
    if [ -z "${SUBSCRIBE_URL}" ] || [ "$1" = "1" ]; then
        printf "Enter your subscribe URL (supports xray/v2ray format): "
        read sub_url
        [ -n "${sub_url}" ] && update_variable "SUBSCRIBE_URL" "${sub_url}"
    fi
    mkdir -p "${CONFIG_DIR}"
    [ -f "$CONFIG_FILE" ] && cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    subscribe_file="/tmp/${SUBSCRIBE_URL##*/}"
    template_file="/tmp/${TEMPLATE_URL##*/}"
    log "Downloading config template and subscribe files..."
    download "$TEMPLATE_URL" "$template_file" || handle_error "Failed to download config template"
    download "$SUBSCRIBE_URL" "$subscribe_file" || handle_error "Failed to download subscribe file"

    log "Decoding subscribe file..."
    openssl base64 -d -in "$subscribe_file" | tr -d '\r' > "${subscribe_file}.tmp" \
        && mv "${subscribe_file}.tmp" "$subscribe_file" \
        || handle_error "Failed to base64-decode subscribe file"

    log "Generating config files..."
    append_outbounds "$subscribe_file" "$template_file" "$CONFIG_FILE"
    log "Config file generated at: $CONFIG_FILE"
}

# 清除规则及热插拔脚本
clear_proxy_rule() {
    rm -f "/usr/share/nftables.d/ruleset-post/99-singbox.nft" 2>/dev/null || true
    nft delete table inet sing-box 2>/dev/null || true
    # 清除路由规则（先删 rule 再删 route，避免孤立路由）
    ip rule del fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE priority 100 2>/dev/null || true
    ip route del local default dev lo table $PROXY_ROUTE_TABLE 2>/dev/null || true
    ip -6 rule del fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE priority 100 2>/dev/null || true
    ip -6 route del local default dev lo table $PROXY_ROUTE_TABLE 2>/dev/null || true
    rm -f "${RULESET_FILE}" "${HOTPLUG_FILE}"
    log "Proxy rules cleared"
}

# 设置透明代理规则（适配 OpenWrt 25.x / fw4 / nftables v1.1+）
#
# 流量路径说明：
#   LAN 客户端 DNS  → 路由器 dnsmasq（私有IP直通）→ dnsmasq 查上游
#                      → output chain 标记1 → lo → tproxy:7895 → sing-box hijack-dns
#   LAN 客户端 TCP/UDP → prerouting tproxy:7895 → sing-box → 代理出站
#   sing-box 自身流量  → output mark=255 → 直接出站，不循环
setup_proxy_rule() {
    # 1. 加载必要内核模块
    modprobe nft_tproxy 2>/dev/null || true
    modprobe xt_TPROXY  2>/dev/null || true

    # 2. 设置 IP 路由规则：fwmark=PROXY_MARK 的包通过 lo 送达 tproxy socket
    #    使用 priority 100，避免与系统默认规则（32766 main）冲突
    ip route add local default dev lo table $PROXY_ROUTE_TABLE 2>/dev/null || true
    ip rule add fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE priority 100 2>/dev/null || true
    ip -6 route add local default dev lo table $PROXY_ROUTE_TABLE 2>/dev/null || true
    ip -6 rule add fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE priority 100 2>/dev/null || true

    # 3. 生成 nftables 规则文件
    #    注意：此处使用不带引号的 EOF，以便展开 shell 变量
    mkdir -p "${RULESET_FILE%/*}"
    cat > "${RULESET_FILE}" << EOF
# sing-box 透明代理规则
# 生成时间: $(date)
# TPROXY_PORT=${TPROXY_PORT}  PROXY_MARK=${PROXY_MARK}  OUTPUT_MARK=${OUTPUT_MARK}
table inet sing-box {

    # ── 私有/保留地址集合 ────────────────────────────────────────────────
    set BYPASS_IPV4 {
        type ipv4_addr
        flags interval
        elements = {
            0.0.0.0/8,
            10.0.0.0/8,
            100.64.0.0/10,
            127.0.0.0/8,
            169.254.0.0/16,
            172.16.0.0/12,
            192.168.0.0/16,
            224.0.0.0/4,
            240.0.0.0/4
        }
    }

    set BYPASS_IPV6 {
        type ipv6_addr
        flags interval
        elements = {
            ::1/128,
            fc00::/7,
            fe80::/10,
            ff00::/8
        }
    }

    # ── prerouting：处理 LAN 客户端转发流量 ─────────────────────────────
    #
    # 规则顺序（顺序至关重要）：
    #   1. 跳过回程包（避免对已建立连接的响应包二次 tproxy）
    #   2. 跳过私有/保留 IP → 直接送达本机服务（dnsmasq 等）
    #      ★ 关键修复：必须在 DNS/QUIC 规则之前，否则发往路由器
    #        自身（192.168.x.x:53）的 DNS 会被 tproxy 劫持，
    #        dnsmasq 收不到请求，导致 DNS 解析失败
    #   3. 丢弃 QUIC（强制降级为 TCP，tproxy 不处理 QUIC）
    #      ★ 关键修复：移至 bypass 之后，避免丢弃私有 IP 的 QUIC
    #   4. 其余 TCP/UDP tproxy 到 sing-box
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # 1. 回程/已建立连接的响应包直接放行（性能优化）
        ct direction reply accept comment "Skip: reply/response packets"

        # 2. 私有地址直通（路由器本机服务、局域网内部流量）
        ip  daddr @BYPASS_IPV4 accept comment "Skip: private/reserved IPv4"
        ip6 daddr @BYPASS_IPV6 accept comment "Skip: private/reserved IPv6"

        # 3. 丢弃公网 QUIC/HTTP3（只丢公网，私有 IP 已在第2步放行）
        meta l4proto udp udp dport { 80, 443 } drop comment "Drop: QUIC/HTTP3"

        # 4. 剩余 TCP/UDP → tproxy 到 sing-box
        meta l4proto { tcp, udp } tproxy to :${TPROXY_PORT} meta mark set ${PROXY_MARK} accept comment "Tproxy: to sing-box"
    }

    # ── output：处理路由器自身发出的流量（dnsmasq 上游查询等）──────────
    #
    # 规则顺序：
    #   1. ★ 优先放行 sing-box 自身流量（OUTPUT_MARK=${OUTPUT_MARK}）
    #      必须第一条，防止 sing-box 发出的包被重新标记造成路由环路
    #   2. 跳过回程包
    #   3. 跳过私有/保留 IP
    #   4. 丢弃公网 QUIC
    #   5. 其余 TCP/UDP 标记为 PROXY_MARK → 路由到 lo → tproxy socket
    #      覆盖了 dnsmasq 的上游 DNS 查询，使其经过 sing-box hijack-dns
    chain output {
        type route hook output priority mangle; policy accept;

        # 1. sing-box 自身流量（route.default_mark = ${OUTPUT_MARK}）直接放行
        meta mark ${OUTPUT_MARK} accept comment "Skip: sing-box output (default_mark)"

        # 2. 回程包直接放行
        ct direction reply accept comment "Skip: reply packets"

        # 3. 私有地址直通
        ip  daddr @BYPASS_IPV4 accept comment "Skip: private/reserved IPv4"
        ip6 daddr @BYPASS_IPV6 accept comment "Skip: private/reserved IPv6"

        # 4. 丢弃公网 QUIC
        meta l4proto udp udp dport { 80, 443 } drop comment "Drop: QUIC/HTTP3"

        # 5. 其余 TCP/UDP 标记 PROXY_MARK，由 ip rule fwmark 路由至 lo
        #    lo 上的包再次经过 prerouting → tproxy → sing-box 接收
        #    dnsmasq 的上游 DNS 查询也经此路径被 sing-box hijack-dns 处理
        meta l4proto { tcp, udp } meta mark set ${PROXY_MARK} accept comment "Reroute: via tproxy"
    }
}
EOF

    # 4. 加载 nftables 规则（先删旧表）
    nft delete table inet sing-box 2>/dev/null || true
    if ! nft -f "${RULESET_FILE}"; then
        log "ERROR: Failed to load nftables rules from ${RULESET_FILE}"
        return 1
    fi
    log "nftables rules loaded successfully"

    # 5. 生成热插拔脚本，确保 fw4 reload/reboot 后自动恢复规则
    #    OpenWrt 25.x fw4 使用 ACTION=add 触发 hotplug.d/firewall
    mkdir -p "${HOTPLUG_FILE%/*}"
    cat > "${HOTPLUG_FILE}" << EOF
#!/bin/sh
# sing-box 透明代理热插拔脚本（fw4 reload 后自动恢复）
# ACTION=add 由 fw4 在应用防火墙规则后触发
[ "\$ACTION" = "add" ] || exit 0
pgrep -x sing-box > /dev/null 2>&1 || exit 0

# 恢复路由规则
ip route add local default dev lo table ${PROXY_ROUTE_TABLE} 2>/dev/null || true
ip rule add fwmark ${PROXY_MARK} table ${PROXY_ROUTE_TABLE} priority 100 2>/dev/null || true
ip -6 route add local default dev lo table ${PROXY_ROUTE_TABLE} 2>/dev/null || true
ip -6 rule add fwmark ${PROXY_MARK} table ${PROXY_ROUTE_TABLE} priority 100 2>/dev/null || true

# 恢复 nftables 规则
nft delete table inet sing-box 2>/dev/null || true
nft -f "${RULESET_FILE}" 2>/dev/null && logger -t sing-box "Transparent proxy rules restored after fw4 reload" || logger -t sing-box "WARNING: Failed to restore sing-box nft rules"
EOF
    chmod +x "${HOTPLUG_FILE}"
    log "Hotplug script installed at ${HOTPLUG_FILE}"
}

# Start the service
start_service() {
    check_commands "curl nft ip ping netstat jq base64"
    check_network
    check_port "$TPROXY_PORT"

    if [ ! -f "$CONFIG_FILE" ]; then
        update_subscribe
    fi

    if ! ${SING_BOX_BIN} check -c "$CONFIG_FILE"; then
        log "Configuration validation failed, restoring backup..."
        cp -f "${CONFIG_FILE}.bak" "$CONFIG_FILE" 2>/dev/null
        handle_error "Configuration validation failed"
    fi

    log "Starting sing-box service..."
    ${SING_BOX_BIN} run -c "$CONFIG_FILE" > /dev/null 2>&1 &

    sleep 2
    if pgrep "sing-box" > /dev/null; then
        clear_proxy_rule
        if setup_proxy_rule; then
            log "sing-box started successfully in TProxy mode"
        else
            killall sing-box 2>/dev/null
            handle_error "Failed to apply nft rules. sing-box service stopped."
        fi
    else
        handle_error "Failed to start sing-box, check the logs"
    fi
}

# Stop the service
stop_service() {
    if killall sing-box 2> /dev/null; then
        log "Stopped existing sing-box service"
    else
        log "No running sing-box service found"
    fi
    clear_proxy_rule
    log "Cleaned up firewall rules"
}

# Detect the active package manager
get_pkg_manager() {
    if command -v apk > /dev/null 2>&1; then
        echo "apk"
    elif command -v opkg > /dev/null 2>&1; then
        echo "opkg"
    else
        echo "unknown"
    fi
}

update() {
    local_ver="0"
    if [ -f "${SING_BOX_BIN}" ]; then
        local_ver=$(${SING_BOX_BIN} version | head -n 1 | sed -n 's/.*version \([-0-9.a-zA-Z]\+\).*/\1/p')
    fi
    log "Current version: ${local_ver:-none}"

    latest_ver=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/tags" | jq -r '.[0].name' | sed 's/^v//')
    [ -n "$latest_ver" ] || handle_error "Failed to fetch latest version from GitHub"
    log "Latest version: $latest_ver"

    if [ "$latest_ver" = "$local_ver" ]; then
        echo "sing-box v${local_ver} is already up to date."
        return 0
    fi

    log "New version available: $latest_ver — starting upgrade..."
    stop_service

    pkg_mgr=$(get_pkg_manager)
    log "Package manager detected: $pkg_mgr"

    case "$pkg_mgr" in
        apk)
            latest_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box_${latest_ver}_openwrt_x86_64.apk"
            pkg_file="/tmp/${latest_url##*/}"
            log "Downloading $latest_url ..."
            download "$latest_url" "$pkg_file" || handle_error "Failed to download apk package"
            apk add --allow-untrusted "$pkg_file" || handle_error "Failed to install package with apk"
            rm -f "$pkg_file"
            ;;
        opkg)
            latest_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box_${latest_ver}_openwrt_x86_64.ipk"
            pkg_file="/tmp/${latest_url##*/}"
            log "Downloading $latest_url ..."
            download "$latest_url" "$pkg_file" || handle_error "Failed to download ipk package"
            opkg install "$pkg_file" || handle_error "Failed to install package with opkg"
            rm -f "$pkg_file"
            ;;
        *)
            handle_error "No supported package manager found (expected apk or opkg)"
            ;;
    esac

    start_service
    log "sing-box updated successfully to v$latest_ver"
}

# Main function
main() {
    case "$1" in
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        ver | version)
            ${SING_BOX_BIN} version
            ;;
        sub | subscribe)
            update_subscribe "$2"
            ;;
        update)
            update
            ;;
        *)
            echo "Usage: $0 {start|stop|ver|subscribe|update}"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
