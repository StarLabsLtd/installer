/* SPDX-License-Identifier: GPL-3.0-or-later */

namespace InstallerDaemon.BootKeymap {
    private const string ESP_PATH = "::/loader/addons/vale-keymap.addon.efi";
    private const uint64 MAX_ADDON_SIZE = 1024 * 1024;

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

    internal string stage (string keymap, string source, uint64 source_device, string work)
                           throws GLib.Error {
        if (!Regex.match_simple ("\\A[A-Za-z0-9][A-Za-z0-9_.+-]*\\z", keymap)) {
            throw new GLib.IOError.INVALID_DATA ("Invalid console keymap name");
        }
        var input = Path.build_filename (source, keymap + ".addon.efi");
        Posix.Stat stat;
        if (Posix.lstat (input, out stat) != 0 || !Posix.S_ISREG (stat.st_mode) ||
            stat.st_dev != source_device || stat.st_size <= 0 || stat.st_size > MAX_ADDON_SIZE) {
            throw new GLib.IOError.FAILED ("Missing authenticated console keymap add-on: %s", keymap);
        }
        // The caller retains the recovery's verity-checked, read-only filesystem.
        var path = Path.build_filename (work, "vale-keymap.addon.efi");
        File.new_for_path (input).copy (File.new_for_path (path), FileCopyFlags.NONE);
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
            RepartCommand.capture ({"mtools", "-c", "mdir", "-b", "-i", image, "::/loader/addons"});
        } catch (GLib.Error e) {
            RepartCommand.capture ({"mtools", "-c", "mmd", "-i", image, "::/loader/addons"});
        }
        RepartCommand.capture ({"mtools", "-c", "mcopy", "-o", "-i", image, staged, ESP_PATH});
        var readback = Path.build_filename (work, "vale-keymap-readback.efi");
        RepartCommand.capture ({"mtools", "-c", "mcopy", "-i", image, ESP_PATH, readback});
        if (!same_bytes (staged, readback)) {
            throw new GLib.IOError.FAILED ("Console keymap add-on differs after writing the ESP");
        }
        File.new_for_path (readback).delete ();
    }
    internal void sync_target_and_remove_staged (int fd, string? staged) throws GLib.Error {
        if (Posix.fsync (fd) != 0) {
            throw new GLib.IOError.FAILED ("Could not sync ESP");
        }
        if (staged != null) File.new_for_path (staged).delete ();
    }

}
