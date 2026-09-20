# 硬件与已知问题

## 硬件

- **SoC**：Qualcomm QRB5165 / SM8250（8 核 Kryo，Adreno 650）
- **内存 / 存储**：12G LPDDR5 / 256G UFS
- **上游板名**：`dg-svr-865-tiny`（DG SVR 865 Tiny，厂商 Dg741a）
- **Armbian 官方支持**：<https://www.armbian.com/boards/dg-svr-865-tiny/>
  维护者 [FantasyGmm](https://github.com/FantasyGmm)
- **同 SoC 参考**：Thundercomm EB5 / Qualcomm RB5

> 本仓库产出的镜像名为 `nico-debian-sm8250`（见 `config/image.conf`）。
> 上游 Armbian 用的板名是 `dg-svr-865-tiny`，两者指同一块板子。

## 关键外设

| 设备 | 说明 |
| --- | --- |
| PCIe0 (`1c00000`) | QCA6390 WiFi/BT（`17cb:1101`），主线开箱可用 |
| PCIe1 (`1c08000`) | **ASM2806 PCIe switch + 2× RTL8168 千兆网口**，需要额外处理 |
| PCIe2 (`1c10000`) | 5G modem（MHI），一般不用 |
| UFS (`1d84000`) | 根文件系统所在 |
| USB1/USB2 | USB-C + USB3，可做 ADB gadget |
| 串口 | `ttyMSM0` @ 0xa90000，115200 8N1 |

## PCIe1 / 有线网卡：为什么需要树外模块

### 现象

主线内核下 `lspci -nn | grep '^0001:'` 只能看到 root port：

```
0001:00:00.0 PCI bridge [0604]: Qualcomm Device [17cb:010b]
```

ASM2806 及其后面的 RTL8168 完全不出现。厂商 4.19 内核则能完整枚举：

```
0001:01:00.0 PCI bridge [0604]: ASMedia ASM2806 [1b21:2806]
0001:02:00.0 PCI bridge [0604]: ASMedia ASM2806 [1b21:2806]
0001:02:06.0 PCI bridge [0604]: ASMedia ASM2806 [1b21:2806]
0001:02:0e.0 PCI bridge [0604]: ASMedia ASM2806 [1b21:2806]
0001:04:00.0 Ethernet controller [0200]: Realtek RTL8111/8168 [10ec:8168]
0001:05:00.0 Ethernet controller [0200]: Realtek RTL8111/8168 [10ec:8168]
```

### 原因

ASM2806 这个 switch 需要板子上几根 GPIO 按照**特定顺序**动作之后才会响应配置空间访问：

```
PERST 82   : high 100ms -> low 200ms
GPIO  88   : low 10ms -> high 10ms
GPIO  89   : low 10ms -> high 10ms
GPIO  121  : high, 保持 5s
GPIO  127  : high
GPIO  126  : high, 保持 120ms
```

（GPIO141 在这块板子上是 **wake 输入**，不需要驱动。）

主线的 `qcom-pcie` 驱动不知道这个板级时序，所以 ASM2806 一直不响应。

### 解决方式（本仓库的做法）

`modules/tc-eb5/` 里有两个**树外模块**，不改任何内核源码：

> 这两个模块来自 [Evsio0n/tc-eb5-oot](https://github.com/evsio0n/tc-eb5-oot) v0.2.1
> （GPL-2.0-only）。本仓库只做了最小改动以适配 6.18/7.x 内核。
> 完整的来源、许可与上游实测数据见 [`CREDITS.md`](../CREDITS.md)。

1. **`tc-eb5-pcie-helper`**
   - 按上面顺序驱动 GPIO 82/88/89/121/127/126；
   - 把 PERST 暴露成一个 **GPIO provider**（`gpio-controller`）；
   - 设备树里 `&pcie1` 的 `perst-gpios = <&pcie1_sequence 0 GPIO_ACTIVE_LOW>`，
     于是**未经修改的** `qcom-pcie` 驱动会通过这个 provider 去拉 PERST，
     顺序天然正确；
   - 还带一个"延迟绑定门"：等原生 PCIe host 绑定完成之后再放行 r8169，
     避免异步 probe 时的 `request_module` 警告和竞态。

2. **`tc-eb5-qmp-pcie`**（可选，本仓库默认不编）
   - 树外的 QMP PCIe PHY 实现，带厂商 PHY sequence 和诊断。

### 实测验证（真实部署机器）

一台已部署的 DG-SVR-865-TINY（Armbian 26.5.1，`6.18.35-current-sm8250`）
上实测的启动日志：

```
[ 10.850995] qcom-pcie 1c08000.pcie: PCIe Gen.3 x2 link up
[ 10.943742] pci 0001:01:00.0: [1b21:2806] ASM2806 Switch Upstream Port
[ 11.017286] pci 0001:02:00.0: [1b21:2806] ASM2806 Switch Downstream Port
[ 11.071340] pci 0001:02:06.0: [1b21:2806] ASM2806 Switch Downstream Port
[ 11.125384] pci 0001:02:0e.0: [1b21:2806] ASM2806 Switch Downstream Port
[ 11.212515] pci 0001:04:00.0: [10ec:8168] PCIe Endpoint
[ 11.283540] pci 0001:05:00.0: [10ec:8168] PCIe Endpoint
[ 11.767049] NETGATE: native host bound; opening supplier async=0 seen=3
[ 11.816001] r8169 0001:04:00.0 eth0: RTL8168h/8111h
[ 11.839096] NETGATE: bound 0001:04:00.0 driver=r8169 async=0
```

对应的 GPIO 时序（同一台机器）：

```
EB5 ASM2806: verified TLMM controls; GPIO141 remains wake input
EB5 ASM2806: GPIO82  requested=1 dir=0 raw=1 hold_ms=100
EB5 ASM2806: GPIO82  requested=0 dir=0 raw=0 hold_ms=200
EB5 ASM2806: GPIO88  requested=0 dir=0 raw=0 hold_ms=10
EB5 ASM2806: GPIO88  requested=1 dir=0 raw=1 hold_ms=10
EB5 ASM2806: GPIO89  requested=0 dir=0 raw=0 hold_ms=10
EB5 ASM2806: GPIO89  requested=1 dir=0 raw=1 hold_ms=10
EB5 ASM2806: GPIO121 requested=1 dir=0 raw=1 hold_ms=5000
EB5 ASM2806: GPIO127 requested=1 dir=0 raw=1 hold_ms=0
EB5 ASM2806: GPIO126 requested=1 dir=0 raw=1 hold_ms=120
EB5 ASM2806: sequence complete; PERST held low for PHY init
EB5 ASM2806: pre-PERST-release settle 10 ms
EB5 ASM2806: post-PERST settle 200 ms (before LTSSM)
```

模块信息：`version 0.2.1`、`vermagic 6.18.35-current-sm8250`、
`alias of:N*T*Cthundercomm,tc-eb5-pcie-sequencer`。

**未验证**：真实网络吞吐、冷启动多次循环、休眠唤醒。

## 已知问题

| 问题 | 影响 | 状态 |
| --- | --- | --- |
| 休眠/唤醒 | 未测试 | — |
| PCIe2 (5G modem) | 未适配 | 主线没有对应 MHI 配置 |
| 厂商的 `reboot-daemon` 行为 | 无（那是厂商 rootfs 的服务） | 本仓库的 Debian rootfs 不含 |

## 固件

rootfs 里**预装**了这块板需要的固件，不需要手动补：

| 固件包 | 内容 | 用途 |
| --- | --- | --- |
| `firmware-realtek` | `rtl_nic/rtl8168h-2.fw` 等 | PCIe1 上两颗 RTL8168（rev15 = `RTL_GIGA_MAC_VER_46`）|
| `firmware-qcom-soc` | `qcom/sm8250/*`、`qcom/a650_*` | QCA6390 WiFi/BT、Adreno A650、ADSP/CDSP |
| `firmware-linux-nonfree` | 其它 SoC 相关 | 兜底 |
| `firmware-linux-free` | 自由许可固件 | 基础集 |

`scripts/build-rootfs.sh` 里有一步硬校验：如果 `rtl_nic/rtl8168h-2.fw` 或
`qcom/sm8250/*` 没装进去会直接让构建失败，不会悄悄出一个"少固件"的镜像。

为什么需要 `rtl8168h-2.fw`：内核 `r8169` 驱动对 rev15 的 RTL8168 会请求这个固件
做 PHY 参数调整。缺了它网卡**能**起来，但会退回降级配置（速率/信号余量变差）。

Debian 13 把固件装在 `/usr/lib/firmware`，构建脚本会自动补一个
`/lib/firmware -> usr/lib/firmware` 的符号链接，兼容老路径。

## 上游参考

- Armbian board config：`config/boards/dg-svr-865-tiny.conf`
- Armbian sm8250 family：`config/sources/families/sm8250.conf`
- 上游设备树：`patch/kernel/archive/sm8250-6.18/dt/qcs8250-dg-svr-865-tiny.dts`

> 上面这些是 **上游**（armbian/build）里的真实路径，板名是 `dg-svr-865-tiny`。
> 本仓库的镜像名 `nico-debian-sm8250` 只是本地命名，不影响上游引用。
