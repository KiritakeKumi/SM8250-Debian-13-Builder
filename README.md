# nico-debian-sm8250 — Debian 13 系统构建仓库

用 GitHub Actions 给 **QRB5165 / SM8250 板子（12G + UFS）** 构建可刷写的 Debian 13 系统镜像。

> 镜像名称 / 主机名等统一由 `config/image.conf` 里的 `IMAGE_NAME` 控制，
> 当前为 `nico-debian-sm8250`。

产出物直接对应板子上 `fastboot flash boot` / `fastboot flash rootfs` 能用的文件：

| 产物 | 用途 | 刷写命令 |
| --- | --- | --- |
| `*-boot.img` | Android boot image（gzip 内核 + 追加 DTB + initramfs） | `fastboot flash boot <file>` |
| `*-boot-recovery.img` | 同上，给 recovery 槽用 | `fastboot flash boot <file>`（备用槽） |
| `*-rootfs.img` | ext4 根文件系统镜像 | `fastboot flash rootfs <file>` |

---

## 快速开始

1. Fork 或使用本仓库。
2. 打开 **Actions** → 左侧 **Build Debian 13 Image** → **Run workflow**。
3. 按需填写参数（见下方"参数说明"），点 **Run workflow**。
4. 跑完后在 workflow 页面底部 **Artifacts** 下载 `boot-images` 和 `rootfs-image`。
5. 刷机（参考 `docs/FLASHING.md`）。

> 首次运行大约 **60–120 分钟**（内核全量编译）。之后命中缓存会快很多。

### 关于 CI 磁盘空间

GitHub 的 **arm64 runner 只有 14 GB 磁盘**（`ubuntu-24.04-arm`）。本流水线需要
约 8–10 GB，所以：

- 用 `scripts/free-disk-space.sh` 做清理，**没有**用第三方 action
  （`descriptinc/free-disk-space` 在 arm64 上会执行
  `apt-get remove google-chrome-stable`，那是 x86-only 包，会直接让 job 失败）。
- `mkrootfs-image.sh` 会在创建镜像前检查剩余空间，不够就明确报错而不是中途 ENOSPC。
- 如果还是空间不足：把 `rootfs_size_mb` 调小（最小 rootfs 约 1.5 GB，
  默认 6000 是给后续装东西留余量）。

---

## 参数说明

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `kernel_version` | `6.18.35` | 内核版本，取 kernel.org 的 tarball。**支持 7.x**，见下方说明 |
| `dtb_source` | `upstream-armbian` | 设备树来源：`upstream-armbian`（官方主线 DT）/ `upstream-vendor-dg`（本地快照）/ `custom`（`dts/custom/`） |
| `with_nic_fix` | `true` | 是否编译并安装树外网卡修复模块（ASM2806 + 双 RTL8168 枚举） |
| `rootfs_size_mb` | `6000` | rootfs 镜像大小（MiB）。必须 ≥ 板子 rootfs 分区实际大小 |
| `hostname` | `nico-sm8250` | 目标机主机名 |
| `root_password` | `root` | root 密码（首登会被要求改） |
| `enable_ssh` | `true` | 是否开启 sshd |
| `extra_packages` | 空 | 额外要装的包，空格分隔 |
| `make_default_user` | `true` | 创建普通用户 `debian`（密码 `debian`），并加入 sudo |
| `publish_release` | `false` | 手动触发时是否发布 release（push 触发时总是发布） |

### 关于 7.x 内核

`kernel_version` 填 `7.2` / `7.2.6` / `7.0` 等都可以。已验证过：

- 模块用到的 **60 个内核 API 在 7.2 上全部存在**
- `device_has_driver_override()` 在 7.0+ 原生就有（6.18 是靠 backport）
- `struct pci_dev.driver_override` 在 7.1 被移除 —— 我们的代码没用它，只用通用 helper
- 设备树在 7.2 头文件下**实际编译通过**（123058 字节，所有节点完整）
- 内核配置项在 7.2 上全部存在

**注意**：Armbian 只在 `sm8250-6.12` 和 `sm8250-6.18` 目录里带这块板的 DT，
没有 7.x 版本。所以 7.x 构建时 `fetch-dts.sh` 会自动回退到仓库内的快照
（`dts/nico-debian-sm8250.dts`），这份快照已验证能在 7.2 上编译。

> 7.x 的内核**还没在真机上启动验证过**。首次测试建议用
> `fastboot boot`（RAM boot）而不是刷写，这样出问题不影响现有系统。

---

## 产物怎么用

### boot.img 的结构

和板子上原有的 boot 镜像一致（Android boot header v0）：

```
[4096B header][gzip Image + appended DTB][initramfs (gzip cpio)]
```

- `kernel_addr = 0x8000`、`ramdisk_addr = 0x1000000`、`tags_addr = 0x100`、`page_size = 4096`
- 内核命令行由 `config/boot-cmdline.txt` 提供，`root=UUID=` 会在打包时自动替换成实际 rootfs 的 UUID。

### rootfs.img

- 单分区 ext4，直接写进 UFS 的 `rootfs` 分区。
- 内部已装好内核、DTB、initramfs、固件、systemd 服务。
- UUID 会写进 `boot.img` 的 cmdline，**不要**手动改 UUID。

---

## 目录结构

```
.github/workflows/build.yml     GitHub Actions 主流水线
config/
  image.conf                    镜像名 / DT 文件名 / 上游 DT 地址
  boot-cmdline.txt              内核命令行模板（root=UUID= 自动替换）
  kernel-base.config            内核基线 defconfig
  kernel-fragment.config        内核配置片段（覆盖在基线之上）
  packages.txt                  rootfs 额外软件包清单
dts/
  README.md                     设备树来源说明
  nico-debian-sm8250.dts        本地设备树快照（dtb_source=upstream-vendor-dg 时用）
  patches/nic-fix-overlay.dtsi  网卡修复叠加层（with_nic_fix=true 时追加）
  custom/                       你自己放设备树的地方（dtb_source=custom）
modules/
  tc-eb5/                       树外网卡修复模块（可选编译）
scripts/
  fetch-kernel.sh               下载内核源码
  fetch-dts.sh                  拉取/准备设备树
  build-kernel.sh               内核 + DTB + initramfs
  build-modules.sh              树外模块编译
  build-rootfs.sh               rootfs（debootstrap）构建
  mkrootfs-image.sh             rootfs → ext4 镜像
  build-bootimg.sh              打包 Android boot image
  check-dts.sh                  设备树离线校验
  validate.sh                   仓库/脚本静态校验
  free-disk-space.sh            CI 上清理磁盘（arm64 安全）
docs/
  FLASHING.md                   刷机步骤
  HARDWARE.md                   硬件与已知问题
```

---

## 本地构建

流水线里所有脚本都是普通的 bash 脚本，本地 Linux（含 WSL2、容器）也能直接跑：

```bash
# 需要在 arm64 机器上跑（x86 上要额外装 qemu-user-static + binfmt）
sudo apt-get install -y build-essential bc bison flex libssl-dev libelf-dev \
    device-tree-compiler debootstrap busybox-static \
    gdisk e2fsprogs android-sdk-libsparse-utils \
    python3 python3-pip

export WORKSPACE=$PWD/work
export KERNEL_VERSION=6.18.35
export DTB_SOURCE=upstream-armbian
export WITH_NIC_FIX=true
export ROOTFS_SIZE_MB=6000
export RELEASE_NAME=trixie

bash scripts/fetch-kernel.sh
bash scripts/fetch-dts.sh
bash scripts/build-kernel.sh
bash scripts/build-modules.sh   # 仅当 WITH_NIC_FIX=true
bash scripts/build-rootfs.sh    # 需要 root，会自动 sudo 提权
bash scripts/mkrootfs-image.sh  # 需要 root，会自动 sudo 提权
bash scripts/build-bootimg.sh
```

> `build-rootfs.sh`（debootstrap/chroot）和 `mkrootfs-image.sh`（loop mount + mkfs）
> 需要 root。这两个脚本会**自己调用 sudo 重新执行**，并把配置通过
> `sudo env VAR=...` 传进去，所以直接 `bash scripts/build-rootfs.sh` 就行。
> 其它脚本不需要 root。

产物在 `work/out/`：

```
nico-debian-sm8250-trixie.boot.img
nico-debian-sm8250-trixie.boot-recovery.img
nico-debian-sm8250-trixie.rootfs.img
```

---

## 已知问题 / 边界

- **有线网卡需要树外模块**：主线 `qcom-pcie` 驱动在这块板上不会自己驱动 ASM2806 的电源/复位时序，`with_nic_fix=true` 时会额外编一个模块来做 GPIO 时序 + PERST 提供者 + 延迟绑定。详见 `docs/HARDWARE.md`。
- 未验证：休眠/唤醒、冷启动多次循环、真实网络吞吐。
- `rtl_nic/rtl8168h-2.fw` 缺失会导致 RTL8168 只能跑到降级速率（不影响连通）。
- 本仓库不包含任何厂商固件/引导链（xbl、abl、tz、hyp 等），那些需要用底包单独刷。
- **7.x 内核还没在真机上启动验证过**（只验证了能编译、API 齐全、配置项都在）。

## 致谢

**本仓库打包的板级支持代码来自别人的工作，不是我们写的。** 详见
[`CREDITS.md`](CREDITS.md)，摘要：

| 来源 | 内容 | 许可 |
| --- | --- | --- |
| [**Evsio0n/tc-eb5-oot**](https://github.com/evsio0n/tc-eb5-oot) v0.2.1 | `modules/tc-eb5/` 的两个模块 + `dts/patches/nic-fix-overlay.dtsi` | GPL-2.0-only / BSD-3-Clause |
| [**armbian/build**](https://github.com/armbian/build) | 设备树 `qcs8250-dg-svr-865-tiny.dts`（维护者 FantasyGmm） | BSD-3-Clause |
| 实际部署的板子 | `config/kernel-base.config`（从 `/proc/config.gz` 导出） | GPL-2.0 |
| [ztelliot 的 gist](https://gist.github.com/ztelliot/d8962d106da85d56176b463c47add079) | EL2/KVM + DSP 支持方案（**参考，未并入**） | — |

**特别感谢 Evsio0n** —— 这块板子上 ASM2806 + 双 RTL8168 能用，靠的就是
`tc-eb5-oot` 那套 GPIO 时序和 PERST provider。本仓库只是把它接进了一条
自动构建流水线。上游的实测结论（Gen3 x2、AER 零、DHCP + SSH 跑通）见
`CREDITS.md`。

## 许可

- 本仓库脚本、workflow：GPL-3.0（见 `LICENSE`）
- `modules/tc-eb5/` 内的树外模块：GPL-2.0-only（来自 Evsio0n/tc-eb5-oot）
- `dts/nico-debian-sm8250.dts`：BSD-3-Clause（来自 armbian/build）
- `dts/patches/nic-fix-overlay.dtsi`：BSD-3-Clause（派生自 tc-eb5.dts）
- `scripts/mkbootimg.py`：GPL-3.0（本仓库原创，格式参考 AOSP mkbootimg）
