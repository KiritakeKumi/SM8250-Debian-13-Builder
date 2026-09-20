# 刷机步骤（nico-debian-sm8250 / QRB5165）

> 前提：你已经能进 **fastboot**（USB 枚举为 fastboot 设备）。
> 如果板子卡在 EDL / QUSB ramdump 模式，先按住 PWR 键冷启动，或参考文末"救砖"。

---

## 0. 先搞清楚分区

这块板的 UFS 是 **LUN 0**（rootfs）和 **LUN 4**（boot/abl/xbl/...）。

| 分区 | 位置 | 用途 |
| --- | --- | --- |
| `rootfs` | LUN0，从 sector 6 开始 | 整个根文件系统，**没有分区表** |
| `boot_a` / `boot_b` | LUN4 | Android boot 镜像（内核+DTB+initramfs） |
| `hyp_a` / `hyp_b` | LUN4 | hypervisor（刷 u-boot 时替换它来支持 KVM） |

查看当前 slot：`fastboot getvar current-slot`

---

> **从 GitHub Release 下载的话，rootfs 是 `.img.gz`，先解压**：
>
> ```bash
> gunzip -k nico-debian-sm8250-trixie.rootfs.img.gz
> ```
>
> Release 单个附件上限 2 GiB，所以只能放压缩版；原始 `.img` 在 Actions artifact 里。

## 1. 刷 rootfs

```bash
fastboot flash rootfs nico-debian-sm8250-trixie.rootfs.img
```

这个分区有 12G 左右，镜像本身是 6G 默认大小，写完后第一次启动会自动扩展不必要 ——
因为 fstab 里用的是 `root=UUID=`，**不要**手动 resize 或改 UUID，否则开不了机。

## 2. 刷 boot

```bash
# 当前 slot
fastboot flash boot nico-debian-sm8250-trixie.boot.img

# 或者明确指定 slot
fastboot flash boot_a nico-debian-sm8250-trixie.boot.img
fastboot flash boot_b nico-debian-sm8250-trixie.boot.img
```

> `boot-recovery.img` 是同内容的备用镜像，正常不需要刷。

## 3. 重启

```bash
fastboot reboot
```

串口（`ttyMSM0`，115200 8N1）应该能看到内核日志和登录提示。

- 用户名：`root` / 密码：你在 workflow 里填的（默认 `root`）
- 普通用户：`debian` / 密码 `debian`，可以 `sudo`（免密码）

---

## 4. 只试不刷（RAM boot）

不想动 UFS 的时候，可以直接把 boot 镜像丢进内存启动：

```bash
fastboot boot nico-debian-sm8250-trixie.boot.img
```

注意：这样启动时 `root=` 的 UUID 还是镜像里的 rootfs，所以 **必须先把 rootfs 刷进去**，
否则会因为找不到根分区掉进 initramfs 的 shell。

---

## 5. 刷 u-boot 以支持 KVM（可选）

想跑 KVM / PVE 的话，把 `hyp` 分区换成 u-boot：

```bash
fastboot flash hyp u-boot.mbn
fastboot reboot
```

```bash
fastboot fetch hyp hyp-backup.img     # 如果 bootloader 支持 fetch
```

---

## 常见问题

**Q: 刷完起不来，串口没有任何输出？**
检查 `boot.img` 的 cmdline 是不是被截断了（board bootloader 只转发 ~511 字节）。
本仓库的 `build-bootimg.sh` 会在超长时直接报错，所以正常不会踩到。

**Q: 起来了但是没有 eth0/eth1？**
说明 `with_nic_fix` 没开，或者 `modules/tc-eb5/` 的模块没装进去。检查：

```bash
lsmod | grep tc-eb5
lspci -nn | grep '^0001:'
dmesg | grep -iE 'tc-eb5|asm2806|r8169'
```

**Q: 根分区挂不上，掉进 initramfs shell？**
`root=UUID=` 和你刷进去的 rootfs 不匹配。用 `blkid` 看一下实际 UUID，重新生成 boot.img。

**Q: 有线网口是 `eth2`/`eth3` 而不是 `eth0`/`eth1`？**
主线上 RTL8168 的枚举顺序可能变化。`systemd-networkd` 的 `.network` 文件是按名字匹配的，
如果名字不对就 `ip -br a` 看实际名字，然后改 `/etc/systemd/network/`。
