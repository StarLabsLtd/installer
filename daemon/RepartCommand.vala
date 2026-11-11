/*
 * Copyright 2026 elementary, Inc. (https://elementary.io)
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace InstallerDaemon.RepartCommand {
    internal string capture (string[] argv) throws GLib.Error {
        var process = new GLib.Subprocess.newv (
            argv, GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE
        );
        string? stdout_buf;
        string? stderr_buf;
        process.communicate_utf8 (null, null, out stdout_buf, out stderr_buf);
        if (process.get_successful ()) {
            return stdout_buf.strip ();
        }

        var diagnostic = stdout_buf.strip ();
        var stderr_text = stderr_buf.strip ();
        if (stderr_text != "") {
            diagnostic = diagnostic == "" ? stderr_text : "%s\n%s".printf (diagnostic, stderr_text);
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
