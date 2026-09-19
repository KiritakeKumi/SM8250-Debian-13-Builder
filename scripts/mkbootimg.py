#!/usr/bin/env python3
"""Pack an Android boot image (header version 0).

Self-contained: no mkbootimg / abootimg needed. The layout was verified by
parsing the board's own boot.img and re-reading every field.

Layout for header_version 0:

    offset  size  field
    ------  ----  -------------------------------------------------
    0       8     "ANDROID!" magic
    8       4     kernel_size          (bytes, unpadded)
    12      4     kernel_addr
    16      4     ramdisk_size         (bytes, unpadded)
    20      4     ramdisk_addr
    24      4     second_size
    28      4     second_addr
    32      4     tags_addr
    36      4     page_size
    40      4     header_version
    44      4     os_version
    48      16    product name (NUL padded)
    64      512   cmdline (NUL padded)
    576     32    id (sha1 digest, zero padded)
    608     1024  extra cmdline (NUL padded)

Followed by, each padded to page_size:
    kernel, ramdisk, second

The board uses: kernel_addr 0x8000, ramdisk_addr 0x1000000, tags_addr 0x100,
second_offset 0x00f00000, page_size 4096, header_version 0.
"""
import argparse
import hashlib
import os
import struct
import sys

BOOT_MAGIC = b'ANDROID!'
BOOT_MAGIC_SIZE = 8
BOOT_NAME_SIZE = 16
BOOT_ARGS_SIZE = 512
BOOT_EXTRA_ARGS_SIZE = 1024


def filesize(path):
    return os.path.getsize(path) if path else 0


def pad_len(n, page):
    return (page - (n & (page - 1))) & (page - 1)


def write_padded(out, path, page):
    """Copy `path` into `out`, then pad out to a page boundary."""
    if not path:
        return
    with open(path, 'rb') as f:
        data = f.read()
    out.write(data)
    out.write(b'\0' * pad_len(len(data), page))


def build(args):
    if args.header_version != 0:
        sys.exit('this packer only writes header_version 0')

    ksize = filesize(args.kernel)
    rsize = filesize(args.ramdisk)
    ssize = filesize(args.second)

    kernel_addr = args.base + args.kernel_offset
    ramdisk_addr = (args.base + args.ramdisk_offset) if rsize else 0
    second_addr = (args.base + args.second_offset) if ssize else 0
    tags_addr = args.base + args.tags_offset

    # id = sha1(kernel || ramdisk || second), per AOSP mkbootimg for v0.
    sha = hashlib.sha1()
    for p in (args.kernel, args.ramdisk, args.second):
        if p:
            with open(p, 'rb') as f:
                sha.update(f.read())
    img_id = sha.digest()  # 20 bytes; packed into a 32-byte field

    cmdline = args.cmdline.encode()
    if len(cmdline) > BOOT_ARGS_SIZE:
        sys.exit(f'cmdline is {len(cmdline)} bytes, max {BOOT_ARGS_SIZE}')
    extra = args.extra_cmdline.encode()
    if len(extra) > BOOT_EXTRA_ARGS_SIZE:
        sys.exit(f'extra cmdline is {len(extra)} bytes, max {BOOT_EXTRA_ARGS_SIZE}')
    board = args.board.encode()
    if len(board) > BOOT_NAME_SIZE:
        sys.exit(f'board name is {len(board)} bytes, max {BOOT_NAME_SIZE}')

    with open(args.output, 'wb') as out:
        out.write(struct.pack(f'<{BOOT_MAGIC_SIZE}s', BOOT_MAGIC))
        out.write(struct.pack('<I', ksize))
        out.write(struct.pack('<I', kernel_addr))
        out.write(struct.pack('<I', rsize))
        out.write(struct.pack('<I', ramdisk_addr))
        out.write(struct.pack('<I', ssize))
        out.write(struct.pack('<I', second_addr))
        out.write(struct.pack('<I', tags_addr))
        out.write(struct.pack('<I', args.pagesize))
        out.write(struct.pack('<I', args.header_version))
        out.write(struct.pack('<I', (args.os_version << 11) | args.os_patch_level))
        out.write(struct.pack(f'<{BOOT_NAME_SIZE}s', board))
        out.write(struct.pack(f'<{BOOT_ARGS_SIZE}s', cmdline))
        out.write(struct.pack('<32s', img_id))
        out.write(struct.pack(f'<{BOOT_EXTRA_ARGS_SIZE}s', extra))

        # The header is exactly 1632 bytes for v0:
        #   8 magic + 10 * 4 (u32 fields) + 16 name + 512 cmdline
        #   + 32 id + 1024 extra_cmdline
        # Then pad to one page.
        header_len = (8
                      + 4 * 10          # kernel/ramdisk/second size+addr,
                                        # tags, page_size, header_version,
                                        # os_version
                      + BOOT_NAME_SIZE
                      + BOOT_ARGS_SIZE
                      + 32
                      + BOOT_EXTRA_ARGS_SIZE)
        if header_len > args.pagesize:
            sys.exit(f'header ({header_len} B) exceeds page size ({args.pagesize})')
        out.write(b'\0' * (args.pagesize - header_len))

        write_padded(out, args.kernel, args.pagesize)
        write_padded(out, args.ramdisk, args.pagesize)
        write_padded(out, args.second, args.pagesize)

    return ksize, rsize, ssize, img_id


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--kernel', required=True)
    p.add_argument('--ramdisk', required=True)
    p.add_argument('--second', default=None)
    p.add_argument('--output', required=True)
    p.add_argument('--cmdline', default='')
    p.add_argument('--extra-cmdline', default='')
    p.add_argument('--board', default='')
    p.add_argument('--base', type=lambda x: int(x, 0), default=0)
    p.add_argument('--kernel-offset', type=lambda x: int(x, 0), default=0x8000)
    p.add_argument('--ramdisk-offset', type=lambda x: int(x, 0), default=0x1000000)
    p.add_argument('--second-offset', type=lambda x: int(x, 0), default=0x00f00000)
    p.add_argument('--tags-offset', type=lambda x: int(x, 0), default=0x100)
    p.add_argument('--pagesize', type=int, default=4096)
    p.add_argument('--header-version', type=int, default=0)
    p.add_argument('--os-version', type=int, default=0)
    p.add_argument('--os-patch-level', type=int, default=0)
    args = p.parse_args()

    ksize, rsize, ssize, img_id = build(args)
    print(f'  wrote {args.output}')
    print(f'    kernel  {ksize:>10} bytes')
    print(f'    ramdisk {rsize:>10} bytes')
    if ssize:
        print(f'    second  {ssize:>10} bytes')
    print(f'    id      {img_id.hex()}')


if __name__ == '__main__':
    main()
