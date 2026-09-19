#!/usr/bin/env python3
"""Self-test for scripts/mkbootimg.py.

Builds synthetic boot images and reads every header field back, so a broken
packer fails here instead of producing an unbootable board image.

Runs standalone:  python3 scripts/test-mkbootimg.py
"""
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PACKER = os.path.join(HERE, 'mkbootimg.py')

PAGE = 4096
BOARD_KERNEL_OFFSET = 0x8000
BOARD_RAMDISK_OFFSET = 0x1000000
BOARD_TAGS_OFFSET = 0x100
BOARD_SECOND_OFFSET = 0x00f00000


def pages(n, page=PAGE):
    return (n + page - 1) // page


def make_blob(path, size):
    with open(path, 'wb') as f:
        # deterministic content so the test is reproducible
        f.write(bytes((i * 7 + 3) & 0xff for i in range(size)))


def run_packer(kernel, ramdisk, out, cmdline, second=None, page=PAGE,
               hver=0, base=0):
    cmd = [
        sys.executable, PACKER,
        '--kernel', kernel,
        '--ramdisk', ramdisk,
        '--output', out,
        '--cmdline', cmdline,
        '--base', hex(base),
        '--kernel-offset', hex(BOARD_KERNEL_OFFSET),
        '--ramdisk-offset', hex(BOARD_RAMDISK_OFFSET),
        '--tags-offset', hex(BOARD_TAGS_OFFSET),
        '--second-offset', hex(BOARD_SECOND_OFFSET),
        '--pagesize', str(page),
        '--header-version', str(hver),
    ]
    if second:
        cmd += ['--second', second]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        raise SystemExit(f'packer failed with {r.returncode}')


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def test_basic(tmp):
    """Small odd-sized blobs: exercises page padding."""
    ksize, rsize = 12345, 6789
    k = os.path.join(tmp, 'k'); make_blob(k, ksize)
    r = os.path.join(tmp, 'r'); make_blob(r, rsize)
    out = os.path.join(tmp, 'basic.img')
    cmdline = 'console=ttyMSM0,115200n8 root=UUID=deadbeef'

    run_packer(k, r, out, cmdline)

    with open(out, 'rb') as f:
        data = f.read()

    expected_size = PAGE * (1 + pages(ksize) + pages(rsize))
    check(len(data) == expected_size,
          f'size {len(data)} != {expected_size}')
    check(pages(ksize) == 4 and pages(rsize) == 2,
          'test assumptions about page counts changed')

    h = data[:PAGE]
    check(h[:8] == b'ANDROID!', 'bad magic')
    got = struct.unpack_from('<II', h, 8)
    check(got == (ksize, BOARD_KERNEL_OFFSET), f'kernel field {got}')
    got = struct.unpack_from('<II', h, 16)
    check(got == (rsize, BOARD_RAMDISK_OFFSET), f'ramdisk field {got}')
    got = struct.unpack_from('<II', h, 24)
    check(got == (0, 0), f'second field {got}')
    tags, = struct.unpack_from('<I', h, 32)
    check(tags == BOARD_TAGS_OFFSET, f'tags {tags:#x}')
    page, = struct.unpack_from('<I', h, 36)
    check(page == PAGE, f'page size {page}')
    hver, = struct.unpack_from('<I', h, 40)
    check(hver == 0, f'header version {hver}')
    got = h[64:64+512].split(b'\0')[0].decode()
    check(got == cmdline, f'cmdline {got!r} != {cmdline!r}')

    # the payload must sit exactly where the header says
    koff = PAGE
    roff = koff + pages(ksize) * PAGE
    check(data[koff:koff+ksize] == open(k, 'rb').read(), 'kernel bytes differ')
    check(data[roff:roff+rsize] == open(r, 'rb').read(), 'ramdisk bytes differ')
    # padding must be zero
    check(data[koff+ksize:roff] == b'\0' * (roff - koff - ksize),
          'kernel padding is not zero')

    # id = sha1(kernel || ramdisk)
    want = hashlib.sha1(open(k, 'rb').read() + open(r, 'rb').read()).digest()
    check(h[576:596] == want, 'id mismatch')
    check(h[596:608] == b'\0' * 12, 'id field not zero-padded to 32 bytes')

    print(f'  OK   basic: {len(data)} bytes '
          f'(1 header + {pages(ksize)} kernel + {pages(rsize)} ramdisk pages)')


def test_page_aligned(tmp):
    """Blobs that are exact multiples of the page size need no extra page."""
    ksize, rsize = PAGE * 2, PAGE * 3
    k = os.path.join(tmp, 'ka'); make_blob(k, ksize)
    r = os.path.join(tmp, 'ra'); make_blob(r, rsize)
    out = os.path.join(tmp, 'aligned.img')
    run_packer(k, r, out, 'x')
    size = os.path.getsize(out)
    expected = PAGE * (1 + 2 + 3)
    check(size == expected, f'aligned size {size} != {expected}')
    print(f'  OK   page-aligned blobs: {size} bytes (no wasted page)')


def test_empty_ramdisk(tmp):
    """A zero-length ramdisk must record size 0 and load address 0."""
    k = os.path.join(tmp, 'ke'); make_blob(k, 5000)
    r = os.path.join(tmp, 're')
    open(r, 'wb').close()          # empty file
    out = os.path.join(tmp, 'noram.img')
    run_packer(k, r, out, 'x')
    with open(out, 'rb') as f:
        h = f.read(PAGE)
    rsize, raddr = struct.unpack_from('<II', h, 16)
    check(rsize == 0, f'ramdisk size {rsize}')
    check(raddr == 0, f'ramdisk addr {raddr:#x} (must be 0 when empty)')
    print(f'  OK   empty ramdisk: size=0 addr=0x0')


def test_cmdline_too_long(tmp):
    """An over-long cmdline must be rejected, not silently truncated."""
    k = os.path.join(tmp, 'kl'); make_blob(k, 100)
    r = os.path.join(tmp, 'rl'); make_blob(r, 100)
    out = os.path.join(tmp, 'long.img')
    r_ = subprocess.run(
        [sys.executable, PACKER, '--kernel', k, '--ramdisk', r,
         '--output', out, '--cmdline', 'A' * 600],
        capture_output=True, text=True)
    check(r_.returncode != 0, 'over-long cmdline was accepted')
    print('  OK   over-long cmdline rejected')


def test_second(tmp):
    """A second stage (unused by this board, but part of the format)."""
    k = os.path.join(tmp, 'ks'); make_blob(k, 3000)
    r = os.path.join(tmp, 'rs'); make_blob(r, 3000)
    s = os.path.join(tmp, 'ss'); make_blob(s, 3000)
    out = os.path.join(tmp, 'second.img')
    run_packer(k, r, out, 'x', second=s)
    with open(out, 'rb') as f:
        h = f.read(PAGE)
    ssize, saddr = struct.unpack_from('<II', h, 24)
    check(ssize == 3000, f'second size {ssize}')
    check(saddr == BOARD_SECOND_OFFSET, f'second addr {saddr:#x}')
    expected = PAGE * (1 + 1 + 1 + 1)
    check(os.path.getsize(out) == expected,
          f'second-stage size {os.path.getsize(out)} != {expected}')
    print(f'  OK   second stage: size={ssize} addr={saddr:#x}')


def main():
    print(f'self-testing {PACKER}')
    with tempfile.TemporaryDirectory() as tmp:
        test_basic(tmp)
        test_page_aligned(tmp)
        test_empty_ramdisk(tmp)
        test_cmdline_too_long(tmp)
        test_second(tmp)
    print('all packer self-tests passed')


if __name__ == '__main__':
    main()
