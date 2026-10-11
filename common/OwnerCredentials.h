/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <glib.h>

int vale_hibernate_bootstrap_fd (GError **error);
gchar *vale_recovery_generate (GError **error);
gboolean vale_owner_password_valid (const gchar *username, const gchar *password);
int vale_owner_credentials_fd (const gchar *username, const gchar *full_name,
                              const gchar *hostname, const gchar *password,
                              GError **error);
int vale_recovery_fd (const gchar *recovery, GError **error);
gboolean vale_credentials_validate (int owner, int recovery, int hibernate_recovery, const gchar *hostname,
                                    gchar **username,
                                    guint64 *password_offset, guint64 *password_size,
                                    GError **error);
