/* SPDX-License-Identifier: GPL-3.0-or-later */

namespace InstallerDaemon.NormalKeymapCredential {
    private const string NAME = "vconsole.keymap";
    private const string ESP_PATH = "::/loader/credentials/vconsole.keymap.cred";
    private const uint64 MAX_CREDENTIAL_SIZE = 65536;

    private string first_component (string value) {
        var comma = value.index_of (",");
        return comma < 0 ? value : value.substring (0, comma);
    }

    private bool has_no_secondary_variants (string value) {
        var comma = value.index_of (",");
        return comma < 0 || value.substring (comma + 1).replace (",", "") == "";
    }

    internal string map_xkb_layout (string map, string layout, string variant) throws GLib.Error {
        foreach (var line in map.split ("\n")) {
            var text = line.strip ();
            if (text == "" || text.has_prefix ("#")) continue;
            var fields = Regex.split_simple ("\\s+", text);
            if (fields.length != 5) {
                throw new GLib.IOError.INVALID_DATA ("Invalid systemd keyboard model map");
            }
            var mapped_variant = fields[3] == "-" ? "" : first_component (fields[3]);
            if (first_component (fields[1]) == layout && mapped_variant == variant &&
                (fields[3] == "-" || has_no_secondary_variants (fields[3]))) return fields[0];
        }
        throw new GLib.IOError.NOT_SUPPORTED ("No console keymap matches the selected XKB layout and variant");
    }

    internal string encrypt (string keymap, string work, string command = "/usr/bin/systemd-creds")
                            throws GLib.Error {
        var path = Path.build_filename (work, NAME + ".cred");
        var process = new Subprocess.newv ({command, "encrypt", "--with-key=tpm2", "--tpm2-pcrs=",
            "--name=" + NAME, "-", path}, SubprocessFlags.STDIN_PIPE);
        try {
            process.communicate_utf8 (keymap, null, null, null);
        } catch (GLib.Error e) {
            process.force_exit ();
            try { process.wait (); } catch (GLib.Error wait_error) { }
            throw new GLib.IOError.FAILED ("Could not encrypt the console keymap: %s", e.message);
        }
        if (!process.get_successful ()) {
            throw new GLib.IOError.FAILED ("Could not encrypt the console keymap");
        }
        Posix.Stat stat;
        if (Posix.lstat (path, out stat) != 0 || !Posix.S_ISREG (stat.st_mode) ||
            stat.st_size <= 0 || stat.st_size > MAX_CREDENTIAL_SIZE || Posix.chmod (path, 0600) != 0) {
            throw new GLib.IOError.FAILED ("systemd-creds produced an invalid keymap credential");
        }
        return path;
    }

    private bool same_bytes (string first, string second) throws GLib.Error {
        uint8[] a;
        uint8[] b;
        FileUtils.get_data (first, out a);
        FileUtils.get_data (second, out b);
        if (a.length != b.length) return false;
        for (size_t i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    internal void copy_to_new_esp (string staged, string disk, uint64 offset, string work) throws GLib.Error {
        var image = "%s@@%s".printf (disk, offset.to_string ());
        try {
            RepartCommand.capture ({"mtools", "-c", "mdir", "-b", "-i", image, "::/loader/credentials"});
        } catch (GLib.Error e) {
            RepartCommand.capture ({"mtools", "-c", "mmd", "-i", image, "::/loader/credentials"});
        }
        RepartCommand.capture ({"mtools", "-c", "mcopy", "-o", "-i", image, staged, ESP_PATH});
        var readback = Path.build_filename (work, "vconsole.keymap-readback.cred");
        RepartCommand.capture ({"mtools", "-c", "mcopy", "-i", image, ESP_PATH, readback});
        if (!same_bytes (staged, readback)) {
            throw new GLib.IOError.FAILED ("Console keymap credential differs after writing the ESP");
        }
        File.new_for_path (readback).delete ();
    }
}
