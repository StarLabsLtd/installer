/* SPDX-License-Identifier: GPL-3.0-or-later */

namespace InstallerDaemon.NormalSeedCarrier {
    private const uint64 COUNTER_HANDLE = 0x01801100;
    private const string ESP_TYPE = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b";
    private const string DOS_ESP_TYPE = "ef";
    private const uint64 MIN_SIZE = 80;
    private const uint64 MAX_SIZE = 4096;

    internal bool counter_is_present (string output) throws GLib.Error {
        bool found = false;
        foreach (var line in output.split ("\n")) {
            var handle = line.strip ();
            if (handle == "") continue;
            if (handle.has_prefix ("- ")) handle = handle.substring (2).strip ();
            if (!Regex.match_simple ("\\A0x[0-9a-fA-F]{1,8}\\z", handle)) {
                throw new GLib.IOError.INVALID_DATA ("Invalid TPM NV handle listing");
            }
            var value = uint64.parse (handle.substring (2), 16);
            if (value == COUNTER_HANDLE) found = true;
        }
        return found;
    }

    internal void require_carrier (bool counter_present, bool carrier_present) throws GLib.Error {
        if (counter_present && !carrier_present) {
            throw new GLib.IOError.BUSY (
                "Cannot erase this disk: the Normal TPM counter exists but its seed carrier is missing"
            );
        }
    }

    internal uint64[] esp_offsets (string data) throws GLib.Error {
        var parser = new Json.Parser ();
        parser.load_from_data (data);
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT ||
            !root.get_object ().has_member ("partitiontable") ||
            root.get_object ().get_member ("partitiontable").get_node_type () != Json.NodeType.OBJECT) {
            throw new GLib.IOError.INVALID_DATA ("Invalid target partition table");
        }
        var table = root.get_object ().get_object_member ("partitiontable");
        if (table == null || !table.has_member ("label") || !table.has_member ("sectorsize") ||
            !table.has_member ("partitions") ||
            table.get_member ("label").get_value_type () != typeof (string) ||
            table.get_member ("sectorsize").get_value_type () != typeof (int64) ||
            table.get_member ("partitions").get_node_type () != Json.NodeType.ARRAY) {
            throw new GLib.IOError.INVALID_DATA ("Invalid target partition table");
        }
        var label = table.get_string_member ("label");
        if (label != "gpt" && label != "dos") {
            throw new GLib.IOError.NOT_SUPPORTED ("Unsupported target partition table");
        }
        var sector_size = table.get_int_member ("sectorsize");
        if (sector_size != 512 && sector_size != 4096) {
            throw new GLib.IOError.NOT_SUPPORTED ("Unsupported target logical sector size");
        }

        var partitions = table.get_array_member ("partitions");
        uint64[] offsets = {};
        foreach (var node in partitions.get_elements ()) {
            if (node.get_node_type () != Json.NodeType.OBJECT) {
                throw new GLib.IOError.INVALID_DATA ("Invalid target partition entry");
            }
            var partition = node.get_object ();
            if (!partition.has_member ("type") || !partition.has_member ("start") ||
                partition.get_member ("type").get_value_type () != typeof (string) ||
                partition.get_member ("start").get_value_type () != typeof (int64)) {
                throw new GLib.IOError.INVALID_DATA ("Invalid target partition entry");
            }
            var type = partition.get_string_member ("type").down ();
            if ((label == "gpt" && type != ESP_TYPE) ||
                (label == "dos" && type != DOS_ESP_TYPE)) continue;
            var start = partition.get_int_member ("start");
            if (start < 0 || (uint64) start > uint64.MAX / (uint64) sector_size) {
                throw new GLib.IOError.INVALID_DATA ("Invalid target ESP offset");
            }
            offsets += (uint64) start * (uint64) sector_size;
        }
        return offsets;
    }

    private string esp_image (string disk, uint64 offset) {
        return "%s@@%s".printf (disk, offset.to_string ());
    }

    private uint8[] read_carrier (string image) throws GLib.Error {
        var process = new Subprocess.newv ({"mtools", "-c", "mtype", "-i", image,
            "::/EFI/Vale/normal-seed"}, SubprocessFlags.STDOUT_PIPE);
        var stream = process.get_stdout_pipe ();
        uint8[] carrier = new uint8[MAX_SIZE + 1];
        size_t used = 0;
        try {
            while (used < carrier.length) {
                ssize_t count = stream.read (carrier[used:]);
                if (count == 0) break;
                used += (size_t) count;
            }
        } catch (GLib.Error e) {
            process.force_exit ();
            try { process.wait (); } catch (GLib.Error wait_error) { }
            throw new GLib.IOError.FAILED ("Could not read target Normal seed carrier: %s", e.message);
        }
        if (used > MAX_SIZE) {
            process.force_exit ();
            try { process.wait (); } catch (GLib.Error e) { }
            throw new GLib.IOError.INVALID_DATA ("Normal seed carrier exceeds 4096 bytes");
        }
        try {
            process.wait_check ();
        } catch (GLib.Error e) {
            throw new GLib.IOError.FAILED ("Could not read target Normal seed carrier: %s", e.message);
        }
        if (used < MIN_SIZE) throw new GLib.IOError.INVALID_DATA ("Invalid Normal seed carrier size");
        return carrier[:used];
    }

    internal string? stage_from_target (string disk, uint64[] offsets, string work) throws GLib.Error {
        string? staged = null;
        foreach (var offset in offsets) {
            var image = esp_image (disk, offset);
            try {
                RepartCommand.capture ({"env", "LC_ALL=C", "mtools", "-c", "mdir", "-b", "-i",
                    image, "::/EFI/Vale/normal-seed"});
            } catch (GLib.Error e) {
                if (e.message.contains ("File \"::/EFI/Vale/normal-seed\" not found")) continue;
                throw new GLib.IOError.FAILED ("Could not inspect the existing target ESP: %s", e.message);
            }
            if (staged != null) {
                throw new GLib.IOError.BUSY ("More than one target ESP contains a Normal seed carrier");
            }
            staged = Path.build_filename (work, "normal-seed");
            FileUtils.set_data (staged, read_carrier (image));
        }
        return staged;
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
        var image = esp_image (disk, offset);
        RepartCommand.capture ({"mtools", "-c", "mcopy", "-o", "-i", image,
            staged, "::/EFI/Vale/normal-seed"});
        var readback = Path.build_filename (work, "normal-seed-readback");
        RepartCommand.capture ({"mtools", "-c", "mcopy", "-o", "-i", image,
            "::/EFI/Vale/normal-seed", readback});
        if (!same_bytes (staged, readback)) {
            throw new GLib.IOError.FAILED ("Normal seed carrier differs after writing the new ESP");
        }
        FileUtils.unlink (readback);
    }

    internal void sync_target_and_remove_staged (int fd, string? staged,
                                                 string? staged_keymap = null) throws GLib.Error {
        if (Posix.fsync (fd) != 0) {
            throw new GLib.IOError.FAILED ("Could not sync Normal ESP");
        }
        if (staged != null) File.new_for_path (staged).delete ();
        if (staged_keymap != null) File.new_for_path (staged_keymap).delete ();
    }
}
