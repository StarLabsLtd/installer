/*
 * Copyright 2021-2026 elementary, Inc. (https://elementary.io)
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

[DBus (name = "io.elementary.InstallerDaemon")]
protected interface InstallerDaemon.InstallerInterface : GLib.Object {
    public signal void on_error (InstallerDaemon.Error error);
    public signal void on_status (InstallerDaemon.Status status);
    public signal void on_log_message (InstallerDaemon.LogLevel level, string message);

    public abstract InstallerDaemon.PartitionTable bootloader_detect () throws GLib.Error;

    public abstract InstallerDaemon.DiskInfo get_disks (bool get_partitions = false) throws GLib.Error;
    public abstract async int decrypt_partition (string path, string pv, string password, GLib.BusName sender) throws GLib.Error;
    public abstract InstallerDaemon.Disk get_logical_device (string pv) throws GLib.Error;
    public virtual async void install_dave (InstallerDaemon.InstallConfig config, string disk, GLib.UnixInputStream owner, GLib.UnixInputStream recovery, GLib.UnixInputStream hibernate_recovery, GLib.BusName sender) throws GLib.Error {
        yield InstallerDaemon.authorize_operation (sender);
        try {
            InstallerDaemon.DaveReadiness.require_no_swap ();
            throw new GLib.IOError.NOT_SUPPORTED ("Dave installation requires the repart backend");
        } finally {
            InstallerDaemon.end_operation ();
        }
    }

    public abstract async void install_with_default_disk_layout (InstallerDaemon.InstallConfig config, string disk, bool encrypt, string encryption_password, GLib.BusName sender) throws GLib.Error;
    public abstract async void install_with_custom_disk_layout (InstallerDaemon.InstallConfig config, InstallerDaemon.Mount[] disk_config, InstallerDaemon.LuksCredentials[] luks, GLib.BusName sender) throws GLib.Error;
    public abstract async void set_demo_mode_locale (string locale, GLib.BusName sender) throws GLib.Error;
    public abstract async void trigger_demo_mode (GLib.BusName sender) throws GLib.Error;
}

namespace InstallerDaemon {
    [CCode (cname = "vale_credentials_validate", cheader_filename = "OwnerCredentials.h")]
    internal extern bool validate_dave_credentials (int owner, int recovery, int hibernate_recovery, string hostname,
                                                    out string username, out uint64 password_offset,
                                                    out uint64 password_size) throws GLib.Error;

    private bool operation_active = false;
    private uint caller_watch = 0;

    internal void ensure_idle () throws GLib.Error {
        if (operation_active) {
            throw new GLib.IOError.BUSY ("Another installer operation is in progress");
        }
    }

    internal void end_operation () {
        if (caller_watch != 0) {
            Bus.unwatch_name (caller_watch);
            caller_watch = 0;
        }
        operation_active = false;
    }

    internal async void authorize_operation (GLib.BusName sender) throws GLib.Error {
        ensure_idle ();
        operation_active = true;
        var cancellable = new Cancellable ();
        try {
            // BusName is injected by GDBus, never supplied as a wire argument.
            if (!sender.has_prefix (":")) {
                throw new DBusError.ACCESS_DENIED ("Missing unique D-Bus caller");
            }
            caller_watch = Bus.watch_name (
                BusType.SYSTEM, sender, BusNameWatcherFlags.NONE,
                (connection, name, owner) => {},
                (connection, name) => cancellable.cancel ()
            );
            var subject = new Polkit.SystemBusName (sender);
            var authority = yield Polkit.Authority.get_async (cancellable);
            var result = yield authority.check_authorization (
                subject, "io.elementary.installer.modify-system", null,
                Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION, cancellable
            );
            if (!result.get_is_authorized ()) {
                throw new DBusError.ACCESS_DENIED ("Installer operation is not authorized");
            }
            var connection = yield Bus.get (BusType.SYSTEM, cancellable);
            var owner = yield connection.call (
                "org.freedesktop.DBus", "/org/freedesktop/DBus",
                "org.freedesktop.DBus", "NameHasOwner", new Variant ("(s)", sender),
                new VariantType ("(b)"), DBusCallFlags.NONE, -1, cancellable
            );
            if (!owner.get_child_value (0).get_boolean () || cancellable.is_cancelled ()) {
                throw new IOError.CANCELLED ("Installer caller disconnected before authorization completed");
            }
            // Once admitted, a destructive operation must finish cleanup even
            // if its caller disconnects. The reservation lasts until completion.
        } catch (GLib.Error e) {
            end_operation ();
            throw e;
        }
    }
}

private static GLib.MainLoop loop;

private void on_bus_acquired (GLib.DBusConnection connection, string name) {
    try {
#if DISTINST_BACKEND
        connection.register_object<InstallerDaemon.InstallerInterface> ("/io/elementary/InstallerDaemon", new InstallerDaemon.DistinstBackend ());
#elif REPART_BACKEND
        connection.register_object<InstallerDaemon.InstallerInterface> ("/io/elementary/InstallerDaemon", new InstallerDaemon.RepartBackend ());
#endif
    } catch (GLib.Error e) {
        critical ("Unable to register the object: %s", e.message);
    }
}

public static int main (string[] args) {
    loop = new GLib.MainLoop (null, false);

    var owner_id = GLib.Bus.own_name (
        GLib.BusType.SYSTEM,
        "io.elementary.InstallerDaemon",
        GLib.BusNameOwnerFlags.NONE,
        on_bus_acquired,
        () => { },
        () => { loop.quit (); }
    );

    loop.run ();

    GLib.Bus.unown_name (owner_id);

    return 0;
}
