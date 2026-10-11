/* SPDX-License-Identifier: GPL-3.0-or-later */
internal class InstallerDaemon.NormalRoot {
    internal Json.Object root;
    internal Json.Object esp;

    internal NormalRoot (string data, uint64 swap_size) throws GLib.Error {
        var parser = new Json.Parser ();
        parser.load_from_data (data);
        var node = parser.get_root ();
        if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
            throw new IOError.FAILED ("Invalid Normal partition plan");
        }
        foreach (var entry in node.get_array ().get_elements ()) {
            if (entry.get_node_type () != Json.NodeType.OBJECT) throw new IOError.FAILED ("Invalid Normal partition");
            var partition = entry.get_object ();
            var type = text (partition, "type");
            if (type == "root-x86-64") {
                if (root != null) throw new IOError.FAILED ("Ambiguous Normal ROOT");
                root = partition;
            } else if (type == "esp") {
                if (esp != null) throw new IOError.FAILED ("Ambiguous Normal ESP");
                esp = partition;
            }
        }
        if (root == null || esp == null) throw new IOError.FAILED ("Normal requires one ROOT and one ESP");
        foreach (var partition in new Json.Object[] {root, esp}) {
            if (!Uuid.string_is_valid (text (partition, "uuid")) ||
                number (partition, "offset") == 0 || number (partition, "offset") % 512 != 0 ||
                number (partition, "raw_size") == 0 || number (partition, "raw_size") % 512 != 0) {
                throw new IOError.FAILED ("Invalid Normal partition identity or extent");
            }
            number (partition, "partno");
        }
        if (text (root, "label") != "elementary-root" ||
            number (root, "raw_size") < swap_size + 4 * 1024 * 1024 * 1024UL) {
            throw new IOError.NO_SPACE ("Normal ROOT cannot hold persistent swap and factory files");
        }
        var root_offset = number (root, "offset");
        var esp_offset = number (esp, "offset");
        if (text (root, "uuid").down () == text (esp, "uuid").down () || number (root, "partno") == number (esp, "partno") ||
            (root_offset <= esp_offset ? number (root, "raw_size") > esp_offset - root_offset :
                                        number (esp, "raw_size") > root_offset - esp_offset)) {
            throw new IOError.FAILED ("Normal ROOT and ESP overlap");
        }
    }

    private static string text (Json.Object object, string name) throws GLib.Error {
        var node = object.get_member (name);
        if (node == null || node.get_node_type () != Json.NodeType.VALUE || node.get_value_type () != typeof (string)) {
            throw new IOError.FAILED ("Invalid Normal partition string: %s", name);
        }
        return node.get_string ();
    }

    private static uint64 number (Json.Object object, string name) throws GLib.Error {
        var node = object.get_member (name);
        if (node == null || node.get_node_type () != Json.NodeType.VALUE ||
            node.get_value_type () != typeof (int64) || node.get_int () < 0) {
            throw new IOError.FAILED ("Invalid Normal partition number: %s", name);
        }
        return (uint64) node.get_int ();
    }

    internal string swap_config (string luks_uuid, uint64 offset, uint64 size) throws GLib.Error {
        if (luks_uuid != "none" && !Uuid.string_is_valid (luks_uuid)) {
            throw new IOError.FAILED ("Invalid Normal ROOT LUKS UUID");
        }
        return "ROOT_PARTUUID=%s\nROOT_LUKS_UUID=%s\nRESUME_OFFSET=%s\nSWAP_SIZE=%s\n".printf (
            text (root, "uuid").down (), luks_uuid.down (), offset.to_string (), size.to_string ());
    }

    internal static void write_config (string path, string config) throws GLib.Error {
        // Do not follow factory symlinks or overwrite a preconfigured target.
        int etc = Posix.open (path + "/etc", Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
        if (etc < 0) throw new IOError.FAILED ("Could not open Normal ROOT etc");
        int directory = -1;
        int file = -1;
        bool saved = false;
        if (Posix.mkdirat (etc, "vale", 0755) == 0 || Posix.errno == Posix.EEXIST) {
            directory = Posix.openat (etc, "vale", Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            if (directory >= 0) {
                file = Posix.openat (directory, "root-swap.conf",
                    Posix.O_WRONLY | Posix.O_CREAT | Posix.O_EXCL | Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0644);
                saved = file >= 0 && Posix.write (file, config.data, config.length) == config.length &&
                        Posix.fsync (file) == 0 && Posix.fsync (directory) == 0 && Posix.fsync (etc) == 0;
            }
        }
        if (file >= 0 && Posix.close (file) != 0) saved = false;
        if (directory >= 0 && Posix.close (directory) != 0) saved = false;
        if (Posix.close (etc) != 0) saved = false;
        if (!saved) throw new IOError.FAILED ("Could not publish Normal ROOT swap configuration");
    }
}
