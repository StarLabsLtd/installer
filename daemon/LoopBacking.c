/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "LoopBacking.h"

#include <errno.h>
#include <linux/loop.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/sysmacros.h>

int
vale_loop_backing_device (int fd, dev_t *device)
{
    struct loop_info64 info;
    if (ioctl (fd, LOOP_GET_STATUS64, &info) < 0)
        return -1;

    /* The ioctl uses Linux's huge_encode_dev, not libc's dev_t encoding. */
    unsigned long long encoded = info.lo_rdevice ? info.lo_rdevice : info.lo_device;
    unsigned int major = (encoded >> 8) & 0xfff;
    unsigned int minor = (encoded & 0xff) | ((encoded >> 12) & 0xfff00);
    *device = makedev (major, minor);
    return 0;
}

int
vale_loop_matches_partition (int loop_fd, int disk_fd, unsigned long long offset, unsigned long long size)
{
    struct loop_info64 info;
    struct stat disk;
    dev_t backing;

    if (fstat (disk_fd, &disk) < 0 || !S_ISBLK (disk.st_mode) ||
        ioctl (loop_fd, LOOP_GET_STATUS64, &info) < 0 ||
        vale_loop_backing_device (loop_fd, &backing) < 0)
        return -1;
    if (backing != disk.st_rdev || info.lo_offset != offset ||
        info.lo_sizelimit != size || (info.lo_flags & LO_FLAGS_READ_ONLY)) {
        errno = EINVAL;
        return -1;
    }
    return 0;
}
