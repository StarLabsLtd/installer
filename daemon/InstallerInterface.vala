/*
 * Copyright 2021 elementary, Inc.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

protected interface InstallerDaemon.InstallerInterface : GLib.Object {
    public signal void on_error (InstallerDaemon.Error error);
    public signal void on_status (InstallerDaemon.Status status);
    public signal void on_log_message (InstallerDaemon.LogLevel level, string message);

    public abstract InstallerDaemon.PartitionTable bootloader_detect () throws GLib.Error;
    public abstract InstallerDaemon.DiskInfo get_disks (bool get_partitions = false) throws GLib.Error;
    public abstract int decrypt_partition (string path, string pv, string password) throws GLib.Error;
    public abstract InstallerDaemon.Disk get_logical_device (string pv) throws GLib.Error;
    public abstract void install_with_default_disk_layout (InstallerDaemon.InstallConfig config, string disk,
        bool encrypt, string encryption_password) throws GLib.Error;
    public abstract void install_with_custom_disk_layout (InstallerDaemon.InstallConfig config,
        InstallerDaemon.Mount[] disk_config, InstallerDaemon.LuksCredentials[] luks) throws GLib.Error;
    public abstract bool has_tpm2 () throws GLib.Error;
    protected bool default_has_tpm2 () {
        return false;
    }
}
