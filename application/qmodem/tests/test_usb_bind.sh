#!/bin/sh
# modem_usb_bind.sh must route interfaces from modem_port_rule.json without
# touching modules that have no usb_bind rule.
#
# The script talks to sysfs, so the test builds a throwaway sysfs tree and
# asserts the exact writes: option gets the AT interfaces, qmi_wwan gets the
# RmNet interface only, and the dynamic qmi_wwan ID is removed again.
#
# Note: a real sysfs attribute consumes one command per write, so a plain file
# in the fake tree only keeps the last value. Multi-interface knobs are
# therefore checked one interface at a time.
#
# Ordering (RmNet claimed before the option ID is registered) is not asserted
# here: it only shows up on a real device, where an unclaimed 1.4 would be
# swept up by option's new_id probe. See docs/developer/vendor-tw.zh-cn.md.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/files/usr/share/qmodem/modem_usb_bind.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: modem_usb_bind test needs jq"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM

SYS="$TMP/sys"
RULE="$TMP/modem_port_rule.json"
SLOT="$SYS/bus/usb/devices/2-1"
OTHER="$SYS/bus/usb/devices/3-1"
OPTION_BIND="$SYS/bus/usb/drivers/option/bind"
OPTION_NEW_ID="$SYS/bus/usb-serial/drivers/option1/new_id"
QMI="$SYS/bus/usb/drivers/qmi_wwan"

mkdir -p "$SLOT" "$OTHER" \
    "$SYS/bus/usb-serial/drivers/option1" \
    "$SYS/bus/usb/drivers/option" \
    "$QMI"

printf '2077\n' > "$SLOT/idVendor"
printf '2004\n' > "$SLOT/idProduct"
printf '2dee\n' > "$OTHER/idVendor"
printf '4d23\n' > "$OTHER/idProduct"

# TW500M-CN layout: 1.0 DIAG, 1.1/1.2 AT, 1.3 NMEA, 1.4 RmNet.
for i in 0 1 2 3 4; do
    mkdir -p "$SLOT/2-1:1.$i"
done

write_full_rule()
{
    cat > "$RULE" <<'EOF'
{
    "modem_port_rule": {
        "usb": {
            "2077:2004": {
                "name": "tw500m-cn",
                "option_driver": 0,
                "include": ["1.1", "1.2"],
                "usb_bind": {
                    "serial": ["1.0", "1.1", "1.2", "1.3"],
                    "network": { "1.4": "qmi_wwan" }
                }
            }
        }
    }
}
EOF
}

reset_sysfs()
{
    : > "$OPTION_NEW_ID"
    : > "$OPTION_BIND"
    : > "$SYS/bus/usb/drivers/option/unbind"
    : > "$QMI/bind"
    : > "$QMI/new_id"
    : > "$QMI/remove_id"
}

run_bind()
{
    QMODEM_SYSFS_ROOT="$SYS" QMODEM_PORT_RULE="$RULE" sh "$SCRIPT" "$@"
}

fail=0
expect_file()
{
    path=$1
    expected=$2
    actual=$(cat "$path" 2>/dev/null || true)
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $path" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        fail=1
    fi
}

# 1) Cold enumeration: nothing is bound yet. Every interface is routed, and the
#    dynamic qmi_wwan ID is dropped again so a later enumeration cannot hand
#    the AT interfaces to qmi_wwan.
write_full_rule
reset_sysfs
run_bind 2-1
expect_file "$OPTION_NEW_ID" "2077 2004"
expect_file "$OPTION_BIND" "2-1:1.3"
expect_file "$QMI/new_id" "2077 2004"
expect_file "$QMI/bind" "2-1:1.4"
expect_file "$QMI/remove_id" "2077 2004"

# 2) Each serial interface is bound on its own: no interface is skipped and the
#    RmNet interface is never part of the serial list.
for iface in 1.0 1.1 1.2 1.3; do
    printf '{"modem_port_rule":{"usb":{"2077:2004":{"usb_bind":{"serial":["%s"]}}}}}\n' \
        "$iface" > "$RULE"
    reset_sysfs
    run_bind 2-1
    expect_file "$OPTION_BIND" "2-1:$iface"
    expect_file "$QMI/bind" ""
done

# 3) An ID without a usb_bind rule must be left alone.
write_full_rule
reset_sysfs
run_bind 3-1
expect_file "$OPTION_NEW_ID" ""
expect_file "$OPTION_BIND" ""
expect_file "$QMI/bind" ""

# 4) option already grabbed every interface, including RmNet: RmNet has to be
#    released first and the (already registered) option ID must not be written
#    again.
mkdir -p "$SYS/fake/option" "$SYS/fake/qmi_wwan"
symlink_ok=1
for i in 0 1 2 3 4; do
    ln -sfn "$SYS/fake/option" "$SLOT/2-1:1.$i/driver" 2>/dev/null || symlink_ok=0
done
if [ "$symlink_ok" -eq 1 ]; then
    reset_sysfs
    run_bind 2-1
    expect_file "$SYS/bus/usb/drivers/option/unbind" "2-1:1.4"
    expect_file "$OPTION_NEW_ID" ""
    expect_file "$QMI/bind" "2-1:1.4"
else
    echo "SKIP: symlinks unavailable, cannot simulate an option-owned RmNet interface"
fi
for i in 0 1 2 3 4; do
    rm -f "$SLOT/2-1:1.$i/driver"
done

# 5) Scanning every slot picks up the rule as well.
reset_sysfs
run_bind all
expect_file "$QMI/bind" "2-1:1.4"

[ "$fail" -eq 0 ] || exit 1
echo "PASS: usb bind routing (option for AT ports, qmi_wwan for RmNet, dynamic id cleanup)"
