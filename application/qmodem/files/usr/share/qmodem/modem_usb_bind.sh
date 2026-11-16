#!/bin/sh
# Resolve USB interface ownership for modules whose IDs are not yet present in
# the in-kernel driver tables.
#
# Some 5G modules expose a RmNet/QMI interface next to their AT interfaces but
# ship a VID:PID that neither option.ko nor qmi_wwan.ko knows. Adding the ID to
# option.ko alone would hand every interface - including the RmNet one - to
# option and leave no /dev/cdc-wdm*, so the binding has to be interface
# explicit:
#
#   1. register the ID with option and let it create the ttyUSB ports
#   2. unbind the RmNet interface from option
#   3. register the ID with qmi_wwan, bind only the RmNet interface, then drop
#      the dynamic ID again so a future enumeration cannot steal AT ports
#
# Everything is driven by modem_port_rule.json:
#
#   "usb_bind": {
#       "serial":  ["1.0", "1.1", "1.2", "1.3"],
#       "network": { "1.4": "qmi_wwan" }
#   }
#
# Usage: modem_usb_bind.sh <usb-slot>|all
# Env:   QMODEM_SYSFS_ROOT (default /sys), QMODEM_PORT_RULE (default
#        /usr/share/qmodem/modem_port_rule.json) - used by the tests.
set -u

SYS="${QMODEM_SYSFS_ROOT:-/sys}"
RULE_FILE="${QMODEM_PORT_RULE:-/usr/share/qmodem/modem_port_rule.json}"

log()
{
    command -v logger >/dev/null 2>&1 || return 0
    logger -t modem_usb_bind "$*" >/dev/null 2>&1
}

# sysfs writes must never abort the caller; a missing knob is a kernel without
# that driver, which is reported by the caller instead.
write_sysfs()
{
    [ -e "$1" ] || return 1
    printf '%s\n' "$2" > "$1" 2>/dev/null
}

iface_driver()
{
    local link="$SYS/bus/usb/devices/$1:$2/driver" target
    [ -L "$link" ] || return 0
    target=$(readlink -f "$link" 2>/dev/null) || return 0
    [ -n "$target" ] || return 0
    basename "$target"
}

# Print "<vid:pid>\t<serial-csv>\t<network-kv-csv>" for every rule that asks
# for runtime binding.
rule_table()
{
    [ -f "$RULE_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '
        .modem_port_rule.usb // {}
        | to_entries[]
        | select(.value.usb_bind != null)
        | .key as $id
        | ($id + "\t"
           + ((.value.usb_bind.serial // []) | join(",")) + "\t"
           + ((.value.usb_bind.network // {})
              | to_entries | map(.key + "=" + .value) | join(",")))
    ' "$RULE_FILE" 2>/dev/null
}

ensure_driver_loaded()
{
    local driver="$1" module="${2:-$1}"
    [ -d "$SYS/bus/usb/drivers/$driver" ] && return 0
    command -v modprobe >/dev/null 2>&1 && modprobe "$module" >/dev/null 2>&1
    [ -d "$SYS/bus/usb/drivers/$driver" ]
}

bind_serial()
{
    local slot="$1" vid="$2" pid="$3" interfaces="$4"
    local iface need_id=0

    [ -n "$interfaces" ] || return 0
    ensure_driver_loaded option || {
        log "slot=$slot option driver unavailable"
        return 1
    }

    # The ID is registered only when a port is missing: writing it again while
    # it is already registered returns EEXIST and does not re-probe.
    for iface in $(printf '%s' "$interfaces" | tr ',' ' '); do
        [ "$(iface_driver "$slot" "$iface")" = "option" ] || need_id=1
    done

    if [ "$need_id" -eq 1 ]; then
        write_sysfs "$SYS/bus/usb-serial/drivers/option1/new_id" "$vid $pid"
        for iface in $(printf '%s' "$interfaces" | tr ',' ' '); do
            [ "$(iface_driver "$slot" "$iface")" = "option" ] && continue
            # Explicit bind covers the case where the dynamic ID probe did not
            # pick this interface up.
            write_sysfs "$SYS/bus/usb/drivers/option/bind" "$slot:$iface"
            log "slot=$slot interface=$iface bound to option"
        done
    fi
}

bind_network()
{
    local slot="$1" vid="$2" pid="$3" mapping="$4"
    local entry iface driver current

    [ -n "$mapping" ] || return 0

    for entry in $(printf '%s' "$mapping" | tr ',' ' '); do
        iface="${entry%%=*}"
        driver="${entry#*=}"
        [ -n "$iface" ] && [ -n "$driver" ] || continue

        ensure_driver_loaded "$driver" || {
            log "slot=$slot driver=$driver unavailable; enable the matching kmod"
            continue
        }

        current=$(iface_driver "$slot" "$iface")
        [ "$current" = "$driver" ] && continue

        if [ -n "$current" ]; then
            write_sysfs "$SYS/bus/usb/drivers/$current/unbind" "$slot:$iface"
            log "slot=$slot interface=$iface unbound from $current"
        fi

        # The dynamic ID is only needed to satisfy the driver match check for
        # the explicit bind, so it is removed again right after.
        write_sysfs "$SYS/bus/usb/drivers/$driver/new_id" "$vid $pid"
        write_sysfs "$SYS/bus/usb/drivers/$driver/bind" "$slot:$iface"
        write_sysfs "$SYS/bus/usb/drivers/$driver/remove_id" "$vid $pid"

        # Kernel probe results are asynchronous to the sysfs write, so the
        # layout is logged instead of asserted; a wrong layout surfaces as a
        # missing ttyUSB/wwan device in the scanner.
        log "slot=$slot interface=$iface bound to $driver (now: $(iface_driver "$slot" "$iface"))"
    done
}

bind_slot()
{
    local slot="$1" dir vid pid id rule serial network

    dir="$SYS/bus/usb/devices/$slot"
    [ -f "$dir/idVendor" ] && [ -f "$dir/idProduct" ] || return 0
    vid=$(cat "$dir/idVendor" 2>/dev/null)
    pid=$(cat "$dir/idProduct" 2>/dev/null)
    [ -n "$vid" ] && [ -n "$pid" ] || return 0

    id="$vid:$pid"
    rule=$(printf '%s\n' "$RULE_TABLE" | awk -F'\t' -v id="$id" '$1 == id { print; exit }')
    [ -n "$rule" ] || return 0

    serial=$(printf '%s\n' "$rule" | cut -f2)
    network=$(printf '%s\n' "$rule" | cut -f3)

    # Order matters. Registering the option ID makes the usb-serial core probe
    # *every* interface of the device that no driver owns yet, including the
    # RmNet one. Claiming 1.4 first by qmi_wwan keeps it out of that sweep, so
    # cdc-wdm0/wwan0 appear immediately instead of after an unbind dance.
    #
    # This cannot be fixed by removing the option ID afterwards: kernel 5.4
    # exposes /sys/bus/usb-serial/drivers/option1/new_id without remove_id, so
    # "2077 2004" stays in the table for the rest of the boot and every later
    # enumeration re-runs the sweep.
    bind_network "$slot" "$vid" "$pid" "$network"
    bind_serial "$slot" "$vid" "$pid" "$serial"
}

case "${1:-}" in
    ''|all)
        RULE_TABLE=$(rule_table)
        for dir in "$SYS"/bus/usb/devices/*; do
            [ -f "$dir/idVendor" ] || continue
            bind_slot "$(basename "$dir")"
        done
        ;;
    *)
        RULE_TABLE=$(rule_table)
        bind_slot "$1"
        ;;
esac
