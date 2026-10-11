/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include "OwnerCredentials.h"
#include <gio/gio.h>
#include <pwquality.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

gboolean vale_owner_password_valid (const gchar *username, const gchar *password) {
    pwquality_settings_t *settings = pwquality_default_settings ();
    if (!settings) return FALSE;
    /* Match the installed password stack before accepting a disk password. */
    gboolean valid = pwquality_read_config (settings, NULL, NULL) >= 0 &&
        pwquality_set_int_value (settings, PWQ_SETTING_MIN_LENGTH, 12) >= 0 &&
        pwquality_check (settings, password, NULL, username, NULL) >= 0;
    pwquality_free_settings (settings);
    return valid;
}

static int sealed_fd (const void *data, size_t size, GError **error) {
    int fd = memfd_create ("installer-credential", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) goto failed;
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = write (fd, (const char *) data + offset, size - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) goto failed;
        offset += count;
    }
    if (lseek (fd, 0, SEEK_SET) < 0 ||
        fcntl (fd, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) < 0)
        goto failed;
    return fd;
failed:
    if (fd >= 0) close (fd);
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                         "Could not prepare private credential descriptor");
    return -1;
}

static gboolean random_bytes (unsigned char *bytes, size_t size, GError **error) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = getrandom (bytes + offset, size - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            explicit_bzero (bytes, size);
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                                 "Could not generate recovery credential");
            return FALSE;
        }
        offset += count;
    }
    return TRUE;
}

int vale_hibernate_bootstrap_fd (GError **error) {
    unsigned char bytes[32];
    if (!random_bytes (bytes, sizeof bytes, error)) return -1;
    int fd = sealed_fd (bytes, sizeof bytes, error);
    explicit_bzero (bytes, sizeof bytes);
    return fd;
}

gchar *vale_recovery_generate (GError **error) {
    unsigned char bytes[32];
    if (!random_bytes (bytes, sizeof bytes, error)) return NULL;
    static const char hex[] = "0123456789abcdef";
    gchar *result = g_malloc (65);
    for (size_t i = 0; i < sizeof bytes; i++) {
        result[2 * i] = hex[bytes[i] >> 4];
        result[2 * i + 1] = hex[bytes[i] & 15];
    }
    result[64] = 0;
    explicit_bzero (bytes, sizeof bytes);
    return result;
}

int vale_owner_credentials_fd (const gchar *username, const gchar *full_name,
                              const gchar *hostname, const gchar *password,
                              GError **error) {
    const gchar *fields[] = {username, full_name, hostname, password};
    const size_t bounds[] = {32, 256, 63, 511};
    unsigned char record[866];
    size_t offset = 0;
    for (size_t i = 0; i < G_N_ELEMENTS (fields); i++) {
        size_t size = strnlen (fields[i], bounds[i] + 1);
        if (size > bounds[i] || (i == 3 && size < 12)) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                                 "Owner fields are outside their byte limits");
            explicit_bzero (record, sizeof record);
            return -1;
        }
        memcpy (record + offset, fields[i], size + 1);
        offset += size + 1;
    }
    int fd = sealed_fd (record, offset, error);
    explicit_bzero (record, sizeof record);
    return fd;
}

int vale_recovery_fd (const gchar *recovery, GError **error) {
    if (strlen (recovery) != 64 || strspn (recovery, "0123456789abcdef") != 64) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                             "Invalid recovery credential");
        return -1;
    }
    return sealed_fd (recovery, 64, error);
}

static gboolean read_sealed (int fd, void *data, size_t minimum, size_t maximum,
                             size_t *size, GError **error) {
    struct stat st;
    const int required = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL;
    int seals = fcntl (fd, F_GET_SEALS);
    if (fstat (fd, &st) != 0 || !S_ISREG (st.st_mode) ||
        st.st_size < (off_t) minimum || st.st_size > (off_t) maximum ||
        seals < 0 || (seals & required) != required) goto failed;
    *size = (size_t) st.st_size;
    size_t offset = 0;
    while (offset < *size) {
        ssize_t count = pread (fd, (char *) data + offset, *size - offset, offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) goto failed;
        offset += count;
    }
    return TRUE;
failed:
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                         "Credentials require bounded regular sealed descriptors");
    return FALSE;
}

gboolean vale_credentials_validate (int owner, int recovery, int hibernate_recovery, const gchar *hostname,
                                    gchar **username,
                                    guint64 *password_offset, guint64 *password_size,
                                    GError **error) {
    char record[866] = {0}, key[65] = {0}, hibernate_key[65] = {0};
    char *fields[4];
    const size_t bounds[] = {32, 256, 63, 511};
    size_t size, key_size, offset = 0;
    gboolean valid = FALSE;
    *username = NULL;
    *password_offset = 0;
    *password_size = 0;
    if (!read_sealed (owner, record, 19, sizeof record, &size, error) ||
        !read_sealed (recovery, key, 64, 64, &key_size, error) ||
        !read_sealed (hibernate_recovery, hibernate_key, 64, 64, &key_size, error)) goto done;
    struct stat identities[3];
    const int fds[] = {owner, recovery, hibernate_recovery};
    for (size_t i = 0; i < G_N_ELEMENTS (fds); i++) {
        if (fstat (fds[i], &identities[i]) != 0) goto invalid;
        for (size_t j = 0; j < i; j++) {
            if (identities[i].st_dev == identities[j].st_dev &&
                identities[i].st_ino == identities[j].st_ino) goto invalid;
        }
    }
    for (size_t i = 0; i < G_N_ELEMENTS (fields); i++) {
        char *end = memchr (record + offset, 0, size - offset);
        if (!end) goto invalid;
        size_t length = end - (record + offset);
        if (length == 0 || length > bounds[i] || (i == 3 && length < 12) ||
            !g_utf8_validate (record + offset, length, NULL)) goto invalid;
        fields[i] = record + offset;
        offset += length + 1;
    }
    if (hostname == NULL || offset != size || strspn (key, "0123456789abcdef") != 64 ||
        strspn (hibernate_key, "0123456789abcdef") != 64 || strcmp (key, hibernate_key) == 0 ||
        !g_regex_match_simple ("\\A[a-z_][a-z0-9_-]{0,31}\\z", fields[0], 0, 0) ||
        strcmp (fields[0], "root") == 0 ||
        !g_regex_match_simple ("\\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z", fields[2], 0, 0) ||
        strcmp (fields[2], hostname) != 0 || strchr (fields[1], ':') ||
        strpbrk (fields[1], "\r\n") || strpbrk (fields[3], "\r\n") ||
        strcmp (fields[3], key) == 0 || strcmp (fields[3], hibernate_key) == 0 ||
        !vale_owner_password_valid (fields[0], fields[3])) goto invalid;
    valid = TRUE;
    *username = g_strdup (fields[0]);
    *password_offset = fields[3] - record;
    *password_size = strlen (fields[3]);
    goto done;
invalid:
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                         "Invalid owner or recovery credential record");
done:
    explicit_bzero (record, sizeof record);
    explicit_bzero (key, sizeof key);
    explicit_bzero (hibernate_key, sizeof hibernate_key);
    return valid;
}
