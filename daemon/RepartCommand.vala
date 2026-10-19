/*
 * Copyright 2026 elementary, Inc. (https://elementary.io)
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace InstallerDaemon.RepartCommand {
    internal string capture (string[] argv) throws GLib.Error {
        var process = new GLib.Subprocess.newv (
            argv, GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_MERGE
        );
        string? stdout_buf;
        process.communicate_utf8 (null, null, out stdout_buf, null);
        var diagnostic = stdout_buf.strip ();
        if (process.get_successful ()) {
            return diagnostic;
        }

        string status;
        if (process.get_if_signaled ()) {
            status = "terminated by signal %d".printf (process.get_term_sig ());
        } else {
            status = "exited with status %d".printf (process.get_exit_status ());
        }
        throw new GLib.IOError.FAILED (
            diagnostic == "" ? status : "%s: %s".printf (status, diagnostic)
        );
    }
}
