#!/bin/bash

# ==============================================================================
# Application: Conduit Network Manager
# Version: 1.3.1 (Config Filename Change)
# Description: Network Management + Security Advisor + Firewall Analysis
# ==============================================================================

# --- Configuration & Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

BACKUP_DIR="/var/backups/iptables"
CONFIG_FILE="net_conf.json"  # <-- ????? ??? ???? ??????

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

# --- MODULE 1: DASHBOARD ---

show_dashboard() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       NETWORK DASHBOARD (v1.3.1)                   ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    echo -e "${CYAN}[Public IPv4]${NC}"
    curl -4 -s --connect-timeout 2 ifconfig.me || echo "N/A"
    
    echo -e "\n${CYAN}[Active Interfaces]${NC}"
    ip -4 -o a | awk '{print "  " $2 ": " $4}'
    
    echo -e "\n${CYAN}[Load Balancer Status]${NC}"
    # Check IPv4
    LB_RULES_V4=$(iptables -t nat -L POSTROUTING -n | grep "statistic")
    SNAT_RULES_V4=$(iptables -t nat -L POSTROUTING -n | grep "to:")
    
    if [ -n "$LB_RULES_V4" ]; then 
        echo -e "  IPv4: ${GREEN}Active (Balanced)${NC}"
    elif [ -n "$SNAT_RULES_V4" ]; then
        echo -e "  IPv4: ${GREEN}Active (Single IP)${NC}"
    else 
        echo -e "  IPv4: ${YELLOW}Inactive${NC}"
    fi

    # Check IPv6
    LB_RULES_V6=$(ip6tables -t nat -L POSTROUTING -n | grep "statistic")
    SNAT_RULES_V6=$(ip6tables -t nat -L POSTROUTING -n | grep "to:")
    
    if [ -n "$LB_RULES_V6" ]; then 
        echo -e "  IPv6: ${GREEN}Active (Balanced)${NC}"
    elif [ -n "$SNAT_RULES_V6" ]; then
        echo -e "  IPv6: ${GREEN}Active (Single IP)${NC}"
    else 
        echo -e "  IPv6: ${YELLOW}Inactive${NC}"
    fi
    
    pause
}

# --- MODULE 2: LOAD BALANCER WIZARD ---

run_lb_wizard() {
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

    # Step 2: IPv6
    echo -e "\n${GREEN}[Phase 2] Scanning IPv6...${NC}"
    AVAILABLE_IPS_V6=($(get_valid_ipv6s))
    COUNT_V6=${#AVAILABLE_IPS_V6[@]}
    
    ENABLE_V6_LB="n"
    if [ "$COUNT_V6" -gt 0 ]; then
        echo "Detected IPv6:"; for i in "${!AVAILABLE_IPS_V6[@]}"; do echo -e "  [$((i+1))] ${GREEN}${AVAILABLE_IPS_V6[$i]}${NC}"; done
        if [ "$COUNT_V6" -eq 1 ]; then 
            echo -e "${YELLOW}Warning: Only 1 IPv6 found. Traffic will exit via this single IP.${NC}"
        fi
        echo ""; read -p "Enable NAT/LB for IPv6? (y/n): " ENABLE_V6_LB
    else
        echo -e "${YELLOW}No Global IPv6 found.${NC}"
    fi

    # Step 3: Backup & Flush
    echo -e "\n${YELLOW}[Backup] Saving rules...${NC}"
    mkdir -p "$BACKUP_DIR"
    iptables-save > "$BACKUP_DIR/v4_backup_$(date +%s).v4"
    ip6tables-save > "$BACKUP_DIR/v6_backup_$(date +%s).v6"

    echo -e "\n${GREEN}[Step 3] Mode Selection${NC}"
    echo "1) Enable Automatic Load Balancing"
    echo "2) Disable/Reset"
    read -p "Select: " MODE

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
    
    if [[ "$ENABLE_V6_LB" =~ ^[Yy]$ ]]; then
        flush_snat "ip6tables"
    fi

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
        if [ "$CTR" -eq 1 ]; then
            iptables -t nat -I POSTROUTING 1 -o eth0 -j SNAT --to-source "$ip"
        else
            PROB=$(python3 -c "print(round(1/$CTR, 4))")
            iptables -t nat -I POSTROUTING 1 -o eth0 -m statistic --mode random --probability "$PROB" -j SNAT --to-source "$ip"
        fi
        CTR=$((CTR + 1))
    done

    # Apply IPv6
    if [[ "$ENABLE_V6_LB" =~ ^[Yy]$ ]]; then
        echo -e "\n${GREEN}>> Applying IPv6 Rules...${NC}"
        REVERSED_V6=()
        for ((i=COUNT_V6-1; i>=0; i--)); do REVERSED_V6+=("${AVAILABLE_IPS_V6[$i]}"); done
        CTR=1
        for ip in "${REVERSED_V6[@]}"; do
            if [ "$COUNT_V6" -eq 1 ]; then
                 ip6tables -t nat -I POSTROUTING 1 -o eth0 -j SNAT --to-source "$ip"
                 echo "   IPv6 (Single): $ip"
            else
                if [ "$CTR" -eq 1 ]; then
                    ip6tables -t nat -I POSTROUTING 1 -o eth0 -j SNAT --to-source "$ip"
                else
                    PROB=$(python3 -c "print(round(1/$CTR, 4))")
                    ip6tables -t nat -I POSTROUTING 1 -o eth0 -m statistic --mode random --probability "$PROB" -j SNAT --to-source "$ip"
                fi
            fi
            CTR=$((CTR + 1))
        done
    fi

    sudo netfilter-persistent save >/dev/null 2>&1
    save_config_state
    echo -e "\n${GREEN}Configuration Saved.${NC}"
    
    # Verify
    echo -e "\n${CYAN}Verifying IPv4...${NC}"
    for ((i=1; i<=3; i++)); do IP=$(docker run --rm curlimages/curl -4 -s --connect-timeout 2 ifconfig.me); echo "  v4: $IP"; done
    pause
}

# --- MODULE 3: SECURITY ADVISOR ---

analyze_ports() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       FIREWALL & PORT SECURITY ADVISOR             ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "Scanning listening ports and analyzing risks...\n"

    printf "${BOLD}%-10s | %-15s | %-20s | %-40s${NC}\n" "Port" "Protocol" "Process" "Security Analysis"
    echo "-----------|-----------------|----------------------|----------------------------------------"

    ss -tulpn | grep LISTEN | awk 'NR>1 {print $1, $5, $7}' | while read -r proto local_addr process_info; do
        if [[ "$local_addr" == *"["* ]]; then
            IP=$(echo "$local_addr" | cut -d ']' -f 1 | tr -d '[')
            PORT=$(echo "$local_addr" | cut -d ']' -f 2 | tr -d ':')
        else
            IP=$(echo "$local_addr" | cut -d ':' -f 1)
            PORT=$(echo "$local_addr" | cut -d ':' -f 2)
        fi

        PROC_NAME=$(echo "$process_info" | grep -oP '(?<=").+?(?=")' | head -n 1)
        [ -z "$PROC_NAME" ] && PROC_NAME="Unknown"

        MSG=""
        case $PORT in
            22) MSG="SSH. ${YELLOW}Use Keys & Fail2Ban.${NC}" ;;
            80|443) MSG="Web Server. ${GREEN}Safe.${NC}" ;;
            53) MSG="DNS. ${GREEN}Required if DNS Server.${NC}" ;;
            6010|6011) MSG="X11 Forwarding. ${YELLOW}Disable in sshd_config if not used.${NC}" ;;
            40505|4500) MSG="Internal/Containerd. ${GREEN}Safe (Localhost).${NC}" ;;
            3306|5432|6379) 
                if [[ "$IP" == "127.0.0.1" || "$IP" == "::1" ]]; then MSG="Database (Local). ${GREEN}Safe.${NC}";
                else MSG="Database (Public). ${RED}DANGER! Firewall this!${NC}"; fi ;;
            *) MSG="Custom. Check manually." ;;
        esac

        printf "%-10s | %-15s | %-20s | %b\n" "$PORT" "$proto ($IP)" "$PROC_NAME" "$MSG"
    done
    pause
}

# --- MODULE 4: DIAGNOSTICS ---

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
                echo -e "${GREEN}All SNAT rules cleared. Please go to Option 2 (Load Balancer) to re-apply correctly.${NC}"
                pause
                ;;
            0) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# --- MODULE 5: REAL-TIME MONITOR ---

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

    IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    echo -e "${GREEN}Starting Monitor on interface: $IFACE${NC}"
    echo -e "Instructions: Press ${RED}'q'${NC} to EXIT."
    sleep 3
    iftop -n -N -i "$IFACE"
    echo -e "\n${GREEN}Monitor closed.${NC}"
    pause
}

# --- MAIN EXECUTION ---

check_startup_drift

while true; do
    clear
    echo -e "${BLUE}####################################################${NC}"
    echo -e "${BLUE}#           CONDUIT NETWORK MANAGER                #${NC}"
    echo -e "${BLUE}#           Version: 1.3.1 (Stable)                #${NC}"
    echo -e "${BLUE}####################################################${NC}"
    echo -e "System Time: $(date)"
    echo ""
    echo -e "  ${GREEN}1)${NC} Network Dashboard"
    echo -e "  ${GREEN}2)${NC} Load Balancer Configuration"
    echo -e "  ${GREEN}3)${NC} Diagnostics & Security Advisor"
    echo -e "  ${GREEN}4)${NC} Real-time Monitor (Traffic per IP)"
    echo -e "  ${RED}0)${NC} Exit"
    echo ""
    read -p "Select option: " CHOICE

    case $CHOICE in
        1) show_dashboard ;;
        2) run_lb_wizard ;;
        3) run_diagnostics ;;
        4) run_monitor ;;
        0) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option"; sleep 1 ;;
    esac
done