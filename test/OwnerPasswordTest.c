/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "OwnerCredentials.h"
#include <gio/gio.h>
#include <unistd.h>
#include <string.h>

static void password_policy (void) {
    const gchar *passwords[] = {"InstalledOwnerFixture739!", "quartzLemon!47.Nebula"};
    for (guint i = 0; i < G_N_ELEMENTS (passwords); i++) {
        GError *error = NULL;
        gchar *username = NULL;
        guint64 offset, size;
        gboolean expected = i == 1;
        g_assert_cmpint (vale_owner_password_valid ("owner", passwords[i]), ==, expected);
        int owner = vale_owner_credentials_fd ("owner", "Test User", "fixture", passwords[i], &error);
        g_assert_no_error (error);
        int recovery = vale_recovery_fd ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", &error);
        g_assert_no_error (error);
        int hibernate = vale_recovery_fd ("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210", &error);
        g_assert_no_error (error);
        g_assert_cmpint (vale_credentials_validate (owner, recovery, hibernate, "fixture", &username, &offset, &size, &error), ==, expected);
        if (expected) {
            g_assert_no_error (error);
        } else {
            g_assert_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT);
        }
        g_clear_error (&error);
        g_free (username);
        close (owner);
        close (recovery);
        close (hibernate);
    }
}

static void password_feedback (void) {
    gchar *error = vale_owner_password_error ("star", "star-quart77!");
    g_assert_nonnull (error);
    g_assert_false (vale_owner_password_valid ("star", "star-quart77!"));
    g_assert_null (strstr (error, "star-quart77!"));
    g_free (error);
    g_assert_null (vale_owner_password_error ("sean", "star-quart77!"));
    g_assert_true (vale_owner_password_valid ("sean", "star-quart77!"));
    error = vale_owner_password_error ("sean", "short");
    g_assert_nonnull (error);
    g_assert_cmpstr (error, !=, "");
    g_free (error);
}

int main (int argc, char **argv) {
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/owner/password-policy", password_policy);
    g_test_add_func ("/owner/password-feedback", password_feedback);
    return g_test_run ();
}
