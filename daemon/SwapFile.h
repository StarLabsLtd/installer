/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <stdint.h>

int vale_swapfile_allocate (int fd, uint64_t size);
int vale_swapfile_offset (int fd, uint64_t size, uint64_t *offset);
