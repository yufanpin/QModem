# T&W（西安共进）模组适配说明

本页记录 `vendor/tw.sh` 的硬件前提、USB 绑定方式和已知限制。适用型号：
TW500M-CN、TW510M、TW500G（同为高通 SDX55 平台）。

## 硬件事实

| 项目 | 值 |
| --- | --- |
| USB VID:PID | `2077:2004` |
| 平台 | Qualcomm SDX55 |
| USB 器件 | **USB 3.2 器件**：`bcdUSB` 3.20，`tx_lanes`/`rx_lanes` 各 2（Gen 1x2 能力） |
| USB 链路 | 实际协商 **Gen 1x1 / 5000 Mbps**（主机根集线器 10000 Mbps，只给 1 lane） |
| 取电 | `MxPwr` 896 mA（5G 模块峰值更高，M.2 座供电不足会优先影响 SuperSpeed 枚举） |
| 数据通道 | RmNet → `qmi_wwan` → `/dev/cdc-wdm0` + `wwan0` |
| QMI 客户端 | `/dev/cdc-wdm0` 同一时刻只服务一个客户端，见下节 |
| USB composition | 固件写死，`AT+TPVID` 返回 `OK` 但 PID 不变，只能走 QMI |
| 可用拨号模式 | `qmi` |

接口布局：

```
1.0  ff/ff/30  DIAG        不响应 AT
1.1  ff/ff/40  Modem AT    AT 可用
1.2  ff/ff/40  App AT      AT 可用
1.3  ff/ff/60  NMEA        不响应 AT
1.4  ff/ff/50  RmNet       qmi_wwan
```

`modem_port_rule.json` 的 `include` 只列 `1.1`/`1.2`。`1.0`/`1.3` 发 AT 会挂起，
不能作为候选 AT 端口。

## USB 链路速率

模组**不是** USB 2.0 器件。它的设备描述符里 `bcdUSB` 是 **3.20**，并且 SSP 能力上报
`tx_lanes = rx_lanes = 2`，也就是 USB 3.2 Gen 1x2（双通道 5 Gbps，理论 10 Gbps）。
内核按协商出的 `ssp_rate` 打印成 `SuperSpeed Gen 1x2`，而 sysfs 的 `speed` 给的是
**每条 lane 的速率**（5000），两个数并不矛盾：

```
/sys/bus/usb/devices/2-1/version        3.20      # 设备 bcdUSB
/sys/bus/usb/devices/2-1/speed          5000      # 每 lane 速率
/sys/bus/usb/devices/2-1/tx_lanes       2         # Gen 1x2 能力
/sys/bus/usb/devices/2-1/rx_lanes       2
/sys/bus/usb/devices/2-1/bMaxPower      896mA
/sys/bus/usb/devices/usb2/speed         10000     # 根集线器 10 Gbps
dmesg: usb 2-1: new SuperSpeed Gen 1x2 USB device number 2 using xhci-mtk
       xhci-mtk: Host supports USB 3.2 Enhanced SuperSpeed
```

`/sys/kernel/debug/usb/devices` 的对应关系（主机侧 `Spd=10000 Ver=3.10` 是根集线器，
`Spd=5000 Ver=3.20` 才是模组）：

```
T:  Bus=02 Lev=00 ... Spd=10000 ... D: Ver= 3.10   # xhci-mtk 根集线器
T:  Bus=02 Lev=01 ... Spd=5000  ... D: Ver= 3.20   # 模组 2077:2004
```

M.2 B-key 座只引出一对 SuperSpeed 差分对，所以算有效带宽时按单 lane 5 Gbps 估就够
——对 5G 模组（现网下行 < 1 Gbps）远不是瓶颈。

**没有任何 AT 指令能在这颗模组上切 USB 2.0/3.0。** `AT+TCFG=?` 的全部参数是
`nwscanmode / wband / band / saband / nsaband / nwscanseq / PDP/duplicatechk / usageset /
ltesms/format`，没有 usb 相关项；`AT+TPVID=?` 无参数、`AT+TPVID` 只回 `OK`（改 PID 无效）。
所以“切到 USB2.0”只能是物理层的：换口、换线、换转接板，或者座子只引了 D+/D-。

这一点对测速有实际意义：USB 2.0 的 480 Mbps（实测约 40 MB/s）会先于蜂窝侧成为
瓶颈，USB 3.0 下不会。若跑在 480M 上，先查 USB 3.0 触点/线序（USB2 只有 4 线，
3.0 需要另外 5 根 SuperSpeed 差分对），而不是怀疑模组。

## QMI 控制通道是独占的

`/dev/cdc-wdm0` 同一时刻只服务一个 QMI 客户端。**`quectel-CM` 运行期间**用
`uqmi` 访问会得到：

```
Request timed out
"Failed to connect to service"
```

停掉 `quectel-CM`（本机是 `/etc/init.d/modemdata`）后，同样的命令立刻正常：

```
$ uqmi -d /dev/cdc-wdm0 --get-serving-system
{"registration":"registered","plmn_mcc":460,"plmn_mnc":0,
 "plmn_description":"CMCC","roaming":false}
$ uqmi -d /dev/cdc-wdm0 --get-data-status
"disconnected"        # 因为拨号进程已停，不是故障
```

所以排障时不要把这个报错当成固件不兼容：**先确认没有别的拨号进程占着 cdc-wdm0**。
反过来也说明 QModem 接管拨号前必须先停掉厂商自带的 `modemdata`/`00-tw500m.sh`
一类的脚本，否则两者会互抢。QModem 的 `modem_dial.sh` 走 `uqmi`，是可以用的
（实测 `--get-serving-system`/`--get-signal-info`/`--get-capabilities` 均正常返回）。

## 载波聚合（CA）

**结论：本固件不上报聚合状态，QModem 里做不出 CA 面板；现场也没有可聚合的第二载波。**

实测（2026-11-16，China Mobile，单站只覆盖 B8）：

| 检查点 | 结果 |
| --- | --- |
| `AT+TENG="servingcell"` | 只有一条 PCC：`"LTE","FDD",460,00,EA497AD,392,3590,8,3,3,…`，无 SCC 字段 |
| `AT+TNWINFO` | `"FDD LTE","46000","LTE BAND 8",3590`，只报主载波 |
| `AT+TCAINFO?` / `AT+CAINFO?` / `AT+QCAINFO` / `AT+TSCC?` | 全部 `ERROR`（不存在这些命令） |
| `AT+TCFG=?` | 只有 `nwscanmode`/`wband`/`band`/`saband`/`nsaband`/`nwscanseq`/`PDP`/`usageset`/`ltesms`，无 CA 相关项 |
| `AT+TENG="neighbourcell"` | 邻区只有 B8（3590，-81/-92）和 B39（38400，**-119**） |
| 吞吐 | 单流 22.7 Mbps；4 路并发合计仍约 21 Mbps（不叠加） |

B8 是 10 MHz（`+TENG` 的 `ul/dl` 字段为 `3` = 10 MHz，2×2 MIMO 单载波峰值约 75
Mbps），邻区里唯一的异频点 B39 只有 -119 dBm，达不到 SCell 的添加门限（通常
约 -105 dBm）。所以：**没聚合，而且就算网络想聚合，这个位置也没有可加的第二载波。**

要判"能不能聚"，只能在 B3/B41 与 B8 同覆盖的位置复测：

1. 用锁频段把模组锁到 B41（`AT+TCFG="band",<B41 掩码>,0,1`），确认能否注册、速率
   是否超过单载波理论上限（20 MHz 单载波约 150 Mbps）。
2. 想要看到"聚合了几载波"，唯一手段是 QMI NAS 的 `Get Cell Info`（返回 SIB2 与
   SCC 列表）。`uqmi` 没有这个动作，需要装 `qmicli`（libqmi）：

   ```sh
   qmicli -d /dev/cdc-wdm0 --nas-get-cell-info
   qmicli -d /dev/cdc-wdm0 --nas-get-rf-band-info
   ```

   `qmicli` 同样要独占 `cdc-wdm0`，先停拨号进程。

留一个旁证：QMI DMS 能力报 `max_rx_channel_rate=100 Mbps`、`max_tx=50 Mbps`，
这更像单载波/低阶 CA 的申报值，而不是高阶 CA 模组的常见值；`networks` 只列出
`umts`/`lte`/`unknown`（NR 在旧版 libqmi 里显示为 `unknown`）。

## AT 能力

厂商 AT 集是私有的（`AT+TENG`/`AT+TCFG`/`AT+TNWINFO`），不是移远那套 `AT+Q*`，
也不是标准 `AT$QCSQ`：

| 功能 | 命令 | 状态 |
| --- | --- | --- |
| 身份/固件 | `ATI`、`AT+CGMM`、`AT+CGMI`、`AT+CGMR` | 实测可用 |
| IMEI | `AT+CGSN` | 实测可用 |
| SIM | `AT+CPIN?`、`AT+SIMDET?` | 实测可用（SIMDET 只读） |
| IMSI / ICCID | `AT+CIMI`、`AT+ICCID` | 插卡后实测可用；ICCID 含字母（`898602A7142297010305`），不能按纯数字匹配 |
| 信号/小区 | `AT+TENG="servingcell"` | 唯一信号来源，**返回分两行**，字段顺序见下 |
| 邻区 | `AT+TENG="neighbourcell"` | 实测可用，RSRQ 在 RSRP 之前 |
| 网络/频段 | `AT+TNWINFO` | 实测可用，唯一带频段名（`"LTE BAND 8"`）的命令 |
| 运营商/注册 | `AT+COPS?`、`AT+CREG?`、`AT+CSQ` | **注册后可用**（无卡时 `ERROR`），`+COPS: 0,0,"CHINA MOBILE",7` |
| 制式锁定 | `AT+TCFG="nwscanmode",<0/3/4>,1` | 0 自动、3 仅 4G、4 仅 5G |
| 频段锁定 | `AT+TCFG="band"/"saband"/"nsaband",<掩码>,1` | 实测可用，位图映射见下 |
| 温度 | `AT+TEMP` | 插卡后仍返回 `+TEMP: ,`，无数据 |
| 供电电压 | `AT+CBC` | 只回 `+CBC: 2,0`，没有 mV 字段，因此不显示 |
| 复位 | `AT+CFUN=1,1` | 实测可用 |
| 不可用 | `AT+CLAC`、`AT+QENG`、`AT+QNWINFO`、`AT+QCFG`、`AT$QCSYSMODE`、`AT+TSIMDET?` | `ERROR` |

> 早先无卡测试时 `AT+CSQ`/`AT+COPS?`/`AT+CREG?` 全部 `ERROR`，插卡注册后恢复正常。
> 这类"无卡就没实现"的命令不要按无卡结果写死。

`+TENG` 的字段顺序（LTE 已按实测核对）：

```
LTE:     "servingcell","<state>","LTE","<duplex>",mcc,mnc,cellid,pcid,earfcn,band,ul,dl,tac,rsrp,rsrq,rssi,sinr,-
NR5G-SA: "servingcell","<state>","NR5G-SA","<duplex>",mcc,mnc,cellid,pcid,tac,arfcn,band,ul,dl,rsrp,rsrq,sinr
```

实测一条（China Mobile / B8）：

```
+TENG: "servingcell","CONNECT","LTE"
+TENG: "LTE","FDD",460,00,EA497AD,392,3590,8,3,3,7973,-78,-7,-53,19,-
```

注意两点，解析必须处理，否则小区页面会一直空白：

1. **记录被拆成两行**，第二行重复了 RAT 字段。`tw_teng_join` 会把它们合成一条，
   并去掉重复的 `"LTE"`，合成后才是上面那张字段表的布局。
2. 结尾那个 `-` 是未使用的占位字段，数值解析遇到 `-` 要当作空，不能当成 0。

## 厂商资料的两个坑

厂商随货的资料不能直接当能力清单用，两处都是移远模板改名的产物：

1. **`常用at指令.txt` 是 RM500Q 的说明书**。文件里自己写着「SIM卡热插拔（RM500Q
   默认：`AT+TSIMDET=1,1`）」，还列了 `AT$QCSQ`、`AT$QCSYSMODE`、`AT+TSIMDET?`、
   `AT+COPS?`、`AT+CREG?`、`AT+TMAPWAC`。其中 `AT$QCSQ`/`AT$QCSYSMODE`/`AT+TSIMDET?`
   实测确实 `ERROR`，但 `AT+COPS?`/`AT+CREG?` 插卡注册后是可用的 —— 说明这份表只能
   作为"可能有哪些命令"的线索，能不能用必须逐条实机验证。
2. **Windows 驱动包是移远的套壳**。`T&W_Windows_USB_Driver(Q)_NDIS` 里五个 INF 的硬件
   ID 只有 `2C7C`（移远）、`2CA3`、`3763`、`05C6:9008`（高通 EDL），**没有一条 `2077`**，
   装到 TW500M 上不会匹配。它对 Linux 侧零价值，唯一可借用的是 `05C6:9008` 这个
   EDL 模式 ID —— 刷坏固件时可以靠它救砖。

反过来看，这套 INF 的接口编排（`MI_00`~`MI_03` 串口 + `MI_04` 数据）与实测拓扑一致，
说明模组的 USB 描述符就是移远那套标准型，也是本页接口表可信的旁证。

## 未启用的能力与验证方法

`AT+TPVID` 文档里有四个目标组合，实测都返回 `OK` 但 PID 恒为 `2004`：

| 命令 | 目标 |
| --- | --- |
| `AT+TPVID=2077,2001` | RNDIS |
| `AT+TPVID=2077,2004` | QMI（当前） |
| `AT+TPVID=2077,2007` | MBIM |
| `AT+TPVID=2077,2008` | ECM |

若某版固件让 `2007` 真正生效，MBIM 走标准 `cdc_mbim`，**可以完全绕开本页的
`new_id` 绑定流程**。所以插卡前值得再试一次 `AT+TPVID=2077,2007` + `AT+CFUN=1,1`，
然后 `lsusb` 看 PID；真变了就补 `2077:2007` 的 profile 与端口规则。

锁频段的位图格式（`AT+TCFG=?`）：

```
+TCFG: "wband",(0-405FF),(0,1)
+TCFG: "band",(0-FFFFFFFFFFFFFFFF),(0-FFFFFFFFFFFFFFFF),(0,1)
+TCFG: "saband",(0-FFFFFFFFFFFFFFF) × 8,(0,1)
+TCFG: "nsaband",(0-FFFFFFFFFFFFFFF) × 8,(0,1)
```

**已实测确认**：bit0 对应频段 1，第一个掩码覆盖 1–64，第二个覆盖 65–128，`saband`/
`nsaband` 共 8 个掩码（后 6 个恒为 0）。依据是出厂默认值反解出来的正好是移动的频段组合：

| 项 | 原始回显 | 解出的频段 |
| --- | --- | --- |
| LTE | `0x1E200000095,0x0` | B1 B3 B5 B8 B34 B38 B39 B40 B41 |
| SA | `0x10008000001,0x6000,0×6` | n1 n28 n41 / n78 n79 |
| NSA | `0x10000000000,0x6000,0×6` | n41 / n78 n79 |

写入格式（注意：**掩码不带 `0x`**，末尾必须带生效标志）：

```sh
AT+TCFG="band",1E200000095,0,1          # LTE，2 个掩码
AT+TCFG="saband",10008000001,6000,0,0,0,0,0,0,1     # SA，8 个掩码
AT+TCFG="nsaband",10000000000,6000,0,0,0,0,0,0,1    # NSA，8 个掩码
```

`AT+TCFG="band",0x80,0x0,1` 这种带 `0x` 的写法会 `ERROR`；省略末尾标志（3 参数）也会
`ERROR`。**写频段会让模组重新搜网、PDP 断开**，QModem 侧改完必须重新拨号——实测
`ifdown wwan && ifup wwan` 能恢复。

`lockband` 的 UI 允许在 `lte_band`/`sa_band`/`nsa_band` 三个 profile 字段给出的频段里
勾选，这三个字段会由扫描器写进 UCI；写死默认值就是上表那一组。

另外 `AT+TMAPWAC=1`（模组侧 5G 自拨号）在 OpenWrt 上必须保持关闭：它和
`uqmi`/`quectel-CM` 抢同一条 PDP，症状是 `--start-network` 报 `Call failed`，
或者拿到 IP 但 ping 不通。排障第一步就是 `AT+TMAPWAC=0`。

## USB 绑定（与其它型号最大的差别）

`option.ko` 和 `qmi_wwan.ko` 的 ID 表里都没有 `2077:2004`。只在端口规则里把
`option_driver` 设为 `1` 会带来一个反效果：`option` 的 `new_id` 会连 1.4（RmNet）
一起接管，`/dev/cdc-wdm*` 和 `wwan0` 都不会出现，拨号无从谈起。

因此本型号在 `modem_port_rule.json` 里用 `usb_bind` 描述接口归属，由
`modem_usb_bind.sh` 在扫描前完成路由：

```json
"2077:2004": {
    "name": "tw500m-cn",
    "mode": "qmi",
    "option_driver": 0,
    "include": ["1.1", "1.2"],
    "usb_bind": {
        "serial": ["1.0", "1.1", "1.2", "1.3"],
        "network": { "1.4": "qmi_wwan" }
    }
}
```

执行顺序（`modem_usb_bind.sh`）：

1. 先把 1.4 绑到 `qmi_wwan`（`new_id` → `bind` → `remove_id`）。放在最前面是有原因的：
   `option` 的 `new_id` 会让 usb-serial 核心**扫描该设备所有还没被占用的接口**，1.4 先被
   `qmi_wwan` 占住，这次扫描就不会把它吞掉，`cdc-wdm0` 可以立刻出现。
2. 再把 `2077 2004` 注册给 `option`，绑定 1.0–1.3；已经绑好的跳过，缺的显式 `bind`。
3. 如果 1.4 已经被 `option` 占着（例如厂商脚本先跑过），先从 `option` `unbind` 再按第 1 步重绑。

调用点：`modem_scan.sh add/scan`、`qmodem_init` 的开机扫描。热插拔和 UI 手动扫描
都会经过这里。

### 1.4 归属竞态：“有时认不到模组”的真正原因

`option1/new_id` 里的 `2077 2004` **一旦写进去就删不掉**：内核 5.4 的
`/sys/bus/usb-serial/drivers/option1/` 只导出 `new_id`，没有 `remove_id`
（`qmi_wwan` 那个有）。厂商的 `00-tw500m.sh` 也是只写不删，于是这条动态 ID 在整个
开机周期内一直有效。

后果：**之后每一次重新枚举**，`option` 都会把 1.4 一起接管。此时：

```
1.4=option        # 而不是 qmi_wwan
/dev/cdc-wdm0     不存在
wwan0             不存在
```

`modem_scan` 拿不到 `net_devices` 就不会注册模组，表现出来就是“插着模组但识别不到”。
实测复现（不动硬件，2026-11-16 在 BPI-R3 mini 上跑过两轮）：

```sh
echo 2-1 > /sys/bus/usb/drivers/usb/unbind
echo 2-1 > /sys/bus/usb/drivers/usb/bind      # 软重绑，等价于一次端口 reset

# 重绑前            重绑后
# 1.4 -> qmi_wwan   1.4 -> option        <-- 被抢走
# /dev/cdc-wdm0     （消失）
# wwan0             （消失）
# speed = 5000      speed = 5000         <-- 链路速率没变，仍是 SuperSpeed
```

**注意第二行的 `speed`：重绑前后都是 5000 Mbps。** 也就是说“识别不到”这件事
和 USB 2.0/3.0 完全无关——同一条 5 Gbps 链路上，只要发生一次不带 `usb_device add`
的重枚举，就会掉进这个坑。

厂商脚本救不了这种状态：它的入口条件是 `ACTION=add` 且 `DEVTYPE=usb_device`，
而软重绑只产生 interface 级别的 add 事件。**只有物理插拔或重启才会触发它。**

这也解释了“换到 USB2.0 就能识别”的现象：换口/换线相当于重新插拔，脚本跑了一遍，
于是恢复；而留在 USB3 上如果只是链路重训练或驱动 reload 造成的重枚举，就不会有
`usb_device add` 事件，状态停在坏的那一边。**换 2.0 起作用的是“拔插了一次”，
不是“2.0 更快/更兼容”。**

顺带排除一个常见怀疑：系统里的 `usbmode`（`/sbin/usbmode -s`，由
`/etc/hotplug.d/usb/20-usb_mode` 触发）**不会动这颗模组**——`/etc/usb-mode.json`
只有 `2077:1000`、`2077:f000` 等移远的 PID，没有 `2077:2004`。

修法就是让 `modem_usb_bind.sh` 在每次扫描前跑一遍，实测有效（手工执行等价操作
也从上面的坏状态里恢复过，`wwan0` 拿回同一个 `10.178.73.54/30`，ping 通）：

```
modem_usb_bind: slot=2-1 interface=1.4 unbound from option
modem_usb_bind: slot=2-1 interface=1.4 bound to qmi_wwan (now: qmi_wwan)
→ /dev/cdc-wdm0 出现
```

修完要从坏状态里出来，还要重启一次拨号守护（`/etc/init.d/modemdata restart`），
因为 `quectel-CM` 在 `cdc-wdm0` 消失时已经退出了。

另外如果确实遇到 USB3 链路不稳（反复 reconnect、枚举失败），可以先看端口的
USB3 LPM 设置——MT7986 的 xhci 默认允许 U1/U2：

```sh
cat /sys/bus/usb/devices/usb2/2-0:1.0/usb2-port1/usb3_lpm_permit   # u1_u2
```


## 依赖

必须选上**通用** QMI 驱动：

```
PACKAGE_qmodem_INCLUDE_generic-qmi-wwan=y   # kmod-usb-net-qmi-wwan
```

默认选项是 `vendor-qmi-wwan`（`qmi_wwan_q`），该驱动对 TW500M 会出现
`Failed to connect to service` / `[TIMEOUT]`，不能替代。AT 口依赖
`kmod-usb-serial-option`（已在 `qmodem` 默认依赖中）。

`qmi` 拨号由 `modem_dial.sh` 调用 `quectel-CM` 完成，因此还需要选中至少一个 CM 包：

```
PACKAGE_qmodem_USING_NORMAL_QUECTEL_CM=y    # quectel-cm
# 或 PACKAGE_qmodem_USING_QWRT_QUECTEL_CM_5G / PACKAGE_qmodem_USE_TOM_CUSTOMIZED_QUECTEL_CM
```

## 已知限制（模组固件决定，不是适配缺失）

| 功能 | 状态 | 原因 |
| --- | --- | --- |
| 拨号模式切换 | 不提供 | composition 编译写死，`AT+TPVID` 接受 2001/2004/2007/2008 但 PID 不变 |
| 锁小区 | 不提供 | 无对应命令（邻区列表可读，但不能锁） |
| 锁频段 | **已提供** | `AT+TCFG="band"/"saband"/"nsaband"`，映射已实测确认 |
| 载波聚合显示 | 不提供 | 固件无 SCC 查询命令，`+TENG` 只报主载波，见上文「载波聚合」节 |
| 温度 / 电压 | 不显示 | `AT+TEMP` 回 `+TEMP: ,`，`AT+CBC` 回 `+CBC: 2,0`，都没有数值 |
| 改 IMEI | 不提供 | `AT+TIMEI` 可写但属违规操作，`set_imei` 直接拒绝 |
| 双 SIM 切换 | 不提供 | 模组报 `SIM1`/`SIM2`，未找到切换命令 |
| 短信 | 未验证 | 走 `tom_modem` 的 CPMS/PDU 路径，需实卡确认 |
| 流量统计 | 走 sysfs | 无模组侧 AT 计数器 |

以上能力通过 `vendor_get_disabled_features` 从 LuCI 高级页面隐藏，避免出现
永远失败的按钮。

## 验证状态

| 层级 | 状态 |
| --- | --- |
| 配置已添加（profile/端口规则/厂商脚本） | 完成 |
| 静态检查（AT 边界、shell 语法、usb_bind 单测） | 完成 |
| SDK 构建 | 未执行 |
| 实机验证（识别 / AT / 信息采集 / 锁频段） | **完成**（BPI-R3 mini + QWRT 23.05，插卡） |
| QModem 运行时集成（LuCI 点击、拨号托管） | 未执行，实机跑的是 QWRT 自带 `00-tw500m.sh` + `quectel-CM` |

### 实机验证记录（2026-11-16）

环境：BPI-R3 mini / QWRT R24.04 / OpenWrt 23.05 / kernel 5.4.250，TW500M-CN 插卡
（China Mobile，IMSI `460075…`）。

```
2077:2004  →  1.0-1.3 option，1.4 qmi_wwan
USB 2-1     →  speed 5000 Mbps（每 lane），设备 bcdUSB 3.20 / tx,rx_lanes=2，
              链路 Gen 1x1，主机 xhci-mtk 根集线器 10000M
/dev/ttyUSB0..3 + /dev/cdc-wdm0 + wwan0(10.110.62.254/30)，quectel-CM 拨号成功
```

把 `vendor/tw.sh` 用桩框架在设备上跑一遍，输出与真实回显一致：

```
base_info     name=TW500M-CN  manufacturer=T&W  revision=V1.0.2
sim_info      ready  IMEI=866104050053340  IMSI=460075700558690  ICCID=898602A7142297010305
network_info  CONNECT / LTE / Band=8 / China Mobile
cell_info     MCC=460 MNC=00 TAC=7973 CellID=EA497AD EARFCN=3590 PCI=392
              Band=8 UL=3 DL=3 RSRP=-82 RSRQ=-7 SINR=12 RSSI=-56
neighbourcell 4 条 LTE（earfcn 3590/38400，rsrq 在 rsrp 之前）
lockband      LTE 1,3,5,8,34,38,39,40,41；SA 1,28,41+78,79；NSA 41+78,79
```

`set_lockband` 用当前值回写（`AT+TCFG="band",1E200000095,0,1`）返回 `OK`，读回不变，
连接未中断 —— 说明掩码拼装正确。

吞吐与聚合（同一次实测，镜像站单流/四路并发各 8 s）：

```
单流       22.7 Mbps
4 路并发   合计约 21 Mbps（不叠加，说明是单载波或限速，而不是 USB/主机瓶颈）
+ 邻区     3590(B8,-81/-92) + 38400(B39,-119)
+ QMI      uqmi --get-capabilities: max_rx=100 Mbps max_tx=50 Mbps, networks=[umts,lte,unknown]
```

`uqmi` 是在停掉 `quectel-CM` 之后才连上 QMI 服务的（见「QMI 控制通道是独占的」），
`--get-serving-system`、`--get-signal-info`、`--get-capabilities` 均正常返回，
说明 QModem 的 `uqmi` 拨号路径在本固件上可用。

仍未验证的部分：

- 5G SA 的 `+TENG` 字段布局（现场只注册到 LTE，没有 NR 样本）。`NR5G-SA` 分支沿用
  同一形状，如果真实返回字段数不足会退化成 `Serving Cell (raw)`，不会给错值。
- 载波聚合是否真的会发生（需要 B3/B41 与 B8 同覆盖的位置；本机用 `qmicli` 读 SIB2 才能确认）。
- 短信、SIM 卡槽切换、IMEI。
- QModem 自身在 LuCI 里的点击流程（设备上没装 QModem，用的是 QWRT 自带脚本）。

采集 fixture 时按 `testcases/README.md` 的流程，把上面的真实回显固化成
`expected/base_info.json` 等文件，就能从"实机验证"升级到"fixture 可回放"。
