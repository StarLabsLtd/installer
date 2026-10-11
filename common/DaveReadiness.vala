/* SPDX-License-Identifier: GPL-3.0-or-later */
internal class InstallerDaemon.DaveReadiness {
    internal static bool matches_bios_vendor (string contents) {
        // sysfs appends a newline; whitespace in the firmware value is significant.
        return contents == "DAVE\n";
    }

    internal static bool allows_dave_firmware () {
#if TEST_DAVE_VISIBILITY
        return true;
#else
        try {
            string vendor;
            FileUtils.get_contents ("/sys/class/dmi/id/bios_vendor", out vendor);
            return matches_bios_vendor (vendor);
        } catch (FileError e) {
            return false;
        }
#endif
    }

    internal static void check_swap_contents (string contents) throws GLib.Error {
        var lines = contents.split ("\n");
        if (!contents.validate () || lines.length == 0 ||
            string.joinv (" ", Regex.split_simple ("\\s+", lines[0].strip ())) != "Filename Type Size Used Priority") {
            throw new IOError.FAILED ("Could not identify active swap state");
        }
        for (int i = 1; i < lines.length; i++) {
            if (lines[i].strip () != "") {
                throw new IOError.PERMISSION_DENIED ("Dave mode requires no active swap");
            }
        }
    }

    internal static void require_no_swap () throws GLib.Error {
        // Fixed kernel path, bounded read; flags in /proc/cmdline are not proof.
        var stream = File.new_for_path ("/proc/swaps").read ();
        GLib.Error? close_error = null;
        try {
            uint8[] bytes = new uint8[4097];
            size_t count;
            stream.read_all (bytes, out count);
            if (count == 0 || count >= bytes.length) {
                throw new IOError.FAILED ("Could not read bounded active swap state");
            }
            for (size_t i = 0; i < count; i++) {
                if (bytes[i] == 0) throw new IOError.FAILED ("Invalid active swap state");
            }
            bytes[count] = 0;
            check_swap_contents ((string) bytes);
        } finally {
            try {
                stream.close ();
            } catch (GLib.Error e) {
                close_error = e;
            }
        }
        if (close_error != null) throw close_error;
    }
}
