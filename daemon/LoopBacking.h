/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <sys/types.h>

int vale_loop_backing_device (int fd, dev_t *device);
int vale_loop_matches_partition (int loop_fd, int disk_fd, unsigned long long offset, unsigned long long size);
