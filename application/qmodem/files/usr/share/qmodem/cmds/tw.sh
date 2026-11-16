#!/bin/sh
# T&W (Xi'an Gongjin) SDX55 module AT command wrappers.
#
# TW500M-CN drops the Quectel extensions and keeps the 3GPP basics: AT+QENG
# and AT+CLAC do not exist, so signal and cell data only come from the vendor
# private commands below. AT+CSQ, AT+COPS?, AT+CREG?, AT+ICCID and AT+CIMI do
# answer once the SIM is registered.
# Never send raw AT from the vendor layer; add a wrapper here instead so
# fixtures can be collected and replayed.
#
# Convention: $1 is the AT port, remaining args are command parameters.

#identity
cmd_tw_ati() { at "$1" 'ATI'; }
cmd_tw_cgmm() { at "$1" 'AT+CGMM'; }
cmd_tw_cgmi() { at "$1" 'AT+CGMI'; }
cmd_tw_cgmr() { at "$1" 'AT+CGMR'; }
cmd_tw_cgsn() { at "$1" 'AT+CGSN'; }

#SIM
cmd_tw_cpin_query() { at "$1" 'AT+CPIN?'; }
cmd_tw_simdet_query() { at "$1" 'AT+SIMDET?'; }
cmd_tw_iccid() { at "$1" 'AT+ICCID'; }
cmd_tw_cimi() { at "$1" 'AT+CIMI'; }
cmd_tw_cnum() { at "$1" 'AT+CNUM'; }

#serving cell and network information
#+TENG: "servingcell","SEARCH"
#+TENG: "servingcell","NOCONN","LTE","FDD",<mcc>,<mnc>,<cellid>,<pcid>,...
cmd_tw_teng_servingcell() { at "$1" 'AT+TENG="servingcell"'; }
cmd_tw_teng_neighbourcell() { at "$1" 'AT+TENG="neighbourcell"'; }
cmd_tw_tnwinfo() { at "$1" 'AT+TNWINFO'; }

#temperature; returns an empty field until the SIM is ready
cmd_tw_temp() { at "$1" 'AT+TEMP'; }

#supply voltage, standard +CBC: <bcs>,<bcl>,<mV>
cmd_tw_cbc() { at "$1" 'AT+CBC'; }

#generic configuration
#$2: key such as nwscanmode, band, saband or nsaband
cmd_tw_tcfg_query() { at "$1" "AT+TCFG=\"$2\""; }

#$2: key, $3: value, $4: storage flag (0 = apply now, 1 = save)
cmd_tw_tcfg_set() { at "$1" "AT+TCFG=\"$2\",$3,$4"; }

#$2: cid, $3: pdp type, $4: apn
cmd_tw_cgdcont_set() { at "$1" "AT+CGDCONT=$2,\"$3\",\"$4\""; }

#USB composition; the vendor list documents four targets (2077,2001 RNDIS /
#2077,2004 QMI / 2077,2007 MBIM / 2077,2008 ECM) but this firmware answers OK
#without changing the PID, so the wrapper stays here only for documentation.
cmd_tw_tpvid_set() { at "$1" "AT+TPVID=$2,$3"; }
