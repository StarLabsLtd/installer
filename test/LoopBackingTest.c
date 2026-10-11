/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "LoopBacking.h"

#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <unistd.h>

static void
invalid_status (void)
{
    dev_t device = 0;
    g_assert_cmpint (vale_loop_backing_device (-1, &device), ==, -1);
    g_assert_cmpint (errno, ==, EBADF);

    int fd = open ("/dev/null", O_RDONLY | O_CLOEXEC);
    g_assert_cmpint (fd, >=, 0);
    g_assert_cmpint (vale_loop_backing_device (fd, &device), ==, -1);
    g_assert_cmpint (errno, ==, ENOTTY);
    close (fd);
}

static void
backing_identity (void)
{
    const char *path = g_getenv ("VALE_TEST_LOOP_DEVICE");
    const char *expected = g_getenv ("VALE_TEST_BACKING_DEVICE");
    if (!path || !expected) {
        g_test_skip ("Requires a configured loop device and its backing dev_t");
        return;
    }

    int fd = open (path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    g_assert_cmpint (fd, >=, 0);
    dev_t device = 0;
    g_assert_cmpint (vale_loop_backing_device (fd, &device), ==, 0);
    close (fd);
    g_assert_cmpuint (device, ==, g_ascii_strtoull (expected, NULL, 10));
}

static void
unbound_status (void)
{
    const char *path = g_getenv ("VALE_TEST_UNBOUND_LOOP_DEVICE");
    if (!path) {
        g_test_skip ("Requires an unbound loop device");
        return;
    }

    int fd = open (path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    g_assert_cmpint (fd, >=, 0);
    dev_t device = 0;
    g_assert_cmpint (vale_loop_backing_device (fd, &device), ==, -1);
    g_assert_cmpint (errno, ==, ENXIO);
    close (fd);
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/loop/invalid-status", invalid_status);
    g_test_add_func ("/loop/backing-identity", backing_identity);
    g_test_add_func ("/loop/unbound-status", unbound_status);
    return g_test_run ();
}
