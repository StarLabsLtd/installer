/* SPDX-License-Identifier: GPL-3.0-or-later */
internal delegate string InstallerDaemon.BootCommand (string[] argv) throws GLib.Error;
internal delegate void InstallerDaemon.BootGuard () throws GLib.Error;

internal class InstallerDaemon.NormalBoot {
    private enum Publication {
        NONE,
        ORDER,
        DEFAULT,
        ONESHOT,
        NEXT
    }

    private const string VARIABLES = "/sys/firmware/efi/efivars";
    internal const string EFI = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
    internal const string LOADER = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
    private HashTable<string, Bytes> entries;
    private Bytes? order;
    private Bytes? default_entry;
    private string ordinary;
    private string commission;
    private BootCommand command;
    private BootGuard guard;
    private HashTable<string, string> files;

    [CCode (cname = "vale_boot_entry_matches", cheader_filename = "BootEntry.h")]
    private static extern bool entry_matches ([CCode (array_length_type = "size_t")] uint8[] data,
        uint32 partition, string uuid, uint64 start, uint64 sectors, string loader);

    internal NormalBoot (string source, string work, owned BootCommand command, owned BootGuard guard) throws GLib.Error {
        this.command = (owned) command;
        this.guard = (owned) guard;
        this.guard ();
        // The caller retained this image from the signed recovery's verity media.
        // Bind the producer's installed chain, not the live recovery dispatcher.
        var listing = this.command ({"mtools", "-c", "mdir", "-b", "-i", source,
                                     "::/EFI/Linux/elementary_*.efi"}).strip ().split ("\n");
        ordinary = Path.get_basename (listing[0]);
        MatchInfo match;
        var pattern = new Regex ("\\Aelementary_([0-9]+)\\.efi\\z");
        if (!pattern.match (ordinary, 0, out match) || listing.length != 1) {
            throw new IOError.FAILED ("Normal requires one versioned ordinary image");
        }
        commission = "elementary-normal-commission_" + match.fetch (1) + ".efi";
        var commissions = this.command ({"mtools", "-c", "mdir", "-b", "-i", source,
                                         "::/EFI/Linux/elementary-normal-commission_*.efi"}).strip ().split ("\n");
        if (commissions.length != 1 || Path.get_basename (commissions[0]) != commission) {
            throw new IOError.FAILED ("Normal commissioning image does not match the ordinary image");
        }
        files = new HashTable<string, string> (str_hash, str_equal);
        foreach (var path in new string[] {"/EFI/BOOT/BOOTX64.EFI", "/EFI/systemd/systemd-bootx64.efi",
                                          "/EFI/Linux/" + ordinary, "/EFI/Linux/" + commission, "/loader/loader.conf"}) {
            files.insert (path, image_hash (source, path, work));
        }
        if (files.lookup ("/EFI/BOOT/BOOTX64.EFI") != files.lookup ("/EFI/systemd/systemd-bootx64.efi")) {
            throw new IOError.NOT_SUPPORTED ("Normal requires the authenticated direct systemd-boot fallback");
        }
        var config = this.command ({"mtools", "-c", "mtype", "-i", source, "::/loader/loader.conf"});
        bool default_found = false;
        foreach (var line in config.split ("\n")) {
            var words = Regex.split_simple ("\\s+", line.strip ());
            if (words[0] == "default") {
                if (default_found || words.length != 2 || words[1] != "elementary_*") {
                    throw new IOError.FAILED ("Normal requires an ordinary-only loader default");
                }
                default_found = true;
            } else if (words[0] == "sysfail") {
                throw new IOError.BUSY ("Loader failure selection conflicts with commissioning");
            }
        }
        if (!default_found) throw new IOError.FAILED ("Normal loader default is missing");
        // Preserve queued user operations; this installation does not own them.
        if (read_variable ("BootNext", EFI) != null || read_variable ("LoaderEntryOneShot", LOADER) != null ||
            read_variable ("LoaderEntrySysFail", LOADER) != null) {
            throw new IOError.BUSY ("A firmware or loader boot selection is already pending");
        }
        order = read_variable ("BootOrder", EFI);
        order_string (order);
        default_entry = read_variable ("LoaderEntryDefault", LOADER);
        if (default_entry != null && loader_string (default_entry) != "elementary_*" &&
            loader_string (default_entry) != ordinary) {
            throw new IOError.BUSY ("The existing loader default requires explicit selection");
        }
        entries = read_entries ();
    }

    private string image_hash (string image, string path, string work) throws GLib.Error {
        var copy = work + "/boot-input";
        try {
            command ({"mtools", "-c", "mcopy", "-i", image, "::" + path, copy});
            return command ({"sha256sum", copy}).split (" ")[0];
        } finally {
            if (FileUtils.unlink (copy) != 0 && Posix.errno != Posix.ENOENT) {
                warning ("Could not remove private boot input: %s", Posix.strerror (Posix.errno));
            }
        }
    }

    internal void verify_target (string image, string work) throws GLib.Error {
        guard ();
        foreach (var path in files.get_keys ()) {
            if (image_hash (image, path, work) != files.lookup (path)) {
                throw new IOError.FAILED ("Installed boot input differs from authenticated media: %s", path);
            }
        }
        require_selection (order, default_entry);
    }

    internal static Bytes? read_variable (string name, string guid) throws GLib.Error {
        var file = File.new_for_path (VARIABLES + "/" + name + "-" + guid);
        try {
            uint8[] data;
            file.load_contents (null, out data, null);
            if (data.length < 4 || data.length > 131076) {
                throw new IOError.FAILED ("Invalid EFI variable: %s", name);
            }
            return new Bytes (data);
        } catch (IOError.NOT_FOUND e) {
            return null;
        }
    }

    private static bool same (Bytes? first, Bytes? second) {
        return first == null ? second == null : second != null && first.compare (second) == 0;
    }

    internal static string loader_string (Bytes value) throws GLib.Error {
        unowned uint8[] data = value.get_data ();
        if (data.length < 6 || data.length % 2 != 0 || data[data.length - 2] != 0 || data[data.length - 1] != 0) {
            throw new IOError.FAILED ("Invalid loader selection");
        }
        var text = new StringBuilder ();
        for (int i = 4; i < data.length - 2; i += 2) {
            if (data[i + 1] != 0 || data[i] < 0x20 || data[i] >= 0x7f) {
                throw new IOError.FAILED ("Nonliteral loader selection");
            }
            text.append_c ((char) data[i]);
        }
        return text.str;
    }

    private static string order_string (Bytes? value) throws GLib.Error {
        if (value == null) return "";
        unowned uint8[] data = value.get_data ();
        if (data.length % 2 != 0) throw new IOError.FAILED ("Invalid firmware boot order");
        string[] numbers = {};
        for (int i = 4; i < data.length; i += 2) {
            numbers += "%04X".printf ((uint) data[i] | ((uint) data[i + 1] << 8));
        }
        return string.joinv (",", numbers);
    }

    private static HashTable<string, Bytes> read_entries () throws GLib.Error {
        var result = new HashTable<string, Bytes> (str_hash, str_equal);
        var directory = File.new_for_path (VARIABLES).enumerate_children (FileAttribute.STANDARD_NAME,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? info;
        while ((info = directory.next_file ()) != null) {
            var name = info.get_name ();
            if (!Regex.match_simple ("\\ABoot[0-9A-Fa-f]{4}-" + EFI + "\\z", name)) continue;
            var value = read_variable (name.substring (0, 8), EFI);
            if (value == null) throw new IOError.BUSY ("Firmware boot entries changed");
            result.insert (name.substring (0, 8), value);
        }
        directory.close ();
        return result;
    }

    private void require_selection (Bytes? expected_order, Bytes? expected_default,
                                    Bytes? expected_oneshot = null, Bytes? expected_next = null) throws GLib.Error {
        guard ();
        var current = read_entries ();
        if (current.size () != entries.size ()) throw new IOError.BUSY ("Firmware boot entries changed");
        foreach (var name in entries.get_keys ()) {
            if (!same (entries.lookup (name), current.lookup (name))) {
                throw new IOError.BUSY ("Firmware boot entry changed: %s", name);
            }
        }
        if (!same (expected_order, read_variable ("BootOrder", EFI)) ||
            !same (expected_default, read_variable ("LoaderEntryDefault", LOADER)) ||
            !same (expected_next, read_variable ("BootNext", EFI)) ||
            !same (expected_oneshot, read_variable ("LoaderEntryOneShot", LOADER)) ||
            read_variable ("LoaderEntrySysFail", LOADER) != null) {
            throw new IOError.BUSY ("Boot selections changed during installation");
        }
    }

    internal void publish (string disk, uint32 partition, string uuid, uint64 start,
                           uint64 sectors) throws GLib.Error {
        const string qualified_loader = "\\EFI\\BOOT\\BOOTX64.EFI";
        require_selection (order, default_entry);
        command ({"efibootmgr", "--create-only", "--disk", disk, "--part", partition.to_string (),
                  "--loader", qualified_loader, "--label", "Vale"});
        // A failed attempt leaves its new inactive-in-BootOrder entry for inspection.
        // Never delete Boot#### or change a pre-existing entry during cleanup.
        var current = read_entries ();
        string? created = null;
        foreach (var name in current.get_keys ()) {
            if (entries.contains (name)) {
                if (!same (entries.lookup (name), current.lookup (name))) {
                    throw new IOError.BUSY ("Foreign firmware boot entry changed");
                }
            } else {
                if (created != null) throw new IOError.BUSY ("Ambiguous newly created firmware entries");
                created = name;
            }
        }
        if (created == null || current.size () != entries.size () + 1 ||
            !entry_matches (current.lookup (created).get_data (), partition, uuid, start, sectors, qualified_loader)) {
            throw new IOError.FAILED ("Created firmware entry differs from the admitted target");
        }
        entries.insert (created, current.lookup (created));
        require_selection (order, default_entry);
        var number = created.substring (4);
        var previous_order = order_string (order);
        var installed_order = number + (previous_order == "" ? "" : "," + previous_order);
        Bytes? installed_order_value = null;
        Bytes? installed_default = null;
        Bytes? installed_oneshot = null;
        Bytes? installed_next = null;
        Publication attempted = Publication.NONE;
        try {
            attempted = Publication.ORDER;
            command ({"efibootmgr", "--bootorder", installed_order});
            var written_order = read_variable ("BootOrder", EFI);
            if (written_order == null || order_string (written_order) != installed_order) {
                throw new IOError.FAILED ("Could not verify installed firmware boot order");
            }
            installed_order_value = written_order;
            require_selection (installed_order_value, default_entry);
            // Recovery uses a dispatcher, not necessarily systemd-boot. Select
            // the qualified target's entries without relying on live LoaderInfo.
            attempted = Publication.DEFAULT;
            command ({"bootctl", "--variables=yes", "set-default", "elementary_*"});
            var written_default = read_variable ("LoaderEntryDefault", LOADER);
            if (written_default == null || loader_string (written_default) != "elementary_*") {
                throw new IOError.FAILED ("Could not verify ordinary Normal boot default");
            }
            installed_default = written_default;
            require_selection (installed_order_value, installed_default);
            attempted = Publication.ONESHOT;
            command ({"bootctl", "--variables=yes", "set-oneshot", commission});
            var written_oneshot = read_variable ("LoaderEntryOneShot", LOADER);
            if (written_oneshot == null || loader_string (written_oneshot) != commission) {
                throw new IOError.FAILED ("Could not verify commissioning boot selection");
            }
            installed_oneshot = written_oneshot;
            require_selection (installed_order_value, installed_default, installed_oneshot);
            attempted = Publication.NEXT;
            command ({"efibootmgr", "--bootnext", number});
            var written_next = read_variable ("BootNext", EFI);
            if (written_next == null || order_string (written_next) != number) {
                throw new IOError.FAILED ("Could not verify commissioning firmware route");
            }
            installed_next = written_next;
            require_selection (installed_order_value, installed_default, installed_oneshot, installed_next);
        } catch (GLib.Error e) {
            // A command or its readback may fail after the write took effect.
            // Reconcile attempted values, preserving a different writer's choice.
            try {
                var current_next = read_variable ("BootNext", EFI);
                if (attempted >= Publication.NEXT && current_next != null && order_string (current_next) == number) {
                    command ({"efibootmgr", "--delete-bootnext"});
                }
                var current_oneshot = read_variable ("LoaderEntryOneShot", LOADER);
                if (attempted >= Publication.ONESHOT && current_oneshot != null && loader_string (current_oneshot) == commission) {
                    command ({"bootctl", "--variables=yes", "set-oneshot", ""});
                }
                var current_default = read_variable ("LoaderEntryDefault", LOADER);
                if (attempted >= Publication.DEFAULT && current_default != null && loader_string (current_default) == "elementary_*") {
                    command ({"bootctl", "--variables=yes", "set-default", default_entry == null ? "" : loader_string (default_entry)});
                }
                var current_order = read_variable ("BootOrder", EFI);
                if (attempted >= Publication.ORDER && current_order != null && order_string (current_order) == installed_order) {
                    if (order == null) command ({"efibootmgr", "--delete-bootorder"});
                    else command ({"efibootmgr", "--bootorder", previous_order});
                }
            } catch (GLib.Error cleanup_error) {
                throw new IOError.FAILED ("%s; boot selection cleanup failed: %s", e.message, cleanup_error.message);
            }
            throw e;
        }
    }
}
