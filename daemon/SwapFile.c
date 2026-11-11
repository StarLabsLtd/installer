/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "SwapFile.h"

#include <errno.h>
#include <linux/fiemap.h>
#include <linux/fs.h>
#include <linux/magic.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

int
vale_swapfile_allocate (int fd, uint64_t size)
{
    struct stat st;
    struct statfs fs;
    char zeros[1024 * 1024] = {0};
    long page = sysconf (_SC_PAGESIZE);

    if (fstat (fd, &st) < 0 || fstatfs (fd, &fs) < 0)
        return -1;
    if (!S_ISREG (st.st_mode) || st.st_size != 0 || st.st_nlink != 1 ||
        st.st_uid != geteuid () || (st.st_mode & 0777) != 0600 ||
        fs.f_type != EXT4_SUPER_MAGIC || page <= 0 ||
        size < (uint64_t) page * 2 || size > INT64_MAX || size % page) {
        errno = EINVAL;
        return -1;
    }

    /* Write all pages: holes and unwritten extents must not escape qualification. */
    for (uint64_t written = 0; written < size;) {
        size_t chunk = size - written < sizeof zeros ? size - written : sizeof zeros;
        ssize_t n = pwrite (fd, zeros, chunk, written);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            if (n == 0) errno = EIO;
            return -1;
        }
        written += n;
    }
    return fsync (fd);
}

int
vale_swapfile_offset (int fd, uint64_t size, uint64_t *offset)
{
    struct stat st;
    struct statfs fs;
    struct {
        struct fiemap map;
        struct fiemap_extent extents[64];
    } batch;
    uint64_t end = 0;
    long page = sysconf (_SC_PAGESIZE);

    if (fstat (fd, &st) < 0 || fstatfs (fd, &fs) < 0 || fsync (fd) < 0)
        return -1;
    if (!S_ISREG (st.st_mode) || st.st_size < 0 || (uint64_t) st.st_size != size ||
        fs.f_type != EXT4_SUPER_MAGIC || page <= 0 || size == 0 || size % page) {
        errno = EINVAL;
        return -1;
    }

    while (end < size) {
        memset (&batch, 0, sizeof batch);
        batch.map.fm_start = end;
        batch.map.fm_length = size - end;
        batch.map.fm_flags = FIEMAP_FLAG_SYNC;
        batch.map.fm_extent_count = 64;
        if (ioctl (fd, FS_IOC_FIEMAP, &batch) < 0)
            return -1;
        if (!batch.map.fm_mapped_extents || batch.map.fm_mapped_extents > 64)
            goto invalid;
        for (unsigned i = 0; i < batch.map.fm_mapped_extents; i++) {
            struct fiemap_extent *e = &batch.extents[i];
            if (e->fe_logical != end || !e->fe_length ||
                e->fe_length > size - end || !e->fe_physical ||
                e->fe_physical % page || e->fe_length % page ||
                (e->fe_flags & ~FIEMAP_EXTENT_LAST))
                goto invalid;
            if (end == 0) *offset = e->fe_physical / page;
            end += e->fe_length;
            if ((e->fe_flags & FIEMAP_EXTENT_LAST) && end != size)
                goto invalid;
        }
    }
    return 0;

invalid:
    errno = EINVAL;
    return -1;
}
