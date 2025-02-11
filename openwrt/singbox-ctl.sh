#!/bin/sh

# depend on: curl nft ip ping netstat jq coreutils-base64
# Configuration parameters
# xray/v2ray url格式节点订阅链接
SUBSCRIBE_URL="http://YOUR_SERVER/proxy/node"
# sing-box 配置模板文件
TEMPLATE_URL="http://YOUR_SERVER/proxy/singbox_template.json"
SING_BOX_BIN="/usr/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
# 防火墙规则
RULESET_FILE="/usr/share/nftables.d/ruleset-post/99-singbox.nft"
CONFIG_FILE="${CONFIG_DIR}/config.json"
TPROXY_PORT=7895  # sing-box tproxy port
# 代理流量标记
PROXY_MARK=1
# 直接出站流量标记 (对应 sing-box 配置中的 outbound.routing_mark 或 route.default_mark)
OUTPUT_MARK=255
PROXY_ROUTE_TABLE=100
# 统计
RULE_COUNTER=""
# RULE_COUNTER="counter"

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

# Trap interrupt signals for clear_fw_route
trap 'handle_error "Script interrupted"' INT TERM

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

# Download file
# $1:url,$2:output file
download() {
	curl -s -L --retry 3 --connect-timeout 10 --max-time 30 "$1" -o "$2"
}

# URL decode
# $1:url
url_decode() {
	#printf "%b" "${1//\%/\\x}"
	hex=$(echo "$1" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;')
	printf "%b" "$hex"
}

# convert xray node to sing-box node
# $1: url of xray node
convert_to_singbox() {
	url="$1"
	tag=$(echo "$url" | cut -d'#' -f2)
	tag=$(url_decode "$tag")
	protocol=$(echo "$url" | cut -d':' -f1)
	uuid=$(echo "$url" | cut -d'@' -f1 | cut -d'/' -f3)
	server=$(echo "$url" | cut -d'@' -f2 | cut -d':' -f1)
	port=$(echo "$url" | cut -d':' -f3 | cut -d'?' -f1)
	params=$(echo "$url" | cut -d'?' -f2 | cut -d'#' -f1)
	#encryption=$(echo "$params" | grep -o 'encryption=[^&]*' | cut -d'=' -f2)
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

	echo "{"
	echo "  \"tag\": \"$tag\","
	echo "  \"type\": \"$protocol\","
	echo "  \"server\": \"$server\","
	echo "  \"server_port\": $port,"
	echo "  \"uuid\": \"$uuid\","

	echo "  \"tls\": {"
	echo "    \"enabled\": true,"
	echo "    \"server_name\": \"$sni\","

	if [ "$security" = "reality" ]; then
		echo "    \"utls\": {"
		echo "      \"enabled\": true,"
		echo "      \"fingerprint\": \"$fp\""
		echo "    },"
		echo "    \"reality\": {"
		echo "      \"enabled\": true,"
		echo "      \"public_key\": \"$pbk\","
		echo "      \"short_id\": \"$sid\""
		echo "    },"
	fi
	echo "    \"insecure\": false"
	echo "  },"

	case "$type" in
		"ws")
			echo "  \"transport\": {"
			echo "    \"type\": \"ws\","
			echo "    \"headers\": {"
			echo "      \"Host\": \"$host\""
			echo "    },"
			echo "    \"path\": \"$path\""
			echo "  }"
			;;
		"grpc")
			echo "  \"transport\": {"
			echo "    \"type\": \"grpc\","
			echo "    \"service_name\": \"learning\""
			echo "  }"
			;;
	esac

	if [ "$security" = "reality" ]; then
		echo "  \"flow\": \"$flow\""
	fi

	echo "}"
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
				# Use grep to filter the list based on key_words
				filtered_outbounds=$(echo "$all_outbounds" | jq -r '.[]' | grep -E "$key_words")
				# Convert the filtered list back to a JSON array
				outbound_filter=$(echo "$filtered_outbounds" | jq -R -s -c 'split("\n")[:-1]' | tr -d '[]')
				sed -i "s/\"${item}\"/${outbound_filter}/g" "$1"
				;;
		esac
	done
}

#$1: xray node files, $2:sing-box config template file, $3:new sing-box config file
append_outbounds() {
	mv "$2" "$3"
	while IFS= read -r node; do
		outbound=$(convert_to_singbox "${node}")
		jq --argjson new_outbound "$outbound" '.outbounds += [$new_outbound]' "$3" > "$3.tmp"
		mv "$3.tmp" "$3"
	done < "$1"
	patch_outbound_filter "$3"
}

update_subscribe() {
	mkdir -p ${CONFIG_DIR}
	cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak"
	subscribe_file="/tmp/${SUBSCRIBE_URL##*/}"
	template_file="/tmp/${TEMPLATE_URL##*/}"
	cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
	log "Start downloading config template and subscribe files..."
	download "$TEMPLATE_URL" "$template_file" || handle_error "Failed to download configuration file after 3 retries"
	download "$SUBSCRIBE_URL" "$subscribe_file" || handle_error "Failed to download configuration file after 3 retries"
	base64 -d "$subscribe_file" | tr -d '\r' > "${subscribe_file}.tmp" && mv "${subscribe_file}.tmp" "$subscribe_file"
	log "Start generating config files..."
	append_outbounds "$subscribe_file" "$template_file" "$CONFIG_FILE"
	log "The generated config file path: $CONFIG_FILE"
}

# 清除规则
clear_fw_route() {
	nft list ruleset | grep -q "sing-box" && nft flush table inet sing-box > /dev/null 2>&1
	rm -f /etc/nftables.d/99-singbox.nft
	ip route del local default table $PROXY_ROUTE_TABLE > /dev/null 2>&1
	ip rule del fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE > /dev/null 2>&1
	ip -6 route del local default table $PROXY_ROUTE_TABLE > /dev/null 2>&1
	ip -6 rule del fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE > /dev/null 2>&1
}

# 设置新规则
setup_fw_route() {
	ip route add local default dev lo table $PROXY_ROUTE_TABLE
	ip rule add fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE
	ip -6 route add local default dev lo table $PROXY_ROUTE_TABLE
	ip -6 rule add fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE
	[ -d "${RULESET_FILE%/*}" ] || mkdir -p "${RULESET_FILE%/*}"
	cat > "${RULESET_FILE}" << EOF
#!/usr/sbin/nft -f
table inet sing-box {
    # IPv4 和 IPv6 保留地址
    set RESERVED_IPSET {
        type ipv4_addr
        flags interval
        auto-merge
        elements = {
            10.0.0.0/8,         # * A 类私有保留地址
            100.64.0.0/10,      # * 运营商保留地址
            127.0.0.0/8,        # * 本地回环接口地址
            169.254.0.0/16,     # * DHCP 保留地址
            172.16.0.0/12,      # * B 类私有保留地址
            192.168.0.0/16,     # * C 类私有保留地址
            224.0.0.0/4,        # * 多播地址
            240.0.0.0/4,        # - 研究测试保留，除了 255.255.255.255
            255.255.255.255/32  # * 全局广播地址
        }
    }

    set RESERVED_IPSET_V6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = {
            ::1/128,            # * 本地回环接口地址
            100::/64,           # * 保留用于本地通信的地址
            fc00::/7,           # * 唯一本地地址（ULA）
            fe80::/10,          # * 链路本地地址
            ff00::/8            # * 多播地址
        }
    }

    # 局域网透明代理
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # 绕过应答流量
        ct direction reply $RULE_COUNTER accept comment "Optimize: Reply Packets"

        # 优化已经建立的 TCP 透明代理连接；使用系统记录的Socket，将流量直接送入协议栈
        # openwrt 不支持
        # meta l4proto tcp socket transparent 1 $RULE_COUNTER meta mark set $PROXY_MARK accept comment "Optimize: Just re-route established TCP proxy connections"

        # 劫持所有 DNS；DNS 请求比较多，TProxy 成本高，不建议使用；建议直接开一个 DNS-INBOUND
        udp dport 53 $RULE_COUNTER tproxy to :$TPROXY_PORT meta mark set $PROXY_MARK accept comment "Proxy: DNS(UDP) Hijack"

        # 绕过发往保留地址的流量
        meta nfproto ipv4 ip daddr @RESERVED_IPSET $RULE_COUNTER accept comment "Bypass: IPv4 Reserved Address"
        meta nfproto ipv6 ip6 daddr @RESERVED_IPSET_V6 $RULE_COUNTER accept comment "Bypass: IPv6 Reserved Address"

        # 绕过发往本机地址的流量 (如果保留地址包含了所有本机接口，可以忽略此规则)
        # fib daddr type local $RULE_COUNTER accept comment "Bypass: Local Address"

        # 转发到代理服务
        meta l4proto { tcp, udp } $RULE_COUNTER tproxy to :$TPROXY_PORT meta mark set $PROXY_MARK accept comment "Proxy: Default"
    }

    # 本机透明代理
    chain output {
        type route hook output priority mangle; policy accept;

        # 绕过应答流量
        ct direction reply $RULE_COUNTER accept comment "Optimize: Reply Packets"

        # 绕过代理程序出站流量
        meta mark $OUTPUT_MARK $RULE_COUNTER accept comment "Bypass: Proxy Output"

        # 重路由 DNS(UDP) 出站流量; DNS 请求比较多，TProxy 成本高，不建议使用；建议直接开一个 DNS-INBOUND
        udp dport 53 $RULE_COUNTER meta mark set $PROXY_MARK accept comment "Re-route: DNS(UDP) Output"

        # 绕过发往保留地址的流量
        meta nfproto ipv4 ip daddr @RESERVED_IPSET $RULE_COUNTER accept comment "Bypass: IPv4 Reserved Address"
        meta nfproto ipv6 ip6 daddr @RESERVED_IPSET_V6 $RULE_COUNTER accept comment "Bypass: IPv6 Reserved Address"

        # 绕过发往本机地址的流量 (如果保留地址包含了所有本机接口，可以忽略此规则)
        # fib daddr type local $RULE_COUNTER accept comment "Bypass: Local Address"

        # 重路由默认出站流量; 需配合策略路由
        meta l4proto { tcp, udp } $RULE_COUNTER meta mark set $PROXY_MARK accept comment "Re-route: Default Output"
    }
}
EOF
	# 应用防火墙规则
	if ! nft -f "${RULESET_FILE}"; then
		handle_error "Failed to apply firewall rules"
	fi
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
		log "Configuration file validation failed, restoring backup"
		cp -f "${CONFIG_FILE}.bak" "$CONFIG_FILE"
		handle_error "Configuration validation failed"
	fi

	log "Starting sing-box service..."
	${SING_BOX_BIN} run -c "$CONFIG_FILE" > /dev/null 2>&1 &

	sleep 2
	if pgrep "sing-box" > /dev/null; then
		clear_fw_route
		setup_fw_route
		log "sing-box started successfully in TProxy mode"
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
	clear_fw_route
	log "Stopped sing-box and cleaned up"
}

update() {
	local_ver=$(${SING_BOX_BIN} version | head -n 1 | sed -n 's/.*version \([-0-9.a-zA-Z]\+\).*/\1/p')
	latest_ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/tags | jq -r '.[0].name' | sed 's/^v//')
	if [ "$latest_ver" != "$local_ver" ]; then
		log "New version available: $latest_ver"
		log "Start downloading..."
		latest_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-amd64.tar.gz"
		pkg_file="/tmp/${latest_url##*/}"
		download "$latest_url" "${pkg_file}" || handle_error "Failed to download latest package"
		tar -xzf "${pkg_file}" -C /tmp
		stop_service
		tmp_dir=$(echo "${pkg_file}" | sed 's/.tar.gz$//')
		mv -f "${tmp_dir}/sing-box" "${SING_BOX_BIN}"
		chmod +x /usr/bin/sing-box
		start_service
		echo "sing-box updated to version $latest_ver"
	else
		echo "sing-box v${local_ver} is already up to date."
	fi
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
			update_subscribe
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
