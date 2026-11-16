#!/bin/sh
# T&W (Xi'an Gongjin) TW500M-CN / TW510M / TW500G adapter.
#
# Hardware facts this adapter relies on (see docs/developer/vendor-tw.zh-cn.md):
#   - Qualcomm SDX55, USB 2077:2004, five interfaces:
#       1.0 DIAG  1.1 Modem AT  1.2 Application AT  1.3 NMEA  1.4 RmNet
#   - Only 1.1 and 1.2 answer AT; DIAG and NMEA never reply (and block).
#   - USB composition is fixed in firmware: AT+TPVID answers OK but the PID
#     stays 2004, so QMI is the only data path (no ECM/RNDIS/MBIM).
#   - The AT set is vendor private for the things that matter (AT+TENG /
#     AT+TCFG / AT+TNWINFO), but the 3GPP basics work once the SIM is
#     registered: AT+CSQ, AT+COPS?, AT+CREG?, AT+ICCID and AT+CIMI all answer.
#     Signal and cell data still come from AT+TENG, which carries everything.
#   - AT+TENG splits a servingcell report after the RAT token, so the payload
#     arrives on two "+TENG:" lines and has to be merged before parsing.
#
# Parsing rules: the +TENG field order below mirrors the Quectel +QENG
# servingcell layout the vendor copied. Unknown or short responses are
# reported verbatim instead of being mapped onto guessed fields.
_Vendor="tw"
_Author="QModem contributors"
_Maintainer="QModem contributors"
source "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
source "${QMODEM_HOME:-/usr/share/qmodem}/cmds/tw.sh"

debug_subject="tw_ctrl"

# Print the nth payload line of a response, skipping the command echo, blank
# lines and the final OK/ERROR status word.
#$1: response  $2: 1-based index
tw_payload_line()
{
    printf '%s\n' "$1" | awk -v want="$2" '
        {
            line=$0
            sub(/\r$/, "", line)
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line == "" || line == "OK" || line == "ERROR" || line ~ /^\+/)
                next
            if (line ~ /^AT/)
                next
            count++
            if (count == want) {
                print line
                exit
            }
        }
    '
}

# Print the value that follows a response prefix such as "+CGMM:" or "+TEMP:".
# Accepts both "+PREFIX: value" and a value placed on the next line.
#$1: response  $2: prefix
tw_prefixed_value()
{
    printf '%s\n' "$1" | awk -v prefix="$2" '
        function trim(value) {
            sub(/^[ \t]+/, "", value)
            sub(/[ \t]+$/, "", value)
            return value
        }
        {
            line=$0
            sub(/\r$/, "", line)
            if (!matched) {
                if (index(line, prefix) == 1) {
                    value=trim(substr(line, length(prefix) + 1))
                    if (value != "" && value !~ /^\+/) {
                        print value
                        exit
                    }
                    matched=1
                }
                next
            }
            value=trim(line)
            if (value == "")
                next
            if (value == "OK" || value == "ERROR" || value ~ /^\+/)
                exit
            print value
            exit
        }
    ' | sed 's/^"//; s/"$//'
}

# Print one comma separated field of a +TENG line.
#$1: line  $2: 1-based field index
tw_csv_field()
{
    printf '%s' "$1" | cut -d',' -f"$2" | tr -d '"\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Print one numeric field of a +TENG record, empty for "-" or garbage.
#$1: record  $2: 1-based field index
tw_csv_num()
{
    local value
    value=$(tw_csv_field "$1" "$2")
    case "$value" in
        ''|'-'|*[!0-9.-]*) return 0 ;;
    esac
    echo "$value"
}

# Print a SINR value, dropping the -20 this firmware uses for "not measured".
#$1: value
tw_sinr_or_empty()
{
    case "$1" in
        ''|-) return 0 ;;
        -2[0-9]|-[3-9][0-9]) return 0 ;;
    esac
    echo "$1"
}

# Merge the "+TENG:" lines that belong to one record into a single CSV string.
#
# The firmware splits long reports after the RAT token, so a serving cell
# arrives as two lines:
#   +TENG: "servingcell","CONNECT","LTE"
#   +TENG: "LTE","FDD",460,00,EA497AD,392,3590,8,3,3,7973,-78,-7,-53,19,-
# The RAT token is repeated at the head of the second line, so it is dropped
# while joining; the result is the single record the parser expects.
#$1: record tag without quotes, e.g. servingcell  stdin: response
tw_teng_join()
{
    local tag="$1" line payload out="" started=0 head tail

    while IFS= read -r line; do
        case "$line" in
            '+TENG:'*) payload=${line#+TENG:} ;;
            *) continue ;;
        esac
        payload=$(printf '%s' "$payload" | tr -d '\r' | sed 's/^[[:space:]]*//')
        case "$payload" in
            "\"$tag\""*)
                out="$payload"
                started=1
                continue
                ;;
            '"neighbourcell'*)
                # A different record type; never append it to this one.
                started=0
                continue
                ;;
        esac
        if [ "$started" = "1" ]; then
            head=$(printf '%s' "$payload" | cut -d',' -f1)
            tail=${out##*,}
            [ "$head" = "$tail" ] && payload=${payload#*,}
            out="$out,$payload"
        fi
    done

    printf '%s' "$out"
}

# Map a PLMN to its operator name; returns nothing for unknown networks.
#$1: mcc  $2: mnc
tw_plmn_carrier()
{
    local mcc="$1" mnc="$2"
    # Some firmware revisions drop the leading zero of the MNC.
    case "$mnc" in
        [0-9]) mnc="0$mnc" ;;
    esac
    case "${mcc}${mnc}" in
        46000|46002|46004|46007|46008) echo "China Mobile" ;;
        46001|46006|46009) echo "China Unicom" ;;
        46003|46005|46011|46012) echo "China Telecom" ;;
        46015) echo "China Broadnet" ;;
        *) return 0 ;;
    esac
}

# Print the numeric modem temperature in Celsius, empty when unavailable.
#$1: AT+TEMP response
tw_temperature()
{
    local value
    value=$(tw_prefixed_value "$1" "+TEMP:")
    case "$value" in
        ''|*[!0-9.-]*) return 0 ;;
    esac
    echo "$value"
}

# Print the supply voltage in millivolts, empty when unavailable.
#$1: AT+CBC response, standard +CBC: <bcs>,<bcl>,<voltage mV>
tw_voltage()
{
    local line mv
    line=$(printf '%s\n' "$1" | grep '^+CBC:' | head -n 1 | tr -d '\r')
    [ -n "$line" ] || return 0
    mv=$(printf '%s' "${line#*:}" | awk -F',' '{ print $3 }' | tr -d ' ')
    case "$mv" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # A Li-ion pack on this platform stays well inside 3.0-5.0 V. Anything
    # outside means the field order differs, so show nothing instead of a
    # plausible but wrong number.
    [ "$mv" -ge 3000 ] && [ "$mv" -le 5000 ] || return 0
    echo "$mv"
}

# Print the band number from a +TNWINFO line.
#   +TNWINFO: "FDD LTE","46000","LTE BAND 8",3590  ->  8
tw_tnwinfo_band()
{
    local line band
    line=$(printf '%s\n' "$1" | grep '^+TNWINFO:' | head -n 1 | tr -d '\r')
    [ -n "$line" ] || return 0
    band=$(printf '%s' "$line" | sed -n 's/.*BAND[[:space:]]*\([0-9][0-9]*\)".*/\1/p')
    [ -n "$band" ] && echo "$band"
}

# Cache the merged serving cell record for the lifetime of one info refresh.
tw_serving_cell()
{
    if [ -z "${tw_serving_line:-}" ]; then
        tw_serving_line=$(cmd_tw_teng_servingcell "$at_port" | tw_teng_join servingcell)
    fi
    printf '%s' "${tw_serving_line:-}"
}

base_info()
{
    local ati cgmm name manufacturer revision temperature voltage

    ati=$(cmd_tw_ati "$at_port")
    cgmm=$(cmd_tw_cgmm "$at_port")

    # ATI reports three payload lines: vendor, model, "Revision: <fw>".
    name=$(tw_prefixed_value "$cgmm" "+CGMM:")
    [ -n "$name" ] || name=$(tw_payload_line "$cgmm" 1)
    [ -n "$name" ] || name=$(tw_payload_line "$ati" 2)

    manufacturer=$(tw_payload_line "$ati" 1)
    [ -n "$manufacturer" ] || manufacturer=$(tw_payload_line "$(cmd_tw_cgmi "$at_port")" 1)
    [ -n "$manufacturer" ] || manufacturer="T&W"

    revision=$(printf '%s\n' "$ati" | sed -n 's/^Revision:[[:space:]]*//p' | tr -d '\r' | head -n 1)
    [ -n "$revision" ] || revision=$(tw_payload_line "$(cmd_tw_cgmr "$at_port")" 1)

    class="Base Information"
    add_plain_info_entry "name" "$name" "Name"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"

    temperature=$(tw_temperature "$(cmd_tw_temp "$at_port")")
    [ -n "$temperature" ] && add_plain_info_entry "temperature" "$temperature C" "Temperature"

    voltage=$(tw_voltage "$(cmd_tw_cbc "$at_port")")
    [ -n "$voltage" ] && add_plain_info_entry "voltage" "$voltage mV" "Voltage"

    get_connect_status
}

get_imei()
{
    local imei

    imei=$(cmd_tw_cgsn "$at_port" | grep -o '[0-9]\{15\}' | head -n 1)
    json_add_string "imei" "$imei"
}

# The vendor manual documents AT+TIMEI, but rewriting the IMEI is both
# unverified on this firmware and legally restricted, so the feature is
# advertised as disabled and this stub refuses instead of pretending.
set_imei()
{
    json_select "result"
    json_add_string "status" "unsupported"
    json_add_string "set_imei" "IMEI writing is disabled for TW500M-CN"
    json_close_object
    return 1
}

sim_info()
{
    local response flag imei iccid imsi

    response=$(cmd_tw_cpin_query "$at_port")
    flag=$(printf '%s\n' "$response" | grep -E '^\+CPIN:|^\+CME ERROR:' | head -n 1)
    sim_status=$(get_sim_status "$flag")

    imei=$(cmd_tw_cgsn "$at_port" | grep -o '[0-9]\{15\}' | head -n 1)

    class="SIM Information"
    add_plain_info_entry "SIM Status" "$sim_status" "SIM Status"
    add_plain_info_entry "IMEI" "$imei" "International Mobile Equipment Identity"
    [ "$sim_status" = "ready" ] || return

    # ICCID may only answer once the card is ready; QMI UIM does not expose it
    # on this firmware, so a failed AT+ICCID simply leaves the field empty.
    # The printed ICCID is not pure digits (spare nibble shows up as a letter),
    # so it is taken verbatim instead of being matched with a digit pattern.
    iccid=$(cmd_tw_iccid "$at_port" | sed -n 's/^+ICCID:[[:space:]]*//p' | tr -d '\r ' | head -n 1)
    imsi=$(cmd_tw_cimi "$at_port" | grep -o '[0-9]\{15\}' | head -n 1)

    add_plain_info_entry "IMSI" "$imsi" "International Mobile Subscriber Identity"
    add_plain_info_entry "ICCID" "$iccid" "Integrate Circuit Card Identity"
}

# USB composition is compiled in; AT+TPVID is a no-op on this firmware.
get_mode()
{
    local available_modes available_mode

    available_modes=$(uci -q get "qmodem.$config_section.modes")
    json_add_object "mode"
    for available_mode in $available_modes; do
        if [ "$available_mode" = "qmi" ]; then
            json_add_string "$available_mode" "1"
        else
            json_add_string "$available_mode" "0"
        fi
    done
    json_close_object
}

set_mode()
{
    json_select "result"
    json_add_string "status" "unsupported"
    json_add_string "set_mode" "USB composition is fixed: AT+TPVID accepts 2001/2004/2007/2008 but the PID stays 2004"
    json_close_object
    return 1
}

get_network_prefer()
{
    local response code prefer_4g="0" prefer_5g="0"

    response=$(cmd_tw_tcfg_query "$at_port" "nwscanmode")
    code=$(printf '%s\n' "$response" \
        | sed -n 's/.*"nwscanmode"[[:space:]]*,[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)

    case "$code" in
        0) prefer_4g="1"; prefer_5g="1" ;;
        3) prefer_4g="1" ;;
        4) prefer_5g="1" ;;
        *) prefer_4g="0"; prefer_5g="0" ;;
    esac

    # Only 4G and 5G are exposed: nwscanmode values for WCDMA/GSM are not
    # documented, so offering a 3G checkbox would be a lie.
    json_add_object "network_prefer"
    json_add_string 4G "$prefer_4g"
    json_add_string 5G "$prefer_5g"
    json_close_object
}

set_network_prefer()
{
    local selected count prefer_4g prefer_5g code response

    selected="$1"
    count=$(printf '%s' "$selected" | jq -r 'length' 2>/dev/null)
    case "$count" in
        ''|0)
            json_select "result"
            json_add_string "status" "error"
            json_add_string "set_network_prefer" "No network type selected"
            json_close_object
            return 1
            ;;
    esac

    prefer_4g=$(printf '%s' "$selected" | jq -r 'contains(["4G"])' 2>/dev/null)
    prefer_5g=$(printf '%s' "$selected" | jq -r 'contains(["5G"])' 2>/dev/null)

    # nwscanmode: 0 auto, 3 LTE only, 4 NR only (vendor AT manual).
    if [ "$prefer_4g" = "true" ] && [ "$prefer_5g" = "true" ]; then
        code=0
    elif [ "$prefer_4g" = "true" ]; then
        code=3
    elif [ "$prefer_5g" = "true" ]; then
        code=4
    else
        json_select "result"
        json_add_string "status" "error"
        json_add_string "set_network_prefer" "TW500M-CN supports 4G and 5G preference only"
        json_close_object
        return 1
    fi

    response=$(cmd_tw_tcfg_set "$at_port" "nwscanmode" "$code" "1")
    json_select "result"
    if printf '%s\n' "$response" | grep -q 'OK'; then
        json_add_string "status" "ok"
    else
        json_add_string "status" "error"
    fi
    json_add_string "code" "$code"
    json_add_string "res" "$response"
    json_close_object
}

network_info()
{
    local line state rat network_type carrier band

    line=$(tw_serving_cell)
    state=$(tw_csv_field "$line" 2)
    rat=$(tw_csv_field "$line" 3)
    network_type="${rat:-$state}"

    class="Network Information"
    add_plain_info_entry "Network State" "$state" "Network State"
    add_plain_info_entry "Network Type" "$network_type" "Network Type"

    # +TNWINFO is the only place that spells the band out by name.
    band=$(tw_tnwinfo_band "$(cmd_tw_tnwinfo "$at_port")")
    [ -n "$band" ] && add_plain_info_entry "Band" "$band" "Band"

    carrier=$(tw_plmn_carrier "$(tw_csv_field "$line" 5)" "$(tw_csv_field "$line" 6)")
    add_plain_info_entry "Carrier" "$carrier" "Carrier"
}

# Carrier aggregation is not reported by this firmware: +TENG carries one
# primary component only, and every SCC style query (AT+TCAINFO?/AT+CAINFO?/
# AT+QCAINFO/AT+TSCC?) returns ERROR. add_ca_info() is therefore never called
# here -- adding it would only print empty rows.
cell_info()
{
    local line rat fields mcc mnc state

    line=$(tw_serving_cell)
    [ -n "$line" ] || return 0

    rat=$(tw_csv_field "$line" 3)
    fields=$(printf '%s' "$line" | awk -F',' '{print NF}')

    class="Cell Information"
    mcc=$(tw_csv_field "$line" 5)
    mnc=$(tw_csv_field "$line" 6)

    case "$rat" in
        LTE)
            # Field map verified against a live China Mobile registration:
            #  1 "servingcell" 2 state 3 RAT 4 duplex 5 mcc 6 mnc 7 cellid
            #  8 pcid 9 earfcn 10 band 11 ul_bw 12 dl_bw 13 tac 14 rsrp
            #  15 rsrq 16 rssi 17 sinr 18 trailing "-"
            if [ "$fields" -ge 17 ]; then
                set_4g_cell_info "$mcc" "$mnc" \
                    "$(tw_csv_num "$line" 13)" \
                    "$(tw_csv_field "$line" 7)" \
                    "$(tw_csv_num "$line" 9)" \
                    "$(tw_csv_num "$line" 8)" \
                    "$(tw_csv_num "$line" 10)" \
                    "$(tw_csv_num "$line" 11)" \
                    "$(tw_csv_num "$line" 12)" \
                    "$(tw_csv_num "$line" 14)" \
                    "$(tw_csv_num "$line" 15)" \
                    "$(tw_csv_num "$line" 17)" \
                    "" \
                    "$(tw_csv_num "$line" 16)"
                return 0
            fi
            ;;
        NR5G-SA)
            # No 5G SA registration has been captured yet; the layout below is
            # the vendor's NSA/SA variant of the same +QENG shape.
            if [ "$fields" -ge 16 ]; then
                set_5g_cell_info "$mcc" "$mnc" \
                    "$(tw_csv_num "$line" 9)" \
                    "$(tw_csv_field "$line" 7)" \
                    "$(tw_csv_num "$line" 10)" \
                    "$(tw_csv_num "$line" 8)" \
                    "$(tw_csv_num "$line" 11)" \
                    "$(tw_csv_num "$line" 12)" \
                    "$(tw_csv_num "$line" 13)" \
                    "$(tw_csv_num "$line" 14)" \
                    "$(tw_csv_num "$line" 15)" \
                    "$(tw_csv_num "$line" 16)" \
                    "" \
                    ""
                return 0
            fi
            ;;
    esac

    # Layout not understood: show the raw line so it can be reported instead
    # of displaying fields that may belong to something else.
    state=$(tw_csv_field "$line" 2)
    add_plain_info_entry "Serving Cell" "$line" "Serving Cell (raw)"
    [ -n "$state" ] && add_plain_info_entry "Network State" "$state" "Network State"
}

# Neighbour cells come from AT+TENG="neighbourcell". This firmware has no
# cell lock command, so only the scan list is exposed.
#
# Verified shape (serving PCI 392 / EARFCN 3590 shows up with rsrq -7, rsrp -79,
# i.e. the RSRQ column comes before RSRP, same as +QENG):
#   +TENG: "neighbourcell intra","LTE",3590,392,-7,-79,-53,-20,-,-,-,-,-
#          1                        2     3    4   5  6   7   8
get_neighborcell()
{
    local lines line kind old_ifs

    json_add_object "Feature"
    json_add_string "Unlock" "2"
    json_add_string "Lock PCI" "1"
    json_add_string "Reboot Modem" "4"
    json_add_string "Manually Search" "3"
    json_close_object

    json_add_array "NR"
    json_close_array

    lines=$(cmd_tw_teng_neighbourcell "$at_port" | grep '^+TENG:' | sed 's/^+TENG:[[:space:]]*//' | tr -d '\r')
    json_add_array "LTE"
    old_ifs=$IFS
    IFS='
'
    for line in $lines; do
        [ "$(tw_csv_field "$line" 2)" = "LTE" ] || continue
        kind=$(tw_csv_field "$line" 1)
        json_add_object ""
        json_add_string "neighbourcell" "$kind"
        json_add_string "arfcn" "$(tw_csv_num "$line" 3)"
        json_add_string "pci" "$(tw_csv_num "$line" 4)"
        json_add_string "rsrq" "$(tw_csv_num "$line" 5)"
        json_add_string "rsrp" "$(tw_csv_num "$line" 6)"
        json_add_string "rssi" "$(tw_csv_num "$line" 7)"
        json_add_string "sinr" "$(tw_sinr_or_empty "$(tw_csv_num "$line" 8)")"
        json_close_object
    done
    IFS=$old_ifs
    json_close_array

    json_add_object "lockcell_status"
    json_add_string "LTE" "unlock"
    json_add_string "NR" "unlock"
    json_close_object
}

set_neighborcell()
{
    json_select "result"
    json_add_string "status" "unsupported"
    json_add_string "set_neighborcell" "Cell locking is not supported on TW500M-CN"
    json_close_object
    return 1
}

# AT+TCFG band bitmaps. Verified on a live module: bit 0 is band 1, the first
# mask covers bands 1-64 and the second covers 65-128. The shipped defaults
# read back as
#   band   (LTE) 0x1E200000095,0x0        -> B1 B3 B5 B8 B34 B38 B39 B40 B41
#   saband (SA)  0x10008000001,0x6000,... -> n1 n28 n41 + n78 n79
#   nsaband      0x10000000000,0x6000,... -> n41 + n78 n79
# which matches the China Mobile band set exactly.
#
# Writing a mask resets the modem and drops the PDP context, so the caller has
# to re-dial afterwards.

# Print the band numbers held in one hex mask.
#$1: mask, with or without 0x  $2: number of the lowest band in that mask
tw_mask_bands()
{
    local hex="$1" base="$2" pos=0 digit value bit bands=""

    hex=$(printf '%s' "$hex" | sed 's/^0[xX]//' | tr 'a-f' 'A-F')
    [ -n "$hex" ] || return 0

    while [ -n "$hex" ]; do
        digit=${hex#"${hex%?}"}
        hex=${hex%?}
        case "$digit" in
            [0-9]) value="$digit" ;;
            A) value=10 ;; B) value=11 ;; C) value=12 ;; D) value=13 ;;
            E) value=14 ;; F) value=15 ;;
            *) return 0 ;;
        esac
        for bit in 0 1 2 3; do
            [ $(( (value >> bit) & 1 )) -eq 1 ] && bands="$bands,$(( base + pos * 4 + bit ))"
        done
        pos=$(( pos + 1 ))
    done

    printf '%s' "${bands#,}"
}

# Split an AT+TCFG bitmap reply into its masks.
#$1: +TCFG line  ->  prints "0x.. 0x.." one per line
tw_tcfg_masks()
{
    printf '%s\n' "$1" | sed -n 's/^+TCFG:[[:space:]]*"[^"]*",//p' | tr -d '\r ' | tr ',' '\n'
}

# Build one hex mask from a list of band numbers.
#$1: comma separated bands  $2: number of the lowest band in the mask
tw_bands_mask()
{
    local list=",$1," base="$2" nib=15 bit band value digit out=""

    while [ "$nib" -ge 0 ]; do
        value=0
        bit=0
        while [ "$bit" -lt 4 ]; do
            band=$(( base + nib * 4 + bit ))
            case "$list" in
                *",$band,"*) value=$(( value | (1 << bit) )) ;;
            esac
            bit=$(( bit + 1 ))
        done
        case "$value" in
            10) digit=A ;; 11) digit=B ;; 12) digit=C ;; 13) digit=D ;;
            14) digit=E ;; 15) digit=F ;; *) digit="$value" ;;
        esac
        out="$out$digit"
        nib=$(( nib - 1 ))
    done

    while [ "${#out}" -gt 1 ]; do
        case "$out" in
            0*) out=${out#0} ;;
            *) break ;;
        esac
    done
    printf '%s' "$out"
}

get_lockband()
{
    local lte_masks sa_masks nsa_masks band

    lte_masks=$(tw_tcfg_masks "$(cmd_tw_tcfg_query "$at_port" "band")")
    sa_masks=$(tw_tcfg_masks "$(cmd_tw_tcfg_query "$at_port" "saband")")
    nsa_masks=$(tw_tcfg_masks "$(cmd_tw_tcfg_query "$at_port" "nsaband")")

    json_add_object "UMTS"
    json_add_array "available_band"
    json_close_array
    json_add_array "lock_band"
    json_close_array
    json_close_object

    json_add_object "LTE"
    json_add_array "available_band"
    for band in $(tw_band_list lte_band "1 3 5 8 34 38 39 40 41"); do
        add_avalible_band_entry "$band" "LTE_B$band"
    done
    json_close_array
    json_add_array "lock_band"
    for band in $(tw_mask_bands "$(printf '%s' "$lte_masks" | sed -n 1p)" 1); do
        json_add_string "" "$band"
    done
    for band in $(tw_mask_bands "$(printf '%s' "$lte_masks" | sed -n 2p)" 65); do
        json_add_string "" "$band"
    done
    json_close_array
    json_close_object

    json_add_object "NR"
    json_add_array "available_band"
    for band in $(tw_band_list sa_band "1 28 41 78 79"); do
        add_avalible_band_entry "$band" "NR_n$band"
    done
    json_close_array
    json_add_array "lock_band"
    for band in $(tw_mask_bands "$(printf '%s' "$sa_masks" | sed -n 1p)" 1); do
        json_add_string "" "$band"
    done
    for band in $(tw_mask_bands "$(printf '%s' "$sa_masks" | sed -n 2p)" 65); do
        json_add_string "" "$band"
    done
    json_close_array
    json_close_object

    json_add_object "NR_NSA"
    json_add_array "available_band"
    for band in $(tw_band_list nsa_band "41 78 79"); do
        add_avalible_band_entry "$band" "NR_n$band"
    done
    json_close_array
    json_add_array "lock_band"
    for band in $(tw_mask_bands "$(printf '%s' "$nsa_masks" | sed -n 1p)" 1); do
        json_add_string "" "$band"
    done
    for band in $(tw_mask_bands "$(printf '%s' "$nsa_masks" | sed -n 2p)" 65); do
        json_add_string "" "$band"
    done
    json_close_array
    json_close_object
}

# Print the band list to offer in the UI: the profile's own list when present,
# otherwise the hardware defaults captured from a TW500M-CN.
#$1: uci option name  $2: default list
tw_band_list()
{
    local configured
    configured=$(uci -q get "qmodem.$config_section.$1")
    [ -n "$configured" ] || configured="$2"
    printf '%s' "$configured" | tr '/' ' '
}

set_lockband()
{
    local config="$1" band_class lock_band masks key mask_count i response

    if command -v jq >/dev/null 2>&1; then
        band_class=$(printf '%s' "$config" | jq -r '.band_class' 2>/dev/null)
        lock_band=$(printf '%s' "$config" | jq -r '.lock_band' 2>/dev/null)
    else
        # Same two fields without the jq dependency, so the function can also
        # be exercised on a stripped-down test shell.
        band_class=$(printf '%s' "$config" | sed -n 's/.*"band_class"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        lock_band=$(printf '%s' "$config" | sed -n 's/.*"lock_band"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    lock_band=$(printf '%s' "$lock_band" | tr -d ' ')

    case "$band_class" in
        LTE) key="band"; mask_count=2 ;;
        NR) key="saband"; mask_count=8 ;;
        NR_NSA) key="nsaband"; mask_count=8 ;;
        *)
            json_select "result"
            json_add_string "status" "error"
            json_add_string "set_lockband" "Unsupported band class: $band_class"
            json_close_object
            return 1
            ;;
    esac

    [ -n "$lock_band" ] || {
        json_select "result"
        json_add_string "status" "error"
        json_add_string "set_lockband" "No band selected"
        json_close_object
        return 1
    }

    masks=""
    i=0
    while [ "$i" -lt "$mask_count" ]; do
        mask=$(tw_bands_mask "$lock_band" $(( i * 64 + 1 )))
        masks="${masks:+$masks,}$mask"
        i=$(( i + 1 ))
    done

    response=$(cmd_tw_tcfg_set "$at_port" "$key" "$masks" "1")
    json_select "result"
    if printf '%s\n' "$response" | grep -q 'OK'; then
        json_add_string "status" "ok"
    else
        json_add_string "status" "error"
    fi
    json_add_string "set_lockband" "$key=$masks"
    json_add_string "config" "$config"
    json_add_string "band_class" "$band_class"
    json_add_string "lock_band" "$lock_band"
    json_close_object
}

get_sim_slot()
{
    local response sim_slot

    response=$(cmd_tw_simdet_query "$at_port")
    sim_slot=$(tw_prefixed_value "$response" "+SIMDET:" | cut -d',' -f1 | tr -d '"')
    case "$sim_slot" in
        SIM1) sim_slot="1" ;;
        SIM2) sim_slot="2" ;;
        '') sim_slot="1" ;;
    esac
    json_add_string "sim_slot" "$sim_slot"
}

set_sim_slot()
{
    json_select "result"
    json_add_string "status" "unsupported"
    json_add_string "set_sim_slot" "SIM slot switching is not supported on TW500M-CN"
    json_close_object
    return 1
}

vendor_get_disabled_features()
{
    json_add_string "" "DialMode"
    json_add_string "" "IMEI"
}
