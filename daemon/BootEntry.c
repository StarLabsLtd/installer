/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "BootEntry.h"
#include <efivar/efiboot.h>
#include <string.h>

bool vale_boot_entry_matches(const uint8_t *variable, size_t size,
                            uint32_t partition, const char *uuid,
                            uint64_t start, uint64_t sectors, const char *loader)
{
    efi_guid_t guid;
    uint8_t expected[1024];
    ssize_t used, n;

    /* efivarfs prefixes the EFI load option with four attribute bytes. */
    if (size < 10 || size > 131076 || efi_str_to_guid(uuid, &guid) < 0)
        return false;
    efi_load_option *option = (efi_load_option *)(variable + 4);
    if (efi_loadopt_is_valid(option, size - 4) != 1 ||
        !(efi_loadopt_attrs(option) & 1) ||
        efi_loadopt_optional_data_size(option, size - 4) != 0)
        return false;

    used = efidp_make_hd(expected, sizeof(expected), partition, start, sectors,
                         (uint8_t *)&guid, EFIDP_HD_FORMAT_GPT, EFIDP_HD_SIGNATURE_GUID);
    if (used <= 0 || used >= (ssize_t)sizeof(expected))
        return false;
    n = efidp_make_file(expected + used, sizeof(expected) - used, (char *)loader);
    if (n <= 0 || n >= (ssize_t)sizeof(expected) - used)
        return false;
    used += n;
    n = efidp_make_end_entire(expected + used, sizeof(expected) - used);
    if (n <= 0 || n > (ssize_t)sizeof(expected) - used)
        return false;
    used += n;

    efidp path = efi_loadopt_path(option, size - 4);
    return path && efi_loadopt_pathlen(option, size - 4) == used &&
           memcmp(path, expected, used) == 0;
}
