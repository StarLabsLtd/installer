/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool vale_boot_entry_matches(const uint8_t *variable, size_t size,
                            uint32_t partition, const char *uuid,
                            uint64_t start, uint64_t sectors, const char *loader);
