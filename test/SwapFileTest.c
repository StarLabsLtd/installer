/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "SwapFile.h"

#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <linux/magic.h>
#include <sys/vfs.h>
#include <unistd.h>

static void
allocation_and_offset (void)
{
    char *path = NULL;
    int fd = g_file_open_tmp ("vale-swap-XXXXXX", &path, NULL);
    g_assert_cmpint (fd, >=, 0);
    struct statfs fs;
    g_assert_cmpint (fstatfs (fd, &fs), ==, 0);
    if (fs.f_type != EXT4_SUPER_MAGIC) {
        g_test_skip ("Requires an ext4 temporary directory");
        goto out;
    }
    uint64_t size = 16 * 1024 * 1024;
    uint64_t offset = 0;
    g_assert_cmpint (ftruncate (fd, size), ==, 0);
    g_assert_cmpint (vale_swapfile_offset (fd, size, &offset), ==, -1);
    g_assert_cmpint (ftruncate (fd, 0), ==, 0);
    g_assert_cmpint (vale_swapfile_allocate (fd, size), ==, 0);
    g_assert_cmpint (vale_swapfile_offset (fd, size, &offset), ==, 0);
    g_assert_cmpuint (offset, >, 0);
    g_assert_cmpint (vale_swapfile_offset (fd, size + 4096, &offset), ==, -1);
    g_assert_cmpint (vale_swapfile_allocate (fd, size), ==, -1);
out:
    close (fd);
    unlink (path);
    g_free (path);
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/swap/allocation-and-offset", allocation_and_offset);
    return g_test_run ();
}
