# Credits / 致谢

本仓库的构建流水线是自己写的，但**它打包的板级支持代码来自别人的工作**。
下面把来源和许可写清楚。

---

## Evsio0n/tc-eb5-oot — 板级 PCIe1 支持

<https://github.com/evsio0n/tc-eb5-oot>

> TC-EB5 / QRB5165 out-of-tree GPIO/PERST helper, PCIe late-bind gate and
> validated QMP PHY for Linux 6.13.12

**这是本仓库最关键的外部依赖。** 这块板子上的 ASM2806 PCIe switch + 两颗
RTL8168 网口，主线 `qcom-pcie` 驱动不会自己初始化 —— 需要一套精确的板级
GPIO 时序，以及一个把 PERST 暴露成 GPIO provider 的桥接层。这套东西是
Evsio0n 做出来并实测通过的。

### 本仓库用到的部分

| 本仓库路径 | 上游路径 | 说明 |
| --- | --- | --- |
| `modules/tc-eb5/eb5-board.c` | `modules/eb5-board.c` | GPIO 上电/复位时序 + PERST GPIO provider |
| `modules/tc-eb5/eb5-bind-gate.c` | `modules/eb5-bind-gate.c` | RTL8168 延迟绑定门（等原生 host probe 完成） |
| `modules/tc-eb5/eb5-bind-gate.h` | `modules/eb5-bind-gate.h` | |
| `modules/tc-eb5/Makefile` | `modules/Makefile` | 改为适配本仓库的构建方式 |
| `dts/patches/nic-fix-overlay.dtsi` | 派生自 `dts/tc-eb5.dts` | 只取 PCIe1 + sequencer + pinctrl 部分，重写为叠加层 |
| `config/kernel-fragment.config` | 参考 `config/kernel.config` | PCIe/PHY/IOMMU 相关选项 |

### 版本

对应上游 **v0.2.1**（release：`v0.2.1 - Linux 6.13.12`）。

上游 v0.2.0 有个 deferred-probe 输入生命周期的 bug 会导致 Oops，v0.2.1 修掉了
（改用 platform_data 指针副本 + NULL 保护）。本仓库用的是 v0.2.1。

### 上游的实测结果

来自上游 `TEST-RESULT.md` 与 README：

- 原生 PCIe host 完成绑定后，两颗 RTL8168 **同步绑定**（`async=0`）
- Gen3 x2，4 个 ASM2806 bridge function + 2 个 RTL8168 全部枚举
- 5 分钟 11 次采样，**AER 错误计数为 0**，无 WARN/Oops
- 后续在 A 槽持久化启动中，`eth0` 拿到 DHCP 租约并跑通 SSH

上游明确的边界：未测试冷启动多次循环、休眠/唤醒、以及真实吞吐压力。

### 许可

上游 `LICENSES/` 里是 **GPL-2.0** 和 **BSD-3-Clause**：

- `eb5-board.c` / `eb5-bind-gate.c` / `eb5-bind-gate.h` → **GPL-2.0-only**
  （本仓库保留了原始 SPDX 头和版权声明）
- `dts/tc-eb5.dts`（本仓库叠加层的来源）→ **BSD-3-Clause**

### 本仓库做的改动

为了适配 6.18 和 7.x 内核，对上游源码做了**最小改动**：

1. `eb5-board.c`：`gpio_chip::set` 的返回类型从 `void` 改为 `int`
   （Linux 6.15 起 gpiolib 允许 `set()` 失败）
2. `eb5-bind-gate.c`：`device_has_driver_override(dev)` 的调用方式保持上游写法
   —— 它在 7.0+ 原生存在，在 6.18.30+ 由稳定树 backport 提供
3. `Makefile`：改为 `make -C $KSRC O=$KDIR M=$PWD` 形式，适配本仓库的分离输出目录
4. 叠加层：把上游完整板级 DTS 里与 PCIe1 相关的部分重写为 `dts/patches/nic-fix-overlay.dtsi`，
   追加到 Armbian 维护的主线 DT 之后

**没有**引入上游的 `tc-eb5-qmp-pcie.c`（树外 QMP PHY）—— 本仓库用内核自带的
`phy-qcom-qmp-pcie` 驱动，因为实测那块板子在主线 PHY 驱动下能正常建链。

---

## Armbian — 板级设备树与内核配置基线

<https://github.com/armbian/build>

- **设备树**：`qcs8250-dg-svr-865-tiny.dts`，来自
  `patch/kernel/archive/sm8250-6.18/dt/`，维护者
  [FantasyGmm](https://github.com/FantasyGmm)
- **内核配置基线**：`config/kernel-base.config` 是从一台实际部署的
  DG-SVR-865-TINY（Armbian 26.5.1，`6.18.35-current-sm8250`）上
  `zcat /proc/config.gz` 导出的完整配置

上游板名是 `dg-svr-865-tiny`；本仓库产出的镜像名用 `nico-debian-sm8250`
（见 `config/image.conf`），两者指同一块板子。

---

## ztelliot — EL2 / DSP 支持（参考资料，未并入）

<https://gist.github.com/ztelliot/d8962d106da85d56176b463c47add079>

> `[PATCH] arm64: qcom: add DG SVR 865 Tiny with EL2 DSP support`

**这份补丁目前没有并入本仓库**，但它是"刷 u-boot 支持 KVM"这条路线的关键
参考，记录下来以免后人重复踩坑。

它的价值在于说明了一个**冲突**：把 `u-boot-hyp-12G.mbn` 刷进 `hyp` 分区会
替换 QHEE，于是

- CPU 从 EL2 启动 → `/dev/kvm` 出现（KVM 可用）✅
- 但 ADSP/CDSP 的 stage-2 页表原本由 QHEE 提供，现在没人提供 ❌

该补丁通过四件事补偿：

| 改动 | 作用 |
| --- | --- |
| 新增 `sm8250-dg-svr-865-tiny.dts`（524 行） | 给 adsp/cdsp 加 `iommus` 与 `linux,dst-el2-{adsp,cdsp}` 标记 |
| `arm-smmu.c` | 让被标记的 DSP 节点使用 stage-2 域（EL2 下 S1 归 hypervisor 管） |
| `qcom_q6v5_pas.c`（+500 行） | 静态资源表、stage-2 映射、CDSP/ADSP 上电序列 |
| `dst_{adsp,cdsp}_static_rsc.h` | 静态 resource table，替代 QHEE 提供的那份 |

作者实测结果（gist 里的 `result` 文件）：CDSP/ADSP 正常启动、
`/dev/fastrpc-*` 存在、GPU 与视频编解码器可用、`/dev/kvm` 存在。

**如果以后要做 KVM 支持，注意**：该补丁的检查是
`of_machine_is_compatible("dg,svr-865-tiny")`，而本仓库的 DT 用的是
`qcom,qrb5165-rb5`（Armbian 的 compatible），直接套用不会生效，需要调整。

---

## 工具与数据来源

- **内核源码**：<https://cdn.kernel.org/pub/linux/kernel/>
- **Linux 源码镜像**（7.x 设备树/头文件核对）：<https://github.com/gregkh/linux>
- **boot image 格式**：AOSP `system/tools/mkbootimg` 的
  [mkbootimg.py](https://android.googlesource.com/platform/system/tools/mkbootimg/)
  —— 本仓库的 `scripts/mkbootimg.py` 是按它的 header v0 布局重写的，
  并用板子自己的 `boot.img` 做了逐字节往返验证
- **板子实测日志**：一台实际部署的 DG-SVR-865-TINY（`172.16.11.29`），
  只读采集

---

## 许可汇总

| 内容 | 许可 |
| --- | --- |
| 本仓库的构建脚本、workflow | GPL-3.0（见 `LICENSE`） |
| `modules/tc-eb5/`（来自 Evsio0n） | GPL-2.0-only |
| `dts/nico-debian-sm8250.dts`（来自 Armbian） | BSD-3-Clause |
| `dts/patches/nic-fix-overlay.dtsi` | BSD-3-Clause（派生自 BSD-3-Clause 的 `tc-eb5.dts`） |
| `scripts/mkbootimg.py` | GPL-3.0（本仓库原创，格式参考 AOSP） |
