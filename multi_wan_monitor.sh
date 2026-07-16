#!/bin/bash
# Multi-WAN Automatic Failover for OpenWRT
# Primary: eth1, Secondary: eth2
# Uses ICMP ping for health checks
# Location:  /etc/multi_wan_monitor.sh
# Version 10 - Route replacement issue fix

PRIORITY_WAN="eth1"        # Preferred gateway
BACKUP_WAN="eth2"          # Fallback
INTERFACE_NAME_PRIMARY="wan"     # Logical name in /etc/config/network
INTERFACE_NAME_BACKUP="wan2"     # Logical name in /etc/config/network
PING_TARGETS="8.8.8.8 1.1.1.1 208.67.222.222"      # Google, Cloudflare, Cisco
RETRIES_PER_TARGET=3
CONSECUTIVE_FAILURES_REQUIRED=2
CHECK_INTERVAL=30                                # Between full cycles
COOLDOWN_AFTER_FAILOVER=120                      # Prevent flapping
INITIAL_DELAY=10                                 # Let DHCP settle at boot
LOG_FILE="/var/log/multi_wan_failover.log"
MAX_LOG_SIZE_KB=1500             # Rotate when exceeding this size

# Logging function
log_msg() {
    # Rotate log if too large before appending
    rotate_log_if_needed
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

rotate_log_if_needed() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi

    local file_size_kb
    file_size_kb=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1)

    if [ "${file_size_kb:-0}" -gt "$MAX_LOG_SIZE_KB" ]; then
        # Shift backups
        [ -f "${LOG_FILE}.2" ] && mv "${LOG_FILE}.2" "${LOG_FILE}.3"
        [ -f "${LOG_FILE}.1" ] && mv "${LOG_FILE}.1" "${LOG_FILE}.2"

        # Current becomes .1
        cp "$LOG_FILE" "${LOG_FILE}.1"
        truncate -s 0 "$LOG_FILE"

        log_msg "Log rotated (exceeded ${MAX_LOG_SIZE_KB}KB)"
    fi
}

# Check if interface has actual connectivity (not just link up)
check_connectivity() {
    local iface="$1"

    # Track duration for diagnostic logging
    local check_start
    check_start=$(date +%s)

    log_msg "Checking connectivity on $iface..."

    # Method 1: Physical & Software link check
    ensure_enabled
    if ! ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
	log_msg "✗ LINK DOWN: Interface $iface is physically not UP"
        return 1
    fi

    # Level 2: Is UCI disabled flag set?
    local uci_disabled
    uci_disabled=$(uci get network."$INTERFACE_NAME_PRIMARY".disabled 2>/dev/null)

    if [ "$uci_disabled" = "1" ]; then
        echo "✗ SOFT OFF: Interface $iface is disabled in UCI - fixing now..."
	ensure_enabled
        return 1
    fi

    # Method 2: Has IP address assigned?
    if ! ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
	log_msg "✗ NO IP: Interface $iface has no IPv4 address"
        return 1
    fi

    # Method 3: Try ping with multiple targets
    for target in $PING_TARGETS; do
        if ping -c "$RETRIES_PER_TARGET" -W 5 -I "$iface" "$target" > /dev/null 2>&1; then
            local check_end
            check_end=$(date +%s)
            local duration=$((check_end - check_start))
            log_msg "✓ PASS: $iface reachable via $target (${duration}s)"
            return 0
        fi

        log_msg "✗ FAIL: Could not reach $target via $iface"
    done

    log_msg "✗ CRITICAL: Connectivity FAILED on $iface after testing all targets"
    return 1
}

# Enable WAN interface
enable_wan() {
    local iface_name="$1"
    log_msg "Enabling WAN interface: $iface_name"

    uci set network."$iface_name".disabled='0'
    uci commit network
    ifup "$iface_name" 2>/dev/null || true
    sleep 3
}

# Get currently active WAN interface (which default route is being used)
get_active_gateway_iface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    echo "${iface:-none}"
}

# Force failover from current primary to backup
failover_to_backup() {
    log_msg "=== FAILOVER INITIATED ==="
    log_msg "Primary ($PRIORITY_WAN) unreachable, switching to backup ($BACKUP_WAN)"
    local newroute
    local newsrc_full
    local newsrc_ip

    newroute=$(ifstatus "$INTERFACE_NAME_BACKUP" | jq -r '.route[0].nexthop')
    newsrc_full=$(ifstatus "$INTERFACE_NAME_BACKUP" | jq -r '.route[0].source')
    newsrc_ip=$(echo "$newsrc_full" | cut -d'/' -f1) # Strip the /32 mask

    ensure_enabled
    if [ -n "$newroute" ] && [ -n "$newsrc_ip" ]; then
        log_msg "→ Set eth2 the primary route"
    	log_msg "ip route replace default via $newroute dev $BACKUP_WAN src $newsrc_ip"
    	ip route replace default via $newroute dev $BACKUP_WAN src $newsrc_ip
    else
	log_msg "✗ Failed to parse route data for $BACKUP_WAN"
	return 1
    fi

    # Refresh DNS and routes
    service firewall restart
    sleep 5
    log_msg "✓ Failover complete - Backup WAN now primary path"
    return 0
}

# Restore primary when it recovers
restore_primary() {
    local routebak
    routebak=$(ip route | grep default)
    log_msg "=== RESTORE VALIDATION PHASE ==="
    ensure_enabled

    # STEP 1: Test connectivity WITH primary enabled
    if check_connectivity "$PRIORITY_WAN"; then
        local newroute
	local newsrc_full
	local newsrc_ip

	log_msg "✓ Primary ($PRIORITY_WAN) connectivity VERIFIED - proceeding with restore"
	newroute=$(ifstatus "$INTERFACE_NAME_PRIMARY" | jq -r '.route[0].nexthop')
	newsrc_full=$(ifstatus "$INTERFACE_NAME_PRIMARY" | jq -r '.route[0].source')
	newsrc_ip=$(echo "$newsrc_full" | cut -d'/' -f1) # Strip the /32 mask

        # Rebuild routing table only AFTER confirming primary works
	if [ -n "$newroute" ] && [ -n "$newsrc_ip" ]; then
            log_msg "→ Set eth1 the primary route"
  	    log_msg "ip route replace default via $newroute dev $PRIORITY_WAN src $newsrc_ip"
  	    ip route replace default via $newroute dev $PRIORITY_WAN src $newsrc_ip
	else
	    echo "✗ Failed to parse route data for $PRIORITY_WAN"
	    return 1
	fi
        service firewall restart
        sleep 5

        log_msg "✓ Restore complete - Back to Primary WAN"
        return 0
    else
        # Primary failed test - rollback immediately
        log_msg "✗ Primary FAILED connectivity test"
        ensure_enabled
	if ip route | grep default | grep -q eth1; then
	    log_msg "→ Route changed by OpenWRT; rolling back"
	    ip route replace "$routebak"
	fi
        service firewall restart
	sleep 5
        return 1
    fi
}

ensure_enabled() {
    local disabled_status
    disabled_status=$(uci get network."$INTERFACE_NAME_BACKUP".disabled 2>/dev/null)

    if [ "$disabled_status" != "0" ] || [ -z "$disabled_status" ]; then
        log_msg "→ Backup soft disabled (${disabled_status}), enabling now..."
        enable_wan "$INTERFACE_NAME_BACKUP"
    else
        log_msg "✓ Backup interface already enabled"
    fi

    disabled_status=$(uci get network."$INTERFACE_NAME_PRIMARY".disabled 2>/dev/null)

    if [ "$disabled_status" != "0" ] || [ -z "$disabled_status" ]; then
        log_msg "→ Primary soft disabled (${disabled_status}), enabling now..."
        enable_wan "$INTERFACE_NAME_PRIMARY"
    else
        log_msg "✓ Primary interface already enabled"
    fi

}

check_current_state() {
    local current_iface
    current_iface=$(get_active_gateway_iface)

    if [ "$current_iface" = "$PRIORITY_WAN" ]; then
        printf 'PRIMARY_ACTIVE\n'
    elif [ "$current_iface" = "$BACKUP_WAN" ]; then
        printf 'BACKUP_ACTIVE\n'
    else
        printf 'UNKNOWN\n'
    fi
}

monitor_loop() {
    local consecutive_fails=0
    local last_action_time=0
    local cycle_count=0

    log_msg "=== Multi-WAN Monitor Starting ==="
    log_msg "Priority: ${PRIORITY_WAN}, Backup: ${BACKUP_WAN}"

    sleep "$INITIAL_DELAY"

    while true; do
        ((cycle_count++))
        local cycle_start_time=$(date +%s)

        # Calculate cooldown remaining from last action
        local elapsed_since_action=$(( $(date +%s) - last_action_time ))
        local cooldown_remaining=$((COOLDOWN_AFTER_FAILOVER - elapsed_since_action))

        # Respect failover cooldown period
        if [ "$cooldown_remaining" -gt 0 ]; then
            log_msg "--- Cycle $cycle_count ---"
            log_msg "Cooldown active (${cooldown_remaining}s remaining)"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        local current_route_state=$(check_current_state)
        local current_iface=$(get_active_gateway_iface)
        log_msg "→ Current route state: $current_route_state via $current_iface"

	# Version 4 logic
        if check_connectivity "$PRIORITY_WAN"; then
            consecutive_fails=0

            # Primary healthy - if on backup, restore priority
            if [ "$current_route_state" = "BACKUP_ACTIVE" ] && [ "$elapsed_since_action" -gt 60 ]; then
                log_msg "Primary recovered while backup active - initiating RESTORE"
                restore_primary
                last_action_time=$(date +%s)
            fi
        else
            ((consecutive_fails++))
            log_msg "Primary failure count: $consecutive_fails/$CONSECUTIVE_FAILURES_REQUIRED"

            if [ "$consecutive_fails" -ge "$CONSECUTIVE_FAILURES_REQUIRED" ]; then
                log_msg "CONFIRMED: Primary ($PRIORITY_WAN) DOWN after $consecutive_fails failures"

                # KEY FIX: Don't failover if ALREADY on backup!
                if [ "$current_route_state" = "BACKUP_ACTIVE" ]; then
                    log_msg "→ SKIPPED FAILOVER: Already running on Backup WAN - staying put"
                    consecutive_fails=0  # Reset to avoid repeated warnings
                else
                    # Actually need to failover
                    ensure_enabled

                    if check_connectivity "$BACKUP_WAN"; then
                        failover_to_backup
                        last_action_time=$(date +%s)
                        consecutive_fails=0
                    else
                        log_msg "CRITICAL: Both WANs unreachable! Internet completely lost"
                    fi
                fi
            fi
        fi

        local cycle_end_time=$(date +%s)
        local cycle_duration=$((cycle_end_time - cycle_start_time))
        local sleep_remaining=$((CHECK_INTERVAL - cycle_duration))

        if [ "$sleep_remaining" -gt 0 ]; then
            sleep "$sleep_remaining"
        else
            log_msg "⚠ WARNING: Cycle exceeded interval (${cycle_duration}s)"
            sleep 5
        fi
    done
}

# Signal handlers for graceful shutdown
cleanup() {
    log_msg "=== Monitor Shutting Down ==="
    # Also log to syslog for persistent records
    logger -t "mwan_diy" "Monitor shutting down gracefully"
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP EXIT

# Validate prerequisites
validate_setup() {
    # Check UCI config exists
    if ! uci get network."$INTERFACE_NAME_PRIMARY" &>/dev/null; then
        log_msg "✗ ERROR: Primary interface '$INTERFACE_NAME_PRIMARY' not found in UCI"
        log_msg "→ Check /etc/config/network for correct interface names"
        exit 1
    fi

    log_msg "Configuration validated, starting monitor (Ctrl+C to stop)..."
}

# Main execution
if [ "$EUID" -ne 0 ]; then
    echo "✗ Error: This script requires root privileges" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

validate_setup
monitor_loop
