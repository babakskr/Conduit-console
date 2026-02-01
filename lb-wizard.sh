#!/bin/bash
# ==============================================================================
# Script: Conduit Network Manager (Ultimate Edition)
# Repository: https://github.com/babakskr/Conduit-console.git
# Author: Babak Sorkhpour
# Version: 1.6.0
#
# Changelog v1.6.0:
# - Fix: Adjusted Security Advisor table columns to prevent text wrapping.
# - Feature: Added '0) Cancel/Back' options to all interactive menus.
# - UI: Improved dashboard clarity.
# ==============================================================================

set -u -o pipefail
IFS=$'\n\t'

# --- Configuration & Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

BACKUP_DIR="/var/backups/iptables"
CONFIG_FILE="net_conf.json"
DOCKER_DAEMON_FILE="/etc/docker/daemon.json"
NET_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# Check for Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[Error] This script must be run as root.${NC}"
   exit 1
fi

# --- Helper Functions ---

pause() {
    echo -e "\n${YELLOW}Press [Enter] to go back...${NC}"
    read -r
}

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

get_valid_ipv4s() {
    ip -o -4 addr show scope global | while read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        ip_cidr=$(echo "$line" | awk '{print $4}')
        ip_addr=${ip_cidr%/*}
        if [[ "$iface" == docker* ]] || [[ "$iface" == br-* ]] || [[ "$iface" == lo ]]; then continue; fi
        if [[ "$ip_addr" =~ ^10\. ]] || [[ "$ip_addr" =~ ^192\.168\. ]] || [[ "$ip_addr" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then continue; fi
        echo "$ip_addr"
    done | sort -u
}

get_valid_ipv6s() {
    ip -o -6 addr show scope global | while read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        ip_cidr=$(echo "$line" | awk '{print $4}')
        ip_addr=${ip_cidr%/*}
        if [[ "$iface" == docker* ]] || [[ "$iface" == br-* ]] || [[ "$iface" == lo ]]; then continue; fi
        echo "$ip_addr"
    done | sort -u
}

# --- CONFIG MANAGER MODULE ---

save_config_state() {
    V4_LIST=$(get_valid_ipv4s | tr '\n' ',' | sed 's/,$//')
    V6_LIST=$(get_valid_ipv6s | tr '\n' ',' | sed 's/,$//')
    DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat <<EOF > "$CONFIG_FILE"
{
  "network": {
    "last_updated": "$DATE",
    "ipv4_addresses": "$V4_LIST",
    "ipv6_addresses": "$V6_LIST"
  },
  "status": "active"
}
EOF
}

check_startup_drift() {
    if [ ! -f "$CONFIG_FILE" ]; then return; fi
    SAVED_V4=$(grep "ipv4_addresses" "$CONFIG_FILE" | cut -d '"' -f 4)
    SAVED_V6=$(grep "ipv6_addresses" "$CONFIG_FILE" | cut -d '"' -f 4)
    LAST_RUN=$(grep "last_updated" "$CONFIG_FILE" | cut -d '"' -f 4)
    CURRENT_V4=$(get_valid_ipv4s | tr '\n' ',' | sed 's/,$//')
    CURRENT_V6=$(get_valid_ipv6s | tr '\n' ',' | sed 's/,$//')

    DRIFT=0
    if [ "$SAVED_V4" != "$CURRENT_V4" ] || [ "$SAVED_V6" != "$CURRENT_V6" ]; then DRIFT=1; fi

    if [ "$DRIFT" -eq 1 ]; then
        echo -e "${RED}====================================================${NC}"
        echo -e "${RED} [WARNING] NETWORK CONFIGURATION DRIFT DETECTED!    ${NC}"
        echo -e "${RED}====================================================${NC}"
        echo -e "Last Saved: $LAST_RUN"
        echo -e "Press [Enter] to acknowledge..."
        read -r
    fi
}

# --- NEW: IPv6 DISCOVERY & CONFIGURATION MODULE ---

discover_ipv6_prefix() {
    local found_ip
    found_ip=$(ip -6 -o addr show dev "$NET_IFACE" scope global | grep "/64" | head -n1 | awk '{print $4}')
    
    if [[ -n "$found_ip" ]]; then
        echo "$found_ip" | cut -d: -f1-4
    else
        echo ""
    fi
}

configure_docker_ipv6_subnet() {
    local prefix="$1"
    local docker_subnet="${prefix}:1::/80" 
    
    info "Configuring Docker with Subnet: $docker_subnet"
    if [[ ! -d "/etc/docker" ]]; then mkdir -p /etc/docker; fi
    
    cat > "$DOCKER_DAEMON_FILE" <<EOF
{
  "ipv6": true,
  "fixed-cidr-v6": "${docker_subnet}",
  "ip6tables": true,
  "experimental": true
}
EOF
    systemctl restart docker
    ok "Docker configured and restarted."
}

migrate_docker_containers() {
    info "Scanning for legacy Docker containers to migrate (Host -> Bridge)..."
    mapfile -t containers < <(docker ps -a --format '{{.Names}}' | grep -i "conduit")

    if [ ${#containers[@]} -eq 0 ]; then
        info "No containers found to migrate."
        return
    fi

    for cname in "${containers[@]}"; do
        local net_mode
        net_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$cname")
        
        if [[ "$net_mode" == "host" ]]; then
            info "Migrating $cname..."
            local cmd_str
            cmd_str="$(docker inspect --format '{{join .Config.Cmd " "}}' "$cname")"
            local m_val="-"; [[ "$cmd_str" =~ (-m|--max-clients)[[:space:]]+([^[:space:]]+) ]] && m_val="${BASH_REMATCH[2]}"
            local b_val="-1"; [[ "$cmd_str" =~ (-b|--bandwidth)[[:space:]]+([^[:space:]]+) ]] && b_val="${BASH_REMATCH[2]}"
            local num; num=$(echo "$cname" | grep -oP '\d+')
            local vol="conduit${num}-data"
            local mount="/home/conduit/data"
            
            docker rm -f "$cname" >/dev/null
            docker run -d --name "$cname" \
                -v "$vol:$mount" \
                --restart unless-stopped \
                "ghcr.io/ssmirr/conduit/conduit:latest" \
                start -m "$m_val" -b "$b_val" -d "$mount" --stats-file "$mount/stats.json" >/dev/null
            ok "Migrated $cname"
        fi
    done
}

configure_native_ipv6_aliases() {
    local prefix="$1"
    info "Configuring Native Services (IP Aliasing)..."
    mapfile -t services < <(systemctl list-units --type=service --all "conduit*.service" --no-legend | awk '{print $1}')
    
    local count=0
    for svc in "${services[@]}"; do
        local svc_name="${svc%.service}"
        local num="${svc_name//[^0-9]/}"
        local target_ip="${prefix}::2:${num}" 
        
        if ! ip -6 addr show dev "$NET_IFACE" | grep -q "$target_ip"; then
            ip -6 addr add "${target_ip}/64" dev "$NET_IFACE"
            count=$((count + 1))
        fi
    done
    if [ $count -gt 0 ]; then ok "Added $count IPv6 aliases for Native services."; else info "Native IPs already set."; fi
}

run_ipv6_wizard() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       IPv6 AUTO-CONFIGURATION WIZARD               ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    local detected=$(discover_ipv6_prefix)
    local chosen=""
    
    if [[ -n "$detected" ]]; then
        echo -e "Detected Prefix: ${CYAN}${detected}::/64${NC}"
        read -p "Use this prefix? [Y/n] (0 to Cancel): " c
        if [[ "$c" == "0" ]]; then return; fi
        [[ "${c:-Y}" =~ ^[Yy]$ ]] && chosen="$detected"
    fi
    
    if [[ -z "$chosen" ]]; then
        read -p "Enter IPv6 Prefix (e.g., 2a01:4f8:x:y) or 0 to Cancel: " chosen
        if [[ "$chosen" == "0" ]]; then return; fi
        [[ -z "$chosen" ]] && { err "No prefix provided."; return; }
    fi
    
    echo -e "\nTarget:\n  Docker: ${chosen}:1::/80\n  Native: ${chosen}::2:NUM"
    read -p "Apply? [y/N] (0 to Cancel): " confirm
    if [[ "$confirm" == "0" ]]; then return; fi
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    configure_docker_ipv6_subnet "$chosen"
    migrate_docker_containers
    configure_native_ipv6_aliases "$chosen"
    
    pause
}


# --- MODULE 1: DASHBOARD ---

show_dashboard() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       NETWORK DASHBOARD (v1.6.0)                   ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    echo -e "${CYAN}[Public IPv4]${NC}"
    curl -4 -s --connect-timeout 2 ifconfig.me || echo "N/A"
    
    echo -e "\n${CYAN}[Active Interfaces]${NC}"
    ip -4 -o a | awk '{print "  " $2 ": " $4}'
    
    echo -e "\n${CYAN}[IPv6 Status]${NC}"
    local ipv6_count
    ipv6_count=$(ip -6 addr show scope global | grep -c "inet6")
    echo "  Total Global IPv6 Addresses: $ipv6_count"

    echo -e "\n${CYAN}[Load Balancer Status]${NC}"
    LB_RULES_V4=$(iptables -t nat -L POSTROUTING -n | grep "statistic")
    SNAT_RULES_V4=$(iptables -t nat -L POSTROUTING -n | grep "to:")
    
    if [ -n "$LB_RULES_V4" ]; then 
        echo -e "  IPv4: ${GREEN}Active (Balanced)${NC}"
    elif [ -n "$SNAT_RULES_V4" ]; then
        echo -e "  IPv4: ${GREEN}Active (Single IP)${NC}"
    else 
        echo -e "  IPv4: ${YELLOW}Inactive${NC}"
    fi

    LB_RULES_V6=$(ip6tables -t nat -L POSTROUTING -n | grep "statistic")
    if [ -n "$LB_RULES_V6" ]; then echo -e "  IPv6 (Native Outbound): ${GREEN}Active (Balanced)${NC}"; else echo -e "  IPv6 (Native Outbound): ${YELLOW}Default Routing${NC}"; fi
    
    pause
}

# --- MODULE 2: LOAD BALANCER CONFIG (Manual/Legacy) ---

run_lb_config() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       LOAD BALANCER CONFIGURATION                  ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    # Step 1: IPv4
    echo -e "\n${GREEN}[Phase 1] Scanning IPv4...${NC}"
    AVAILABLE_IPS_V4=($(get_valid_ipv4s))
    COUNT_V4=${#AVAILABLE_IPS_V4[@]}

    if [ "$COUNT_V4" -eq 0 ]; then echo -e "${RED}No Public IPv4 found.${NC}"; else
        echo "Detected IPv4:"; for i in "${!AVAILABLE_IPS_V4[@]}"; do echo -e "  [$((i+1))] ${GREEN}${AVAILABLE_IPS_V4[$i]}${NC}"; done
    fi
    
    # Step 2: IPv6 (Native Outbound Only)
    echo -e "\n${GREEN}[Phase 2] Scanning IPv6 Aliases (for Native)...${NC}"
    AVAILABLE_IPS_V6=($(get_valid_ipv6s))
    COUNT_V6=${#AVAILABLE_IPS_V6[@]}
    
    echo "Detected IPv6 Count: $COUNT_V6"
    read -p "Enable Outbound Load Balancing (SNAT) for Native Services? (y/n): " ENABLE_V6_LB

    # Step 3: Backup & Flush
    echo -e "\n${YELLOW}[Backup] Saving rules...${NC}"
    mkdir -p "$BACKUP_DIR"
    iptables-save > "$BACKUP_DIR/v4_backup_$(date +%s).v4"
    ip6tables-save > "$BACKUP_DIR/v6_backup_$(date +%s).v6"

    echo -e "\n${GREEN}[Step 3] Mode Selection${NC}"
    echo "1) Apply Rules"
    echo "2) Disable/Reset"
    echo "0) Cancel"
    read -p "Select: " MODE
    
    if [ "$MODE" -eq 0 ]; then return; fi

    # Flush Logic
    flush_snat() {
        PROTO=$1
        echo "   -> Flushing $PROTO..."
        $PROTO -t nat -L POSTROUTING --line-numbers | grep "SNAT" | sort -rn | awk '{print $1}' | while read -r line; do
            is_masq=$($PROTO -t nat -L POSTROUTING "$line" | grep "MASQUERADE")
            [ -z "$is_masq" ] && $PROTO -t nat -D POSTROUTING "$line"
        done
    }

    echo -e "\n${YELLOW}>> Flushing old rules...${NC}"
    flush_snat "iptables"
    if [[ "$ENABLE_V6_LB" =~ ^[Yy]$ ]]; then flush_snat "ip6tables"; fi

    if [ "$MODE" -eq 2 ]; then
        sudo netfilter-persistent save >/dev/null 2>&1
        save_config_state
        echo -e "${GREEN}Disabled.${NC}"; pause; return
    fi

    # Apply IPv4
    echo -e "\n${GREEN}>> Applying IPv4 Rules...${NC}"
    REVERSED_V4=()
    for ((i=COUNT_V4-1; i>=0; i--)); do REVERSED_V4+=("${AVAILABLE_IPS_V4[$i]}"); done
    CTR=1
    for ip in "${REVERSED_V4[@]}"; do
        if [ "$CTR" -eq 1 ]; then iptables -t nat -I POSTROUTING 1 -o "$NET_IFACE" -j SNAT --to-source "$ip"; else
            PROB=$(python3 -c "print(round(1/$CTR, 4))")
            iptables -t nat -I POSTROUTING 1 -o "$NET_IFACE" -m statistic --mode random --probability "$PROB" -j SNAT --to-source "$ip"
        fi
        CTR=$((CTR + 1))
    done

    # Apply IPv6 (Only if requested for Native)
    if [[ "$ENABLE_V6_LB" =~ ^[Yy]$ ]]; then
        echo -e "\n${GREEN}>> Applying IPv6 Rules...${NC}"
        REVERSED_V6=()
        for ((i=COUNT_V6-1; i>=0; i--)); do REVERSED_V6+=("${AVAILABLE_IPS_V6[$i]}"); done
        CTR=1
        for ip in "${REVERSED_V6[@]}"; do
             if [ "$CTR" -eq 1 ]; then ip6tables -t nat -I POSTROUTING 1 -o "$NET_IFACE" -j SNAT --to-source "$ip"; else
                PROB=$(python3 -c "print(round(1/$CTR, 4))")
                ip6tables -t nat -I POSTROUTING 1 -o "$NET_IFACE" -m statistic --mode random --probability "$PROB" -j SNAT --to-source "$ip"
            fi
            CTR=$((CTR + 1))
        done
    fi

    sudo netfilter-persistent save >/dev/null 2>&1
    save_config_state
    echo -e "\n${GREEN}Configuration Saved.${NC}"
    pause
}

# --- MODULE 3: SECURITY ADVISOR (Formatted Fixed) ---
analyze_ports() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       FIREWALL & PORT SECURITY ADVISOR             ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "Scanning listening ports and analyzing risks...\n"

    # Expanded columns to handle long ss output
    printf "${BOLD}%-10s | %-30s | %-20s | %-30s${NC}\n" "Port" "Protocol" "Process" "Security Analysis"
    echo "-----------|--------------------------------|----------------------|------------------------------"

    ss -tulpn | grep LISTEN | awk 'NR>1 {print $1, $5, $7}' | while read -r proto local_addr process_info; do
        if [[ "$local_addr" == *"["* ]]; then
            IP=$(echo "$local_addr" | cut -d ']' -f 1 | tr -d '[')
            PORT=$(echo "$local_addr" | cut -d ']' -f 2 | tr -d ':')
        else
            IP=$(echo "$local_addr" | cut -d ':' -f 1)
            PORT=$(echo "$local_addr" | cut -d ':' -f 2)
        fi

        # Extract only the process name to keep table clean (remove pid=...)
        PROC_NAME=$(echo "$process_info" | grep -oP '(?<=").+?(?=")' | head -n 1)
        [ -z "$PROC_NAME" ] && PROC_NAME="Unknown"

        # Format proto string to prevent wrapping
        PROTO_STR="$proto"
        if [ ${#PROTO_STR} -gt 28 ]; then PROTO_STR="${PROTO_STR:0:25}..."; fi

        MSG=""
        case $PORT in
            22) MSG="SSH. ${YELLOW}Use Keys/Fail2Ban.${NC}" ;;
            80|443) MSG="Web Server. ${GREEN}Safe.${NC}" ;;
            53) MSG="DNS. ${GREEN}Required if Server.${NC}" ;;
            6010|6011) MSG="X11 Fwd. ${YELLOW}Disable if unused.${NC}" ;;
            40505|4500) MSG="Internal. ${GREEN}Safe.${NC}" ;;
            3306|5432|6379) 
                if [[ "$IP" == "127.0.0.1" || "$IP" == "::1" ]]; then MSG="DB (Local). ${GREEN}Safe.${NC}";
                else MSG="DB (Public). ${RED}DANGER!${NC}"; fi ;;
            *) MSG="Custom. Check manually." ;;
        esac

        printf "%-10s | %-30s | %-20s | %b\n" "$PORT" "$PROTO_STR" "$PROC_NAME" "$MSG"
    done
    pause
}

# --- MODULE 4: DIAGNOSTICS (Unchanged) ---
run_diagnostics() {
    while true; do
        clear
        echo -e "${BLUE}====================================================${NC}"
        echo -e "${BLUE}           DIAGNOSTICS SUITE                        ${NC}"
        echo -e "${BLUE}====================================================${NC}"
        echo "1. Connectivity Check (IPv4/IPv6)"
        echo "2. DNS Resolution Check"
        echo "3. Firewall Advisor (Analyze Open Ports)"
        echo "4. Docker Network Inspect"
        echo "5. Live NAT Monitor"
        echo "6. Fix Duplicate Rules (Auto-Doctor)"
        echo -e "${RED}0. Return to Main Menu${NC}"
        echo ""
        read -p "Select test: " TEST_ID
        
        case $TEST_ID in
            1) echo ""; ping -c 3 8.8.8.8; echo "---"; ping6 -c 3 google.com; pause ;;
            2) echo ""; host google.com; pause ;;
            3) analyze_ports ;;
            4) echo ""; docker network inspect bridge | grep Subnet; pause ;;
            5)
                echo -e "${YELLOW}>> Resetting counters...${NC}"
                iptables -t nat -Z POSTROUTING
                ip6tables -t nat -Z POSTROUTING
                while true; do
                    clear
                    echo -e "${BLUE}=== LIVE NAT MONITOR (Press ENTER to Go Back) ===${NC}"
                    echo -e "Time: $(date +%H:%M:%S)"
                    echo -e "\n${CYAN}IPv4 Rules:${NC}"
                    iptables -t nat -L POSTROUTING -n -v --line-numbers
                    echo -e "\n${CYAN}IPv6 Rules:${NC}"
                    ip6tables -t nat -L POSTROUTING -n -v --line-numbers
                    read -t 2 -N 1 input
                    if [ $? -eq 0 ]; then break; fi
                done
                ;;
            6)
                echo -e "${YELLOW}>> Running Auto-Doctor to remove duplicates...${NC}"
                iptables -t nat -L POSTROUTING --line-numbers | grep "SNAT" | sort -rn | awk '{print $1}' | while read -r line; do
                    iptables -t nat -D POSTROUTING "$line"
                done
                ip6tables -t nat -L POSTROUTING --line-numbers | grep "SNAT" | sort -rn | awk '{print $1}' | while read -r line; do
                    ip6tables -t nat -D POSTROUTING "$line"
                done
                echo -e "${GREEN}All SNAT rules cleared. Please go to Option 3 (Load Balancer) to re-apply correctly.${NC}"
                pause
                ;;
            0) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# --- MODULE 5: REAL-TIME MONITOR (Unchanged) ---
run_monitor() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       REAL-TIME TRAFFIC MONITOR (PER IP)           ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    TOOL="iftop"
    if ! command -v $TOOL &> /dev/null; then
        echo -e "${RED}Warning: '$TOOL' is NOT installed.${NC}"
        read -p "Install $TOOL now? (y/n): " INSTALL_CONFIRM
        if [[ "$INSTALL_CONFIRM" =~ ^[Yy]$ ]]; then apt-get update && apt-get install -y $TOOL; else return; fi
    fi

    echo -e "${GREEN}Starting Monitor on interface: $NET_IFACE${NC}"
    echo -e "Instructions: Press ${RED}'q'${NC} to EXIT."
    sleep 3
    iftop -n -N -i "$NET_IFACE"
    echo -e "\n${GREEN}Monitor closed.${NC}"
    pause
}

# --- MAIN EXECUTION ---

check_startup_drift

while true; do
    clear
    echo -e "${BLUE}####################################################${NC}"
    echo -e "${BLUE}#           CONDUIT NETWORK MANAGER                #${NC}"
    echo -e "${BLUE}#           Version: 1.6.0 (Polished)              #${NC}"
    echo -e "${BLUE}####################################################${NC}"
    echo -e "System Time: $(date)"
    echo ""
    echo -e "  ${GREEN}1)${NC} Network Dashboard"
    echo -e "  ${GREEN}2)${NC} IPv6 Auto-Config Wizard (Docker+Native)"
    echo -e "  ${GREEN}3)${NC} Load Balancer Rules (Manual SNAT)"
    echo -e "  ${GREEN}4)${NC} Diagnostics & Security Advisor"
    echo -e "  ${GREEN}5)${NC} Real-time Monitor (Traffic per IP)"
    echo -e "  ${RED}0)${NC} Exit"
    echo ""
    read -p "Select option: " CHOICE

    case $CHOICE in
        1) show_dashboard ;;
        2) run_ipv6_wizard ;;
        3) run_lb_config ;;
        4) run_diagnostics ;;
        5) run_monitor ;;
        0) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option"; sleep 1 ;;
    esac
done