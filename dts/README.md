# 设备树来源

`dtb_source` 参数决定用哪个设备树。三种模式：

> 本仓库里设备树的**文件名**由 `config/image.conf` 的 `DTS_FILE` 决定，
> 当前是 `nico-debian-sm8250.dts`。上游 Armbian 那边的原始文件名是
> `qcs8250-dg-svr-865-tiny.dts`（板名 `dg-svr-865-tiny`），拉下来之后
> 会存成本仓库的名字。

## `upstream-armbian`（默认，推荐）

从 Armbian 官方仓库实时拉取这块板的主线设备树：

```
https://raw.githubusercontent.com/armbian/build/main/patch/kernel/archive/sm8250-6.18/dt/qcs8250-dg-svr-865-tiny.dts
```

这是维护者 FantasyGmm 维护的、和 Armbian 官方镜像用的是同一份 DT。
好处是上游更新会自动跟上；坏处是网络不可用时构建会失败。
URL 可以在 `config/image.conf` 里改。

## `upstream-vendor-dg`

用本仓库 `dts/nico-debian-sm8250.dts`（就是上面那份的本地快照）。
构建完全离线可复现，不依赖 GitHub 可用性。

## `custom`

用 `dts/custom/` 目录里你自己放的文件。

要求：

- 必须有一个文件叫 `nico-debian-sm8250.dts`（名字来自 `DTS_FILE`，这是编译入口）
- 其它 `.dtsi` 可以一起放进去，会被 `#include` 找到
- 如果要用到内核的 `sm8250.dtsi` / `pm8150*.dtsi`，直接 `#include "sm8250.dtsi"` 即可，
  构建脚本已经把内核的 `arch/arm64/boot/dts/qcom` 加进了 include 路径

## 网卡修复叠加层

`with_nic_fix=true` 时，构建脚本会把 `dts/patches/nic-fix-overlay.dtsi` **追加**到
选定的设备树后面。它做的事情：

1. 把 `&pcie1` / `&pcie1_phy` 打开（`status = "okay"`）
2. 加 `pcie1-sequencer` 节点（`thundercomm,tc-eb5-pcie-sequencer`），
   声明 GPIO 82/88/89/121/127/126
3. 把 `&pcie1` 的 `perst-gpios` 指向那个 provider
4. 加 `pcie1_asm2806_controls_default` / `pcie1_lan1_pullup` pinctrl
5. 给 `&pcie1` 补上 9 条 per-BDF `iommu-map`（SID `0x1c80`–`0x1c88`）
6. 给根节点加 `thundercomm,eb5` compatible（模块靠这个自检板型）

## 为什么不用厂商反编译的那份 DT

`current.dts` / `vendor.dts`（两份是同一份，30927 行）是**厂商 4.19 内核**的 DT，
从运行中的设备反编译出来的：

- 节点 compatible 是 `qcom,pci-msm` 这类**厂商私有值**（主线是 `qcom,pcie-sm8250`）
- 用了 `use-pcie-bridge-asm2806` / `wake-lan1-gpio` 这类**只有厂商驱动认识**的属性
- 里面大量 phandle 是反编译出来的数字（`<0x76>` 这种），没有 label

主线内核基本认不出它的 PCIe/USB/时钟节点，直接拿来用会开不了机。
它更适合当**参考资料**（比如查 GPIO 编号、查 pinctrl 配置），而不是直接编译。

## 离线校验

```bash
# 需要一个内核源码树（提供 sm8250.dtsi 和 dt-bindings）
bash scripts/check-dts.sh /path/to/linux
```

CI 里有一个独立的 `validate-dts` job 会先跑这一步，DTS 编不过就不会浪费
一小时去编内核。
