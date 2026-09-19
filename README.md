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
| `kernel_version` | `6.18.35` | 内核版本，取 kernel.org 的 tarball。可选 `6.18.52` / `6.12.110` 等 |
| `dtb_source` | `upstream-armbian` | 设备树来源：`upstream-armbian`（官方主线 DT）/ `upstream-vendor-dg`（厂商风格 DG DT）/ `custom`（用 `dts/` 目录里你自己放的文件） |
| `with_nic_fix` | `true` | 是否编译并安装树外网卡修复模块（ASM2806 + 双 RTL8168 枚举） |
| `rootfs_size_mb` | `6000` | rootfs 镜像大小（MiB）。必须 ≥ 板子 rootfs 分区实际大小 |
| `hostname` | `nico-sm8250` | 目标机主机名 |
| `root_password` | `root` | root 密码（首登会被要求改） |
| `enable_ssh` | `true` | 是否开启 sshd |
| `extra_packages` | 空 | 额外要装的包，空格分隔 |
| `make_default_user` | `true` | 创建普通用户 `debian`（密码 `debian`），并加入 sudo |

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

## 许可

- 本仓库脚本：GPL-3.0（见 `LICENSE`）
- `modules/tc-eb5/` 内的树外模块：GPL-2.0-only（各自文件头有声明）
- `dts/` 下的设备树：BSD-3-Clause（文件头有声明）
