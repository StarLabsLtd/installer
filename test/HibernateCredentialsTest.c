/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include "OwnerCredentials.h"
#include <gio/gio.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const char root_key[] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
static const char hib_key[] = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

static int record_fd (const void *data, size_t length, gboolean seal) {
    int fd = memfd_create ("test-credential", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    g_assert_cmpint (fd, >=, 0);
    g_assert_cmpint (write (fd, data, length), ==, length);
    if (seal) g_assert_cmpint (fcntl (fd, F_ADD_SEALS,
        F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL), ==, 0);
    return fd;
}

static void validate (int owner, int root, int hib, gboolean expected) {
    GError *error = NULL;
    char *username = NULL;
    guint64 offset, size;
    g_assert_cmpint (vale_credentials_validate (owner, root, hib, "fixture",
        &username, &offset, &size, &error), ==, expected);
    if (expected) {
        g_assert_no_error (error);
        g_assert_cmpstr (username, ==, "owner");
        char password[512] = {0};
        g_assert_cmpint (pread (owner, password, size, offset), ==, size);
        g_assert_cmpstr (password, ==, "quartzLemon!47.Nebula");
    } else {
        g_assert_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT);
        g_assert_null (username);
        g_assert_cmpuint (size, ==, 0);
    }
    g_free (username);
    g_clear_error (&error);
}

static void custody (void) {
    GError *error = NULL;
    int owner = vale_owner_credentials_fd ("owner", "Test User", "fixture", "quartzLemon!47.Nebula", &error);
    g_assert_no_error (error);
    int root = vale_recovery_fd (root_key, &error);
    g_assert_no_error (error);
    int hib = vale_recovery_fd (hib_key, &error);
    g_assert_no_error (error);
    validate (owner, root, hib, TRUE);
    int alias = dup (root);
    validate (owner, root, alias, FALSE);
    close (alias);
    int identical = vale_recovery_fd (root_key, &error);
    g_assert_no_error (error);
    validate (owner, root, identical, FALSE);
    close (identical);
    validate (owner, root, owner, FALSE);

    char record[] = "owner\0Test User\0fixture\0quartzLemon!47.Nebula";
    char actual[sizeof record];
    g_assert_cmpint (pread (owner, actual, sizeof actual, 0), ==, sizeof actual);
    g_assert_cmpmem (actual, sizeof actual, record, sizeof record);
    int extra = record_fd (record, sizeof record - 1, TRUE);
    validate (extra, root, hib, FALSE); /* final NUL remains mandatory */
    close (extra);

    char invalid[65];
    memcpy (invalid, hib_key, sizeof invalid);
    for (int i = 0; i < 5; i++) {
        size_t length = 64;
        memcpy (invalid, hib_key, sizeof invalid);
        if (i == 0) length = 63;
        if (i == 1) { invalid[64] = '\n'; length = 65; }
        if (i == 2) invalid[0] = 'F';
        if (i == 3) invalid[30] = 0;
        int bad = record_fd (invalid, length, i != 4);
        validate (owner, root, bad, FALSE);
        close (bad);
    }
    int pipes[2];
    g_assert_cmpint (pipe (pipes), ==, 0);
    validate (owner, root, pipes[0], FALSE);
    close (pipes[0]); close (pipes[1]);

    const char password[] = "4e6c94f8a90737d597462841bb1c674209fa2a43d8c570e3837b164c529ed20a";
    g_assert_true (vale_owner_password_valid ("owner", password));
    int same_owner = vale_owner_credentials_fd ("owner", "Test User", "fixture", password, &error);
    int same_hib = vale_recovery_fd (password, &error);
    g_assert_no_error (error);
    validate (same_owner, root, same_hib, FALSE);
    close (same_owner); close (same_hib);
    close (owner); close (root); close (hib);
}

static void bootstrap (void) {
    GError *error = NULL;
    int first = vale_hibernate_bootstrap_fd (&error);
    int second = vale_hibernate_bootstrap_fd (&error);
    g_assert_no_error (error);
    unsigned char a[33], b[33];
    g_assert_cmpint (pread (first, a, sizeof a, 0), ==, 32);
    g_assert_cmpint (pread (second, b, sizeof b, 0), ==, 32);
    g_assert_cmpint (memcmp (a, b, 32), !=, 0);
    const int seals = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL;
    g_assert_cmpint (fcntl (first, F_GET_SEALS) & seals, ==, seals);
    g_assert_cmpint (write (first, "x", 1), ==, -1);
    close (first); close (second);
}

int main (int argc, char **argv) {
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/hibernate/credential-custody", custody);
    g_test_add_func ("/hibernate/bootstrap", bootstrap);
    return g_test_run ();
}
