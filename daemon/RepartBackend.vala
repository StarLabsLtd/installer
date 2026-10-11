/*
 * Copyright 2026 elementary, Inc. (https://elementary.io)
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class InstallerDaemon.RepartBackend : InstallerInterface, GLib.Object {
    // Downstream Normal-only binding to the signed Recovery UKI media contract.
    private class MediaSource : Object {
        public int[] fds = {-1, -1, -1, -1, -1, -1, -1}; // mapper, cdrom, outer, live, raw, live/definition directories
        public Posix.Stat[] identities = new Posix.Stat[7];
        public string table;
        public string state;
        public string backing;
        public Posix.Stat backing_identity;
        public string backing_sequence;
    }

    private class PreparedRoot : Object {
        public string path;
        public bool mounted = false;
        public int fd = -1;
        public Posix.Stat identity;
    }

    [CCode (cname = "vale_hibernate_bootstrap_fd", cheader_filename = "OwnerCredentials.h")]
    private static extern int hibernate_bootstrap_fd () throws GLib.Error;

    [CCode (cname = "vale_loop_backing_device", cheader_filename = "LoopBacking.h")]
    private static extern int loop_backing_device (int fd, out Posix.dev_t device);

    private class DaveInstall : Object {
        public int owner;
        public int recovery;
        public int hibernate_recovery;
        public int bootstrap_fd = -1;
        public int hibernate_fd = -1;
        public int hibernate_image_fd = -1;
        public Posix.Stat hibernate_image;
        public string hibernate_path;
        public string? hibernate_mapping = null;
        public bool hibernate_mounted = false;
        public uint64 hibernate_payload;
        public uint64 hibernate_size;
        public string hibernate_uuid;
        public Json.Object hibernate_plan;
        public Json.Object hibernate_metadata;
        public string hostname;
        public string lang;
        public string keyboard_layout;
        public string keyboard_variant;
        public string srk_name;
        public string uuid;
        public string username;
        public uint64 password_offset;
        public uint64 password_size;
        public string copy_path;
        public int copy_fd = -1;
        public int root_fd = -1;
        public int[] staged_fds = {-1, -1, -1, -1, -1, -1};
        public Posix.Stat[] staged = new Posix.Stat[6];
        public bool copy_mounted = false;
        public bool flatpak_mounted = false;
        public bool factory_mounted = false;
        public Json.Object root_plan;
        public Json.Object metadata;
    }

    private Json.Node parse_json (string data, Json.NodeType type) throws GLib.Error {
        var parser = new Json.Parser ();
        parser.load_from_data (data);
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != type) {
            throw new IOError.FAILED ("Unexpected native tool metadata");
        }
        return root.copy ();
    }

    private unowned Json.Node json_member (Json.Object object, string name, Json.NodeType type) throws GLib.Error {
        unowned var node = object.get_member (name);
        if (node == null || node.get_node_type () != type) {
            throw new IOError.FAILED ("Missing or invalid native metadata: %s", name);
        }
        return node;
    }

    private string json_string (Json.Object object, string name) throws GLib.Error {
        var node = json_member (object, name, Json.NodeType.VALUE);
        if (node.get_value_type () != typeof (string)) {
            throw new IOError.FAILED ("Invalid native string metadata");
        }
        return node.get_string ();
    }

    private int64 json_integer (Json.Object object, string name) throws GLib.Error {
        var node = json_member (object, name, Json.NodeType.VALUE);
        if (node.get_value_type () != typeof (int64) || node.get_int () < 0) {
            throw new IOError.FAILED ("Invalid native integer metadata");
        }
        return node.get_int ();
    }

    private Json.Object dave_root_plan (string data) throws GLib.Error {
        var node = parse_json (data, Json.NodeType.ARRAY);
        Json.Object? root = null;
        uint esp = 0;
        uint usr = 0;
        uint hibernate = 0;
        bool spare_usr = false;
        foreach (var entry in node.get_array ().get_elements ()) {
            if (entry.get_node_type () != Json.NodeType.OBJECT) {
                throw new IOError.FAILED ("Invalid repart partition metadata");
            }
            var partition = entry.get_object ();
            var type = json_string (partition, "type");
            if (type == "root-x86-64") {
                if (root != null) throw new IOError.FAILED ("Ambiguous DAVE ROOT");
                root = partition;
            } else if (type == "swap") {
                if (json_string (partition, "label") != "vale-hibernate") {
                    throw new IOError.FAILED ("Unexpected DAVE HIB label");
                }
                hibernate++;
            } else if (type == "esp") {
                esp++;
            } else if (type == "usr-x86-64") {
                if (json_string (partition, "label") == "_empty") {
                    if (spare_usr) throw new IOError.FAILED ("Ambiguous spare USR");
                    spare_usr = true;
                } else {
                    usr++;
                }
            } else if (!(type in new string[] {"xbootldr", "usr-x86-64-verity", "usr-x86-64-verity-sig"})) {
                throw new IOError.FAILED ("Unsupported DAVE source partition type");
            }
        }
        if (root == null || esp != 1 || usr != 1 || hibernate != 1 || json_string (root, "label") != "elementary-root-dave" ||
            !Uuid.string_is_valid (json_string (root, "uuid"))) {
            throw new IOError.FAILED ("DAVE requires one ROOT, USR and deferred ESP");
        }
        json_integer (root, "offset");
        json_integer (root, "partno");
        return root;
    }

    private void require_sleep_kernel (MediaSource media, string raw, string work, bool dave) throws GLib.Error {
        var directory = work + "/sleep-kernel";
        File.new_for_path (directory).make_directory ();
        GLib.Error? error = null;
        try {
            // Inspect the selected UKIs, not the recovery kernel. Their kernel
            // bytes must match a config from the authenticated lower image.
            run_capture ({"mtools", "-c", "mcopy", "-i", raw + "@@1048576",
                          dave ? "::/EFI/Linux/elementary-dave_*.efi" : "::/EFI/Linux/elementary_*.efi", directory});
            var files = File.new_for_path (directory).enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            string[] names = {};
            while ((info = files.next_file ()) != null) {
                if (info.get_file_type () != FileType.REGULAR || !info.get_name ().has_suffix (".efi")) {
                    throw new IOError.FAILED ("Invalid target UKI for sleep qualification");
                }
                names += info.get_name ();
            }
            files.close ();
            foreach (var name in names) {
                var kernel_image = directory + "/linux";
                uint8[] command_line = {};
                if (dave) {
                    var path = directory + "/cmdline";
                    run_capture ({"objcopy", "--dump-section", ".cmdline=" + path, directory + "/" + name});
                    File.new_for_path (path).load_contents (null, out command_line, null);
                    File.new_for_path (path).delete ();
                }
                run_capture ({"objcopy", "--dump-section", ".linux=" + kernel_image,
                              directory + "/" + name});
                var expected = run_capture ({"sha256sum", kernel_image}).split (" ")[0];
                var modules = File.new_for_path (fd_path (media.fds[5]) + "/usr/lib/modules");
                var versions = modules.enumerate_children (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? version;
                bool matched = false;
                while ((version = versions.next_file ()) != null) {
                    if (version.get_file_type () != FileType.DIRECTORY) continue;
                    var kernel = modules.get_child (version.get_name ());
                    var binary = kernel.get_child ("vmlinuz");
                    var config = kernel.get_child ("config");
                    foreach (var file in new File[] {binary, config}) {
                        Posix.Stat metadata;
                        if (Posix.lstat (file.get_path (), out metadata) != 0 ||
                            !Posix.S_ISREG (metadata.st_mode) || metadata.st_dev != media.identities[5].st_dev) {
                            throw new IOError.FAILED ("Invalid authenticated target kernel input");
                        }
                    }
                    if (run_capture ({"sha256sum", binary.get_path ()}).split (" ")[0] != expected) continue;
                    if (dave) SleepKernel.require_dave_hibernation (get_contents (config), command_line);
                    else SleepKernel.require_normal_hibernation (get_contents (config));
                    matched = true;
                }
                versions.close ();
                File.new_for_path (kernel_image).delete ();
                if (!matched) throw new IOError.NOT_SUPPORTED ("Target UKI has no matching authenticated kernel configuration");
            }
            if (names.length == 0) throw new IOError.NOT_SUPPORTED ("No target kernel qualified for hibernation");
        } catch (GLib.Error e) {
            error = e;
        }
        try {
            var files = File.new_for_path (directory).enumerate_children (
                FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = files.next_file ()) != null) {
                File.new_for_path (directory + "/" + info.get_name ()).delete ();
            }
            files.close ();
            File.new_for_path (directory).delete ();
        } catch (GLib.Error e) {
            if (error == null) error = e;
            else log_message (InstallerDaemon.LogLevel.WARN, "Sleep qualification cleanup failed: %s", e.message);
        }
        if (error != null) throw error;
    }

    private const uint64 GIB = 1024 * 1024 * 1024;

    [CCode (cname = "vale_swapfile_allocate", cheader_filename = "SwapFile.h")]
    private static extern int swapfile_allocate (int fd, uint64 size);

    [CCode (cname = "vale_swapfile_offset", cheader_filename = "SwapFile.h")]
    private static extern int swapfile_offset (int fd, uint64 size, out uint64 offset);

    [CCode (cname = "vale_loop_matches_partition", cheader_filename = "LoopBacking.h")]
    private static extern int loop_matches_partition (int loop_fd, int disk_fd, uint64 offset, uint64 size);

    private uint64 normal_swap_size () throws GLib.Error {
        MatchInfo match;
        var memory = get_contents (File.new_for_path ("/proc/meminfo"));
        var pattern = new Regex ("\\AMemTotal:[ \\t]+([0-9]+) kB\\n");
        uint64 kib = 0;
        if (!pattern.match (memory, 0, out match) || !uint64.try_parse (match.fetch (1), out kib) ||
            kib == 0 || kib > (uint64) int64.MAX / 2048) {
            throw new IOError.FAILED ("Could not determine swapfile memory capacity");
        }
        const uint64 MIB = 1024 * 1024;
        uint64 ram = kib * 1024;
        return ((ram + ram / 8 + 64 * MIB + MIB - 1) / MIB) * MIB;
    }

    private string provision_normal_swap (NormalRoot layout, string target, string work,
                                         string keyfile, uint64 size, int disk_fd, string source) throws GLib.Error {
        var plan = layout.root;
        string config = "";
        var path = work + "/target-root";
        File.new_for_path (path).make_directory ();
        string? loop = null;
        string? mapping = null;
        bool mounted = false;
        int swap_fd = -1;
        int loop_fd = -1;
        GLib.Error? error = null;
        try {
            // A bounded alias permits formatting while the whole disk remains claimed.
            loop = run_capture ({"losetup", "--find", "--show", "--offset",
                json_integer (plan, "offset").to_string (), "--sizelimit",
                json_integer (plan, "raw_size").to_string (), target});
            if (!Regex.match_simple ("^/dev/loop[0-9]+$", loop)) {
                throw new IOError.FAILED ("Invalid target ROOT loop mapping");
            }
            loop_fd = Posix.open (loop, Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            if (loop_fd < 0 || loop_matches_partition (loop_fd, disk_fd,
                (uint64) json_integer (plan, "offset"), (uint64) json_integer (plan, "raw_size")) != 0) {
                throw new IOError.FAILED ("Target ROOT alias does not match the reserved partition");
            }
            var filesystem = fd_path (loop_fd);
            if (keyfile != "") {
                var name = "vale-normal-root-" + Path.get_basename (work);
                run ({"cryptsetup", "open", "--type", "luks2", "--disable-external-tokens",
                      "--key-file", keyfile, fd_path (loop_fd), name});
                mapping = name;
                filesystem = "/dev/mapper/" + mapping;
                // The copied LUKS segment spans the partition; grow its small factory ext4 now.
                run ({"resize2fs", filesystem});
            }
            if (run_capture ({"blkid", "-p", "-s", "TYPE", "-o", "value", filesystem}) != "ext4") {
                throw new IOError.NOT_SUPPORTED ("Normal swap provisioning requires the admitted ext4 ROOT");
            }
            run ({"mount", "-t", "ext4", "-o", "nodev,nosuid,noexec", filesystem, path});
            mounted = true;
            swap_fd = Posix.open (path + "/swapfile", Posix.O_RDWR | Posix.O_CREAT | Posix.O_EXCL |
                                  Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0600);
            if (swap_fd < 0 || swapfile_allocate (swap_fd, size) != 0) {
                throw new IOError.FAILED ("Could not allocate persistent swapfile: %s", Posix.strerror (Posix.errno));
            }
            run ({"mkswap", fd_path (swap_fd)});
            uint64 offset;
            if (swapfile_offset (swap_fd, size, out offset) != 0) {
                throw new IOError.FAILED ("Persistent swapfile has no qualified physical resume offset");
            }
            var luks_uuid = keyfile == "" ? "none" : run_capture ({"cryptsetup", "luksUUID", fd_path (loop_fd)});
            config = layout.swap_config (luks_uuid, offset, size);
            NormalRoot.write_config (path, config);
            log_message (InstallerDaemon.LogLevel.INFO, "Qualified persistent swapfile at page offset %" + uint64.FORMAT, offset);
            var fstab = path + "/etc/fstab";
            Posix.Stat stat;
            if (Posix.lstat (path + "/etc", out stat) != 0 || !Posix.S_ISDIR (stat.st_mode)) {
                throw new IOError.FAILED ("Normal ROOT has no factory etc directory");
            }
            string contents = "";
            if (FileUtils.test (fstab, FileTest.EXISTS)) {
                if (Posix.lstat (fstab, out stat) != 0 || !Posix.S_ISREG (stat.st_mode)) {
                    throw new IOError.FAILED ("Factory fstab is not a regular file");
                }
                contents = get_contents (File.new_for_path (fstab));
                foreach (var line in contents.split ("\n")) {
                    if (line.strip ().has_prefix ("#") || line.strip () == "") continue;
                    var fields = Regex.split_simple ("\\s+", line.strip ());
                    if (fields.length >= 3 && (fields[0] == "/swapfile" || fields[2] == "swap")) {
                        throw new IOError.FAILED ("Factory fstab already configures swap");
                    }
                }
            }
            // Append through the existing inode to preserve its attributes and labels.
            int fstab_fd = Posix.open (fstab, Posix.O_WRONLY | Posix.O_APPEND | Posix.O_CREAT |
                                      Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0644);
            var entry = "\n/swapfile none swap defaults 0 0\n";
            bool saved = fstab_fd >= 0 && Posix.write (fstab_fd, entry.data, entry.length) == entry.length &&
                         Posix.fsync (fstab_fd) == 0;
            if (fstab_fd >= 0 && Posix.close (fstab_fd) != 0) saved = false;
            if (!saved) throw new IOError.FAILED ("Could not persist swapfile fstab entry");
            var sleep_directory = path + "/etc/systemd/sleep.conf.d";
            var logind_directory = path + "/etc/systemd/logind.conf.d";
            foreach (var directory in new string[] {sleep_directory, logind_directory}) {
                try { File.new_for_path (directory).make_directory_with_parents (); }
                catch (IOError.EXISTS e) {
                    if (Posix.lstat (directory, out stat) != 0 || !Posix.S_ISDIR (stat.st_mode)) throw e;
                }
            }
            var sleep_policy = sleep_directory + "/vale-normal.conf";
            var logind_policy = logind_directory + "/vale-normal.conf";
            FileUtils.set_contents (sleep_policy,
                "[Sleep]\nAllowHibernation=yes\nAllowHybridSleep=yes\n" +
                "AllowSuspendThenHibernate=no\nMemorySleepMode=deep\n");
            FileUtils.set_contents (logind_policy,
                "[Login]\nSleepOperation=hybrid-sleep hibernate\nHandleLidSwitch=sleep\nHandleSuspendKey=sleep\n");
            run ({"setfiles", "-F", "-r", path,
                source + "/usr/share/factory/etc/selinux/targeted/contexts/files/file_contexts",
                path + "/swapfile", path + "/etc/vale", fstab, sleep_directory, logind_directory});
            run ({"sync", "-f", path});
        } catch (GLib.Error e) { error = e; }
        if (swap_fd >= 0 && Posix.close (swap_fd) != 0 && error == null) {
            error = new IOError.FAILED ("Could not close persistent swapfile");
        }
        // Never detach a mapping whose mounted filesystem could not be released.
        try {
            if (mounted) run ({"umount", path});
            if (mapping != null) run ({"cryptsetup", "close", mapping});
            if (loop != null && Regex.match_simple ("^/dev/loop[0-9]+$", loop)) {
                run ({"losetup", "--detach", loop});
            }
            if (loop_fd >= 0 && Posix.close (loop_fd) != 0) {
                throw new IOError.FAILED ("Could not close target ROOT alias");
            }
            loop_fd = -1;
            File.new_for_path (path).delete ();
        } catch (GLib.Error e) {
            if (error == null) error = e;
            else log_message (InstallerDaemon.LogLevel.WARN, "Normal ROOT cleanup failed: %s", e.message);
        }
        if (loop_fd >= 0 && Posix.close (loop_fd) != 0 && error == null) {
            error = new IOError.FAILED ("Could not close target ROOT alias");
        }
        if (error != null) throw error;
        return config;
    }

    private void size_dave_hibernate (DaveInstall dave) throws GLib.Error {
        MatchInfo match;
        var memory = get_contents (File.new_for_path ("/proc/meminfo"));
        var pattern = new Regex ("\\AMemTotal:[ \\t]+([0-9]+) kB\\n");
        uint64 kib = 0;
        if (!pattern.match (memory, 0, out match) || !uint64.try_parse (match.fetch (1), out kib) ||
            kib == 0 || kib > (uint64) int64.MAX / 2048) {
            throw new IOError.FAILED ("Could not determine HIB memory capacity");
        }
        uint64 ram = kib * 1024;
        // The kernel compresses 32-page chunks into at most 35 pages. Allow
        // 1/8 extra plus 64 MiB for image/swap maps; repart reserves 32 MiB for LUKS2.
        dave.hibernate_payload = ram + ram / 8 + 64 * 1024 * 1024;
        const uint64 MIB = 1024 * 1024;
        dave.hibernate_size = ((dave.hibernate_payload + 32 * MIB + MIB - 1) / MIB) * MIB;
    }

    private Json.Object dave_hibernate_plan (string data, DaveInstall dave) throws GLib.Error {
        var node = parse_json (data, Json.NodeType.ARRAY);
        Json.Object? hibernate = null;
        foreach (var entry in node.get_array ().get_elements ()) {
            if (entry.get_node_type () != Json.NodeType.OBJECT) throw new IOError.FAILED ("Invalid HIB plan");
            var partition = entry.get_object ();
            if (json_string (partition, "type") != "swap") continue;
            if (hibernate != null) throw new IOError.FAILED ("Ambiguous HIB partition");
            hibernate = partition;
        }
        if (hibernate == null || json_string (hibernate, "label") != "vale-hibernate" ||
            !Uuid.string_is_valid (json_string (hibernate, "uuid")) ||
            json_string (hibernate, "uuid") == json_string (dave.root_plan, "uuid") ||
            json_integer (hibernate, "partno") == json_integer (dave.root_plan, "partno") ||
            json_integer (hibernate, "raw_size") != dave.hibernate_size) {
            throw new IOError.FAILED ("HIB differs from the required memory-bound reservation");
        }
        var offset = json_integer (hibernate, "offset");
        var root_offset = json_integer (dave.root_plan, "offset");
        var root_size = json_integer (dave.root_plan, "raw_size");
        if ((uint64) offset + dave.hibernate_size > (uint64) root_offset &&
            (uint64) root_offset + (uint64) root_size > (uint64) offset) {
            throw new IOError.FAILED ("ROOT and HIB overlap");
        }
        return hibernate;
    }

    private void prepare_dave_hibernate (DaveInstall dave, string work) throws GLib.Error {
        dave.hibernate_path = work + "/hibernate";
        File.new_for_path (dave.hibernate_path).make_directory ();
        // Offline repart would encrypt a full RAM-sized scratch file. A sparse
        // LUKS image needs only its header and empty swap header before CopyBlocks.
        run ({"mount", "-t", "tmpfs", "-o", "size=64M,mode=0700,noswap,nodev,nosuid,noexec",
              "tmpfs", dave.hibernate_path});
        dave.hibernate_mounted = true;
        dave.hibernate_image_fd = Posix.open (dave.hibernate_path + "/image",
            Posix.O_CREAT | Posix.O_EXCL | Posix.O_RDWR | Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0600);
        if (dave.hibernate_image_fd < 0 || Posix.ftruncate (dave.hibernate_image_fd, (Posix.off_t) dave.hibernate_size) != 0) {
            throw new IOError.FAILED ("Could not reserve bounded HIB formatting storage");
        }
        var image = fd_path (dave.hibernate_image_fd);
        dave_crypto ({"luksFormat", "--batch-mode", "--type", "luks2", "--pbkdf", "argon2id",
                      "--cipher", "aes-xts-plain64", "--key-size", "512",
                      "--key-file", fd_path (dave.hibernate_recovery), image});
        var mapping = "elementary-installer-hibernate-" + Uuid.string_random ();
        dave_crypto ({"open", "--disable-external-tokens", "--key-slot", "0",
                      "--key-file", fd_path (dave.hibernate_recovery), image, mapping});
        dave.hibernate_mapping = mapping;
        GLib.Error? error = null;
        try { run ({"/usr/sbin/mkswap", "/dev/mapper/" + mapping}); } catch (GLib.Error e) { error = e; }
        try {
            dave_crypto ({"close", mapping});
            dave.hibernate_mapping = null;
        } catch (GLib.Error e) { if (error == null) error = e; }
        if (error != null) throw error;
        dave.hibernate_uuid = dave_crypto ({"luksUUID", image});
        if (!Uuid.string_is_valid (dave.hibernate_uuid) || dave.hibernate_uuid == dave.uuid) {
            throw new IOError.FAILED ("HIB requires an independent LUKS identity");
        }
        var initial = dave_metadata (image, false);
        var segment = initial.get_object_member ("segments").get_object_member ("0");
        uint64 offset;
        if (!uint64.try_parse (json_string (segment, "offset"), out offset) ||
            offset >= dave.hibernate_size || dave.hibernate_size - offset < dave.hibernate_payload ||
            json_string (segment, "size") != "dynamic") {
            throw new IOError.FAILED ("HIB encrypted payload is too small for memory");
        }
        dave_crypto ({"luksAddKey", "--batch-mode", "--disable-external-tokens", "--key-slot", "0", "--new-key-slot", "1",
                      "--key-file", fd_path (dave.hibernate_recovery), "--new-keyfile", fd_path (dave.bootstrap_fd), image});
        dave.hibernate_metadata = dave_metadata (image, true);
        check_recovery_preserved (initial, dave.hibernate_metadata);
        check_dave_hibernate_keys (dave, image);
        if (Posix.fsync (dave.hibernate_image_fd) != 0 ||
            Posix.fstat (dave.hibernate_image_fd, out dave.hibernate_image) != 0 ||
            dave.hibernate_image.st_size != dave.hibernate_size ||
            dave.hibernate_image.st_blocks > 64 * 1024 * 1024 / 512) {
            throw new IOError.FAILED ("HIB exceeded its bounded formatting storage");
        }
        int writable = dave.hibernate_image_fd;
        dave.hibernate_image_fd = Posix.open (image, Posix.O_RDONLY | Posix.O_CLOEXEC);
        bool closed = Posix.close (writable) == 0;
        if (dave.hibernate_image_fd < 0 || !closed) throw new IOError.FAILED ("Could not retain prepared HIB");
        run ({"mount", "-o", "remount,ro", dave.hibernate_path});
    }

    private void prepare_root_image (PreparedRoot root, string work, string definitions,
                                     string source, string keyfile, DaveInstall? dave) throws GLib.Error {
        root.path = work + "/root-image";
        File.new_for_path (root.path).make_directory ();
        // The current factory ROOT is small; /usr is copied separately. Bound
        // both the encrypted image and native repart's temporary filesystem.
        run ({"mount", "-t", "tmpfs", "-o", "size=768M,mode=0700,noswap,nodev,nosuid,noexec", "tmpfs", root.path});
        root.mounted = true;
        var private_definitions = root.path + "/repart";
        File.new_for_path (private_definitions).make_directory ();
        var original = get_contents (File.new_for_path (definitions + "/40-root.conf"));
        var sizing = new Regex ("^(SizeMinBytes|Weight)=.*$", RegexCompileFlags.MULTILINE);
        var bounded = sizing.replace (original, original.length, 0, "");
        bounded += "SizeMinBytes=256M\nSizeMaxBytes=256M\nWeight=0\nSplitName=prepared-root\n";
        if (keyfile != "") bounded += "KeyFile=" + keyfile + "\n";
        FileUtils.set_contents (private_definitions + "/40-root.conf", bounded);
        var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        launcher.setenv ("TMPDIR", root.path, true);
        if (dave == null) {
            // Small ext4 seeds default to 1 KiB blocks; swap extents must align
            // to x86-64 pages even after the destination filesystem grows.
            launcher.setenv ("SYSTEMD_REPART_MKFS_OPTIONS_EXT4", "-b 4096", true);
        }
        var child = launcher.spawnv ({"systemd-repart", "--offline=yes", "--empty=create", "--size=258M",
            "--factory-reset=no", "--dry-run=no", "--split=yes", "--definitions=" + private_definitions,
            "--copy-source=" + source, root.path + "/disk.raw"});
        string output;
        string error;
        child.communicate_utf8 (null, null, out output, out error);
        if (!child.get_successful ()) {
            throw new IOError.FAILED ("Factory ROOT could not be prepared within its bounded formatting storage");
        }
        File.new_for_path (root.path + "/disk.raw").delete ();
        root.fd = Posix.open (root.path + "/disk.prepared-root.raw", Posix.O_RDWR | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
        if (root.fd < 0 || Posix.fstat (root.fd, out root.identity) != 0 ||
            !Posix.S_ISREG (root.identity.st_mode) || root.identity.st_size != 256 * 1024 * 1024) {
            throw new IOError.FAILED ("Could not retain bounded encrypted ROOT");
        }
        if (dave != null) {
            add_dave_owner_key (dave, fd_path (root.fd));
        } else {
            run_capture ({"/usr/sbin/cryptsetup", "open", "--test-passphrase", "--disable-external-tokens",
                          "--key-file", keyfile, fd_path (root.fd)});
        }
        if (Posix.fsync (root.fd) != 0 || Posix.fstat (root.fd, out root.identity) != 0) {
            throw new IOError.FAILED ("Could not sync prepared ROOT");
        }
        int writable = root.fd;
        root.fd = Posix.open (fd_path (writable), Posix.O_RDONLY | Posix.O_CLOEXEC);
        bool closed = Posix.close (writable) == 0;
        if (root.fd < 0 || !closed) throw new IOError.FAILED ("Could not retain prepared ROOT");
        run ({"mount", "-o", "remount,ro", root.path});
        // Copy the smaller LUKS image directly into the full planned partition.
        // Normal grows ext4 before allocating swap; Dave retains firstboot growth.
        var formatting = new Regex ("^(Format|Encrypt|CopyFiles|KeyFile)=.*$", RegexCompileFlags.MULTILINE);
        var copy = formatting.replace (original, original.length, 0, "");
        FileUtils.set_contents (definitions + "/40-root.conf", copy +
            "CopyBlocks=" + fd_path (root.fd) + "\nGrowFileSystem=yes\n");
    }

    private void check_root_image (PreparedRoot root) throws GLib.Error {
        if (root.fd < 0) return;
        Posix.Stat current;
        if (Posix.fstat (root.fd, out current) != 0 || current.st_dev != root.identity.st_dev ||
            current.st_ino != root.identity.st_ino || current.st_size != root.identity.st_size ||
            current.st_mtime != root.identity.st_mtime || current.st_ctime != root.identity.st_ctime) {
            throw new IOError.FAILED ("Prepared ROOT changed");
        }
        check_source_mount (root.path, current.st_dev, "tmpfs");
    }

    private void cleanup_root_image (PreparedRoot root) throws GLib.Error {
        int fd = root.fd;
        root.fd = -1;
        bool closed = fd < 0 || Posix.close (fd) == 0;
        if (root.mounted) {
            run ({"umount", root.path});
            root.mounted = false;
        }
        if (root.path != null) File.new_for_path (root.path).delete ();
        if (!closed) throw new IOError.FAILED ("Could not close prepared ROOT");
    }

    private void fsync_path (string path, bool directory = false) throws GLib.Error {
        int fd = Posix.open (path, Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC |
                            (directory ? Posix.O_DIRECTORY : 0));
        if (fd < 0) throw new IOError.FAILED ("Could not open private staged input");
        bool synced = Posix.fsync (fd) == 0;
        bool closed = Posix.close (fd) == 0;
        if (!synced || !closed) throw new IOError.FAILED ("Could not sync/close private staged input");
    }

    private void write_dave_file (string path, uint8[] bytes) throws GLib.Error {
        var stream = File.new_for_path (path).create (FileCreateFlags.PRIVATE);
        GLib.Error? error = null;
        try {
            size_t written;
            stream.write_all (bytes, out written);
            if (written != bytes.length) throw new IOError.FAILED ("Private staging short write");
            stream.flush ();
        } catch (GLib.Error e) {
            error = e;
        }
        try { stream.close (); } catch (GLib.Error e) { if (error == null) error = e; }
        if (error != null) throw error;
        fsync_path (path);
    }

    private void copy_dave_credential (int fd, string path) throws GLib.Error {
        FileInputStream? input = null;
        FileOutputStream? output = null;
        GLib.Error? error = null;
        try {
            input = File.new_for_path (fd_path (fd)).read ();
            output = File.new_for_path (path).create (FileCreateFlags.PRIVATE);
            var copied = output.splice (input, OutputStreamSpliceFlags.NONE);
            Posix.Stat original;
            if (Posix.fstat (fd, out original) != 0 || copied != original.st_size) {
                throw new IOError.FAILED ("Incomplete private credential staging");
            }
            output.flush ();
        } catch (GLib.Error e) { error = e; }
        if (output != null) {
            try { output.close (); } catch (GLib.Error e) { if (error == null) error = e; }
        }
        if (input != null) {
            try { input.close (); } catch (GLib.Error e) { if (error == null) error = e; }
        }
        if (error != null) throw error;
        fsync_path (path);
    }

    private void stage_dave (DaveInstall dave, MediaSource media, string work, string definitions) throws GLib.Error {
        var copy = work + "/copy";
        dave.copy_path = copy;
        File.new_for_path (copy).make_directory ();
        // Secrets exist only in this noswap staging tree and encrypted ROOT.
        run ({"mount", "-t", "tmpfs", "-o", "size=64K,mode=0700,noswap,nodev,nosuid,noexec", "tmpfs", copy});
        dave.copy_mounted = true;
        File.new_for_path (copy + "/etc/vale").make_directory_with_parents ();
        if (Posix.chmod (copy + "/etc/vale", 0700) != 0) {
            throw new IOError.FAILED ("Could not protect private credential directory");
        }
        File.new_for_path (copy + "/var/lib/flatpak").make_directory_with_parents ();
        var factory = copy + "/usr/share/vale/install-root";
        File.new_for_path (factory).make_directory_with_parents ();
        copy_dave_credential (dave.owner, copy + "/etc/vale/dave-owner");
        copy_dave_credential (dave.hibernate_recovery, copy + "/etc/vale/hibernate-recovery");
        copy_dave_credential (dave.bootstrap_fd, copy + "/etc/vale/hibernate-bootstrap");
        var config = "ROOT_UUID=%s\nOWNER=%s\nOWNER_SLOT=1\nRECOVERY_SLOT=0\nSRK_NAME=%s\n".printf (
            dave.uuid, dave.username, dave.srk_name);
        write_dave_file (copy + "/etc/vale/root-key.conf", config.data);
        write_dave_file (copy + "/etc/crypttab", ("root UUID=" + dave.uuid + " none luks\n").data);
        var accounts = copy + "/var/lib/AccountsService/users";
        File.new_for_path (accounts).make_directory_with_parents ();
        if (Posix.chmod (copy + "/var/lib/AccountsService", 0775) != 0 || Posix.chmod (accounts, 0700) != 0) {
            throw new IOError.FAILED ("Could not set account preference directory permissions");
        }
        var layouts = KeyboardSources.from_layout (dave.keyboard_layout, dave.keyboard_variant);
        var preferences = new KeyFile ();
        preferences.set_string ("User", "Language", dave.lang);
        // The greeter and session daemon already consume this AccountsService extension.
        preferences.set_string ("io.elementary.SettingsDaemon.AccountsService", "KeyboardLayouts", layouts.print (false));
        write_dave_file (accounts + "/" + dave.username, preferences.to_data ().data);
        // Label private files before binding the read-only factory and Flatpak sources.
        run ({"setfiles", "-m", "-r", copy, "/etc/selinux/targeted/contexts/files/file_contexts", copy});
        foreach (var dir in new string[] {
            "etc/vale", "etc", "var/lib/AccountsService/users", "var/lib/AccountsService",
            "var/lib/flatpak", "var/lib", "var", ""
        }) {
            fsync_path (copy + "/" + dir, true);
        }
        bind_lower_directory (media, {"usr", "share", "vale", "install-root"},
                              factory, ref dave.factory_mounted);
        bind_lower_directory (media, {"var", "lib", "flatpak"},
                              copy + "/var/lib/flatpak", ref dave.flatpak_mounted);
        run ({"mount", "-o", "remount,ro", copy});
        dave.copy_fd = Posix.open (copy, Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
        if (dave.copy_fd < 0) throw new IOError.FAILED ("Could not retain DAVE copy tree");
        var paths = new string[] {"etc/vale/dave-owner", "etc/vale/root-key.conf", "etc/crypttab",
                                 "var/lib/AccountsService/users/" + dave.username,
                                 "etc/vale/hibernate-recovery", "etc/vale/hibernate-bootstrap"};
        for (int i = 0; i < paths.length; i++) {
            dave.staged_fds[i] = Posix.open (copy + "/" + paths[i], Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            if (dave.staged_fds[i] < 0 || Posix.fstat (dave.staged_fds[i], out dave.staged[i]) != 0 ||
                !Posix.S_ISREG (dave.staged[i].st_mode) || dave.staged[i].st_uid != 0 ||
                (dave.staged[i].st_mode & 0777) != 0600 || dave.staged[i].st_nlink != 1) {
                throw new IOError.FAILED ("Could not retain private staged file");
            }
        }
        set_repart_encryption (definitions, "key-file");
        var definition = File.new_for_path (definitions + "/40-root.conf");
        var text = get_contents (definition);
        var label = new Regex ("^Label=.*$", RegexCompileFlags.MULTILINE);
        MatchInfo match;
        if (!label.match (text, 0, out match) || match.next ()) {
            throw new IOError.FAILED ("DAVE requires one factory ROOT label setting");
        }
        // Installed DAVE admission uses GPT PARTLABEL, not an ext4 label
        // (which has a shorter length limit). Change only this private copy.
        text = label.replace (text, text.length, 0, "Label=elementary-root-dave");
        FileUtils.set_contents (definitions + "/40-root.conf", text +
            "KeyFile=" + fd_path (dave.recovery) + "\n" +
            "CopyFiles=/etc/vale/dave-owner:/etc/vale/dave-owner\n" +
            "CopyFiles=/etc/vale/root-key.conf:/etc/vale/root-key.conf\n" +
            "CopyFiles=/etc/crypttab:/etc/crypttab\n" +
            "CopyFiles=/etc/vale/hibernate-recovery:/etc/vale/hibernate-recovery\n" +
            "CopyFiles=/etc/vale/hibernate-bootstrap:/etc/vale/hibernate-bootstrap\n" +
            "CopyFiles=/var/lib/AccountsService/users:/var/lib/AccountsService/users\n");
        // No global --key-file: native repart gives it precedence over KeyFile=.
        // Reserve HIB before ROOT growth; only this new partition receives mkswap.
        FileUtils.set_contents (definitions + "/30-hibernate.conf",
            "[Partition]\nType=swap\nNoAuto=yes\nLabel=vale-hibernate\n" +
            "CopyBlocks=" + fd_path (dave.hibernate_image_fd) + "\n" +
            "SizeMinBytes=" + dave.hibernate_size.to_string () + "\n" +
            "SizeMaxBytes=" + dave.hibernate_size.to_string () + "\nWeight=0\n");
        check_dave_stage (dave, media);
    }

    private void bind_lower_directory (MediaSource media, string[] components, string target,
                                       ref bool mounted) throws GLib.Error {
        // Resolve each authenticated lower directory without following symlinks.
        int parent = Posix.dup (media.fds[5]);
        if (parent < 0) throw new IOError.FAILED ("Could not retain admitted lower");
        GLib.Error? error = null;
        try {
            foreach (var component in components) {
                int child = Posix.openat (parent, component, Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
                int previous = parent;
                parent = child;
                if (Posix.close (previous) != 0 || child < 0) throw new IOError.FAILED ("Invalid admitted lower directory");
            }
            Posix.Stat lower;
            if (Posix.fstat (parent, out lower) != 0 || lower.st_dev != media.identities[5].st_dev) {
                throw new IOError.FAILED ("Input is outside authenticated lower");
            }
            run ({"mount", "--bind", fd_path (parent), target});
            mounted = true;
            run ({"mount", "-o", "remount,bind,ro,nodev,nosuid,noexec", target});
        } catch (GLib.Error e) {
            error = e;
        }
        if (parent >= 0 && Posix.close (parent) != 0 && error == null) {
            error = new IOError.FAILED ("Could not close lower directory");
        }
        if (error != null) throw error;
    }

    private void check_dave_stage (DaveInstall dave, MediaSource media) throws GLib.Error {
        Posix.Stat staged_root;
        if (Posix.fstat (dave.copy_fd, out staged_root) != 0 || !Posix.S_ISDIR (staged_root.st_mode)) {
            throw new IOError.FAILED ("DAVE staging directory changed");
        }
        check_source_mount (dave.copy_path, staged_root.st_dev, "tmpfs");
        Posix.Stat hibernate;
        if (Posix.fstat (dave.hibernate_image_fd, out hibernate) != 0 ||
            hibernate.st_dev != dave.hibernate_image.st_dev || hibernate.st_ino != dave.hibernate_image.st_ino ||
            hibernate.st_size != dave.hibernate_image.st_size || hibernate.st_mtime != dave.hibernate_image.st_mtime ||
            hibernate.st_ctime != dave.hibernate_image.st_ctime) {
            throw new IOError.FAILED ("Prepared HIB image changed");
        }
        check_source_mount (dave.hibernate_path, hibernate.st_dev, "tmpfs");
        check_source_mount (dave.copy_path + "/usr/share/vale/install-root", media.identities[5].st_dev,
                            "squashfs", "/usr/share/vale/install-root");
        check_source_mount (dave.copy_path + "/var/lib/flatpak", media.identities[5].st_dev,
                            "squashfs", "/var/lib/flatpak");
        var paths = new string[] {"etc/vale/dave-owner", "etc/vale/root-key.conf", "etc/crypttab",
                                 "var/lib/AccountsService/users/" + dave.username,
                                 "etc/vale/hibernate-recovery", "etc/vale/hibernate-bootstrap"};
        for (int i = 0; i < paths.length; i++) {
            Posix.Stat current;
            if (Posix.stat (fd_path (dave.copy_fd) + "/" + paths[i], out current) != 0 ||
                current.st_dev != dave.staged[i].st_dev || current.st_ino != dave.staged[i].st_ino ||
                current.st_size != dave.staged[i].st_size || current.st_mtime != dave.staged[i].st_mtime ||
                current.st_ctime != dave.staged[i].st_ctime) {
                throw new IOError.FAILED ("DAVE staged input changed");
            }
        }
    }

    private string dave_crypto (string[] arguments, bool success = true) throws GLib.Error {
        string[] argv = {"/usr/sbin/cryptsetup"};
        foreach (var argument in arguments) argv += argument;
        var child = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        string output;
        string error;
        child.communicate_utf8 (null, null, out output, out error);
        if (!child.get_if_exited () || child.get_successful () != success) {
            // Credentials never occur in argv, and child errors need not be
            // forwarded to the caller or log to establish proof failure.
            throw new IOError.FAILED ("DAVE stock cryptsetup proof failed");
        }
        return output.strip ();
    }

    private Json.Object dave_metadata (string root, bool two_slots) throws GLib.Error {
        var parsed = parse_json (dave_crypto ({"luksDump", "--dump-json-metadata", root}), Json.NodeType.OBJECT);
        var metadata = parsed.get_object ();
        var slots = json_member (metadata, "keyslots", Json.NodeType.OBJECT).get_object ();
        var tokens = json_member (metadata, "tokens", Json.NodeType.OBJECT).get_object ();
        var segments = json_member (metadata, "segments", Json.NodeType.OBJECT).get_object ();
        var digests = json_member (metadata, "digests", Json.NodeType.OBJECT).get_object ();
        if (slots.get_size () != (two_slots ? 2 : 1) || !slots.has_member ("0") || (two_slots && !slots.has_member ("1")) ||
            tokens.get_size () != 0 || segments.get_size () != 1 || !segments.has_member ("0") || digests.get_size () != 1) {
            throw new IOError.FAILED ("Unexpected DAVE slots, tokens or segments");
        }
        var segment = json_member (segments, "0", Json.NodeType.OBJECT).get_object ();
        if (json_string (segment, "type") != "crypt" || json_string (segment, "encryption") != "aes-xts-plain64") {
            throw new IOError.FAILED ("Unexpected DAVE crypt segment");
        }
        foreach (var name in slots.get_members ()) {
            var slot = json_member (slots, name, Json.NodeType.OBJECT).get_object ();
            var kdf = json_member (slot, "kdf", Json.NodeType.OBJECT).get_object ();
            var algorithm = json_string (kdf, "type");
            if (json_string (slot, "type") != "luks2" || json_integer (slot, "key_size") != 64 ||
                (algorithm != "argon2id" && algorithm != "argon2i")) {
                throw new IOError.FAILED ("Unexpected DAVE password keyslot");
            }
        }
        var digest = json_member (digests, digests.get_members ().data, Json.NodeType.OBJECT).get_object ();
        var bound = json_member (digest, "keyslots", Json.NodeType.ARRAY).get_array ();
        var crypt = json_member (digest, "segments", Json.NodeType.ARRAY).get_array ();
        if (bound.get_length () != (two_slots ? 2 : 1) || crypt.get_length () != 1 ||
            crypt.get_element (0).get_string () != "0" || bound.get_element (0).get_string () != "0" ||
            (two_slots && bound.get_element (1).get_string () != "1")) {
            throw new IOError.FAILED ("DAVE slots do not share the expected segment");
        }
        return metadata;
    }

    private int open_dave_partition (Json.Object plan, string destination) throws GLib.Error {
        var parent = File.new_for_path ("/sys/block/" + Path.get_basename (destination));
        var children = parent.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        string? path = null;
        FileInfo? info;
        GLib.Error? error = null;
        try {
            while ((info = children.next_file ()) != null) {
                var child = parent.get_child (info.get_name ());
                if (!child.get_child ("partition").query_exists ()) continue;
                uint64 number = 0;
                uint64 sector = 0;
                if (!uint64.try_parse (get_contents (child.get_child ("partition")).strip (), out number) ||
                    !uint64.try_parse (get_contents (child.get_child ("start")).strip (), out sector)) {
                    throw new IOError.FAILED ("Invalid selected partition topology");
                }
                if (number == json_integer (plan, "partno") + 1 && sector <= uint64.MAX / 512 &&
                    sector * 512 == json_integer (plan, "offset") &&
                    get_contents (child.get_child ("size")).strip () ==
                        (json_integer (plan, "raw_size") / 512).to_string ()) {
                    if (path != null) throw new IOError.FAILED ("Ambiguous selected DAVE partition");
                    path = "/dev/" + info.get_name ();
                }
            }
        } catch (GLib.Error e) { error = e; }
        try { children.close (); } catch (GLib.Error e) { if (error == null) error = e; }
        if (error != null) throw error;
        if (path == null) throw new IOError.FAILED ("Selected DAVE partition unavailable");
        var number = get_contents (parent.get_child (Path.get_basename (path)).get_child ("dev")).strip ();
        int fd = Posix.open (path, Posix.O_RDWR | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
        Posix.Stat opened = Posix.Stat ();
        if (fd < 0 || Posix.fstat (fd, out opened) != 0 || !Posix.S_ISBLK (opened.st_mode) ||
            number != device_number (opened.st_rdev)) {
            if (fd >= 0) Posix.close (fd);
            throw new IOError.FAILED ("Could not retain selected DAVE partition");
        }
        return fd;
    }

    private void check_recovery_preserved (Json.Object initial, Json.Object metadata) throws GLib.Error {
        var before = initial.get_object_member ("keyslots").get_member ("0");
        var after = metadata.get_object_member ("keyslots").get_member ("0");
        if (!before.equal (after) || !initial.get_member ("segments").equal (metadata.get_member ("segments"))) {
            throw new IOError.FAILED ("DAVE Recovery slot or segment changed");
        }
        var old_digests = initial.get_object_member ("digests");
        var new_digests = metadata.get_object_member ("digests");
        var digest_name = old_digests.get_members ().data;
        if (!new_digests.has_member (digest_name)) throw new IOError.FAILED ("DAVE Recovery digest changed");
        var old_digest = old_digests.get_object_member (digest_name);
        var new_digest = new_digests.get_object_member (digest_name);
        if (old_digest.get_size () != new_digest.get_size ()) throw new IOError.FAILED ("DAVE Recovery digest changed");
        foreach (var name in old_digest.get_members ()) {
            if (name != "keyslots" && (!new_digest.has_member (name) ||
                !old_digest.get_member (name).equal (new_digest.get_member (name)))) {
                throw new IOError.FAILED ("DAVE Recovery digest changed");
            }
        }
    }

    private void add_dave_owner_key (DaveInstall dave, string root_fd) throws GLib.Error {
        var initial = dave_metadata (root_fd, false);
        dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens", "--key-slot", "0",
                      "--key-file", fd_path (dave.recovery), root_fd});
        dave_crypto ({"luksUUID", "--batch-mode", "--uuid", dave.uuid, root_fd});
        if (dave_crypto ({"luksUUID", root_fd}) != dave.uuid || !initial.equal (dave_metadata (root_fd, false))) {
            throw new IOError.FAILED ("Chosen ROOT UUID proof failed");
        }
        dave_crypto ({"luksAddKey", "--batch-mode", "--disable-external-tokens", "--key-slot", "0", "--new-key-slot", "1",
                      "--key-file", fd_path (dave.recovery), "--new-keyfile", fd_path (dave.owner),
                      "--new-keyfile-offset", dave.password_offset.to_string (), "--new-keyfile-size", dave.password_size.to_string (), root_fd});
        dave.metadata = dave_metadata (root_fd, true);
        check_recovery_preserved (initial, dave.metadata);
        check_dave_root_keys (dave, root_fd);
    }

    private void check_dave_root_keys (DaveInstall dave, string root_fd) throws GLib.Error {
        if (dave_crypto ({"luksUUID", root_fd}) != dave.uuid || !dave.metadata.equal (dave_metadata (root_fd, true))) {
            throw new IOError.FAILED ("Installed ROOT differs from the prepared image");
        }
        foreach (var slot in new string[] {"0", "1"}) {
            dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens", "--key-slot", slot,
                          "--key-file", fd_path (dave.recovery), root_fd}, slot == "0");
            dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens", "--key-slot", slot,
                          "--key-file", fd_path (dave.owner), "--keyfile-offset", dave.password_offset.to_string (),
                          "--keyfile-size", dave.password_size.to_string (), root_fd}, slot == "1");
        }
        dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens",
                      "--key-file", fd_path (dave.hibernate_recovery), root_fd}, false);
    }

    private void prove_dave_root (DaveInstall dave, string destination, int target_fd, Posix.Stat selected,
                                  string sequence, string result) throws GLib.Error {
        var root = dave_root_plan (result);
        foreach (var name in new string[] {"uuid", "partno", "offset"}) {
            if (!root.get_member (name).equal (dave.root_plan.get_member (name))) {
                throw new IOError.FAILED ("DAVE ROOT differs from admitted plan");
            }
        }
        validate_target (destination, target_fd, selected, sequence);
        dave.root_fd = open_dave_partition (root, destination);
        var root_fd = fd_path (dave.root_fd);
        check_dave_root_keys (dave, root_fd);
        if (Posix.fsync (dave.root_fd) != 0 || Posix.fsync (target_fd) != 0) {
            throw new IOError.FAILED ("Could not sync installed DAVE ROOT");
        }
        validate_target (destination, target_fd, selected, sequence);
    }

    private void prove_dave_hibernate (DaveInstall dave, string destination, int target_fd,
                                       Posix.Stat selected, string sequence, string result) throws GLib.Error {
        var plan = dave_hibernate_plan (result, dave);
        foreach (var name in new string[] {"uuid", "partno", "offset", "raw_size"}) {
            if (!plan.get_member (name).equal (dave.hibernate_plan.get_member (name))) {
                throw new IOError.FAILED ("HIB differs from admitted plan");
            }
        }
        validate_target (destination, target_fd, selected, sequence);
        dave.hibernate_fd = open_dave_partition (plan, destination);
        Posix.Stat root = Posix.Stat ();
        Posix.Stat hibernate = Posix.Stat ();
        if (Posix.fstat (dave.root_fd, out root) != 0 || Posix.fstat (dave.hibernate_fd, out hibernate) != 0 ||
            root.st_rdev == hibernate.st_rdev) throw new IOError.FAILED ("HIB is not independent of ROOT");
        var device = fd_path (dave.hibernate_fd);
        check_dave_hibernate_keys (dave, device);
        if (Posix.fsync (dave.hibernate_fd) != 0 || Posix.fsync (target_fd) != 0) {
            throw new IOError.FAILED ("Could not sync installed HIB");
        }
        validate_target (destination, target_fd, selected, sequence);
    }

    private void check_dave_hibernate_keys (DaveInstall dave, string device) throws GLib.Error {
        if (dave_crypto ({"luksUUID", device}) != dave.hibernate_uuid ||
            !dave.hibernate_metadata.equal (dave_metadata (device, true))) {
            throw new IOError.FAILED ("Installed HIB differs from the prepared image");
        }
        foreach (var slot in new string[] {"0", "1"}) {
            dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens", "--key-slot", slot,
                          "--key-file", fd_path (dave.hibernate_recovery), device}, slot == "0");
            dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens", "--key-slot", slot,
                          "--key-file", fd_path (dave.bootstrap_fd), device}, slot == "1");
        }
        dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens",
                      "--key-file", fd_path (dave.recovery), device}, false);
        dave_crypto ({"open", "--test-passphrase", "--disable-external-tokens",
                      "--key-file", fd_path (dave.owner), "--keyfile-offset", dave.password_offset.to_string (),
                      "--keyfile-size", dave.password_size.to_string (), device}, false);
    }

    private void check_hibernate_publication (DaveInstall dave) throws GLib.Error {
        if (dave_crypto ({"luksUUID", fd_path (dave.hibernate_fd)}) != dave.hibernate_uuid ||
            !dave.hibernate_metadata.equal (dave_metadata (fd_path (dave.hibernate_fd), true))) {
            throw new IOError.FAILED ("Boot publication changed HIB");
        }
    }

    private void require_dave_boot_selection () throws GLib.Error {
        if (NormalBoot.read_variable ("BootNext", NormalBoot.EFI) != null ||
            NormalBoot.read_variable ("LoaderEntryOneShot", NormalBoot.LOADER) != null ||
            NormalBoot.read_variable ("LoaderEntrySysFail", NormalBoot.LOADER) != null) {
            throw new IOError.BUSY ("Resolve pending boot selections before installing DAVE");
        }
        // EFI defaults take precedence over the target's loader.conf.
        var value = NormalBoot.read_variable ("LoaderEntryDefault", NormalBoot.LOADER);
        if (value != null) {
            var selection = NormalBoot.loader_string (value);
            if (selection != "elementary-dave_*" &&
                !Regex.match_simple ("\\Aelementary-dave_[0-9]+(?:_x86-64)?\\.efi\\z", selection)) {
                throw new IOError.BUSY ("Resolve the incompatible EFI boot default before installing DAVE");
            }
        }
    }

    private void publish_dave_boot (DaveInstall dave, string[] first, string destination, string work,
                                    int target_fd, Posix.Stat selected, string sequence) throws GLib.Error {
        require_dave_boot_selection ();
        string[] publish = {};
        foreach (var argument in first) {
            if (argument == "--empty=force") {
                publish += "--empty=refuse";
            } else if (argument == "--defer-partitions=esp,xbootldr") {
                publish += "--defer-partitions=root-x86-64,usr-x86-64,usr-x86-64-verity,usr-x86-64-verity-sig,swap";
            } else if (argument == "--dry-run=no") {
                publish += "--dry-run=yes";
            } else {
                publish += argument;
            }
        }
        var publication = run_capture (publish);
        var plan = dave_root_plan (publication);
        var hibernate_plan = dave_hibernate_plan (publication, dave);
        foreach (var name in new string[] {"uuid", "partno", "offset", "raw_size"}) {
            if (!hibernate_plan.get_member (name).equal (dave.hibernate_plan.get_member (name))) {
                throw new IOError.FAILED ("Boot publication would change HIB");
            }
        }
        check_hibernate_publication (dave);
        foreach (var name in new string[] {"uuid", "partno", "offset"}) {
            if (!plan.get_member (name).equal (dave.root_plan.get_member (name))) {
                throw new IOError.FAILED ("Boot publication would change DAVE ROOT");
            }
        }
        validate_target (destination, target_fd, selected, sequence);
        if (dave_crypto ({"luksUUID", fd_path (dave.root_fd)}) != dave.uuid ||
            !dave.metadata.equal (dave_metadata (fd_path (dave.root_fd), true))) {
            throw new IOError.FAILED ("DAVE ROOT changed before boot publication");
        }
        for (int i = 0; i < publish.length; i++) {
            if (publish[i] == "--dry-run=yes") publish[i] = "--dry-run=no";
        }
        var published = parse_json (run_capture (publish), Json.NodeType.ARRAY);
        int64 esp_offset = 0;
        foreach (var entry in published.get_array ().get_elements ()) {
            var partition = entry.get_object ();
            if (json_string (partition, "type") == "esp") {
                if (esp_offset != 0) throw new IOError.FAILED ("Ambiguous DAVE ESP");
                esp_offset = json_integer (partition, "offset");
            }
        }
        if (esp_offset == 0 || esp_offset % 512 != 0) {
            throw new IOError.FAILED ("Invalid DAVE ESP offset");
        }
        // Use the retained whole-disk descriptor; never mount the claimed target.
        var esp = fd_path (target_fd) + "@@" + esp_offset.to_string ();
        run_capture ({"mtools", "-c", "mdir", "-i", esp, "::/EFI/Linux/elementary-dave_*.efi"});
        var config = run_capture ({"mtools", "-c", "mtype", "-i", esp, "::/loader/loader.conf"});
        var defaults = new Regex ("^default[\\t ]+.*$", MULTILINE);
        config = defaults.replace (config, config.length, 0, "") + "\ndefault elementary-dave_*\n";
        var staged_config = Path.build_filename (work, "repart", "dave-loader");
        FileUtils.set_contents (staged_config, config);
        validate_target (destination, target_fd, selected, sequence);
        run_capture ({"mtools", "-c", "mcopy", "-o", "-i", esp, staged_config, "::/loader/loader.conf"});
        if (run_capture ({"mtools", "-c", "mtype", "-i", esp, "::/loader/loader.conf"}) != config.strip ()) {
            throw new IOError.FAILED ("Could not verify DAVE boot selection");
        }
        if (Posix.fsync (target_fd) != 0) throw new IOError.FAILED ("Could not sync DAVE boot publication");
        if (dave_crypto ({"luksUUID", fd_path (dave.root_fd)}) != dave.uuid ||
            !dave.metadata.equal (dave_metadata (fd_path (dave.root_fd), true))) {
            throw new IOError.FAILED ("Boot publication changed DAVE ROOT");
        }
        check_hibernate_publication (dave);
    }

    private void cleanup_dave (DaveInstall dave, string work) throws GLib.Error {
        GLib.Error? error = null;
        int[] descriptors = dave.staged_fds;
        descriptors += dave.bootstrap_fd;
        descriptors += dave.hibernate_fd;
        descriptors += dave.hibernate_image_fd;
        dave.hibernate_image_fd = -1;
        dave.bootstrap_fd = -1;
        dave.hibernate_fd = -1;
        descriptors += dave.copy_fd;
        descriptors += dave.root_fd;
        dave.staged_fds = {-1, -1, -1, -1, -1, -1};
        dave.copy_fd = -1;
        dave.root_fd = -1;
        foreach (var fd in descriptors) {
            if (fd >= 0 && Posix.close (fd) != 0 && error == null) {
                error = new IOError.FAILED ("Could not close retained DAVE input");
            }
        }
        if (dave.hibernate_mapping != null) {
            dave_crypto ({"close", dave.hibernate_mapping});
            dave.hibernate_mapping = null;
        }
        if (dave.hibernate_mounted) {
            run ({"umount", dave.hibernate_path});
            dave.hibernate_mounted = false;
        }
        var hibernate = File.new_for_path (work + "/hibernate");
        if (hibernate.query_exists ()) hibernate.delete ();
        // Normal unmount, never recurse into a failed-unmount tree. The
        // plaintext owner staging vanishes with its private noswap tmpfs.
        if (dave.flatpak_mounted) {
            run ({"umount", work + "/copy/var/lib/flatpak"});
            dave.flatpak_mounted = false;
        }
        if (dave.factory_mounted) {
            run ({"umount", work + "/copy/usr/share/vale/install-root"});
            dave.factory_mounted = false;
        }
        if (dave.copy_mounted) {
            run ({"umount", work + "/copy"});
            dave.copy_mounted = false;
        }
        var copy = File.new_for_path (work + "/copy");
        if (copy.query_exists ()) copy.delete ();
        if (error != null) throw error;
    }

    private string fd_path (int fd) {
        return "/proc/%d/fd/%d".printf (Posix.getpid (), fd);
    }

    private void require_secure_boot () throws GLib.Error {
        // This is a guard, not runtime attestation of a UKI. The deployment must
        // boot the approved signed UKI/stub/initrd; its embedded cmdline is authority.
        var variables = File.new_for_path ("/sys/firmware/efi/efivars");
        foreach (var name in new string[] {"SecureBoot", "SetupMode"}) {
            uint8[] value;
            variables.get_child (name + "-8be4df61-93ca-11d2-aa0d-00e098032b8c").load_contents (null, out value, null);
            if (value.length != 5 || value[4] != (name == "SecureBoot" ? 1 : 0)) {
                throw new IOError.PERMISSION_DENIED ("Authenticated Normal recovery boot required");
            }
        }
        var mok = variables.get_child ("MokSBStateRT-605dab50-e046-4300-abb6-3dd810dd8b23");
        try {
            uint8[] value;
            mok.load_contents (null, out value, null);
            if (value.length != 5 || value[4] != 0) {
                throw new IOError.PERMISSION_DENIED ("Shim validation must be enabled");
            }
        } catch (IOError.NOT_FOUND e) {
            // A direct firmware boot need not expose a Shim variable.
        }
    }

    private string media_parameter (string command_line, string name) throws GLib.Error {
        string? result = null;
        foreach (var word in Regex.split_simple ("\\s+", command_line.strip ())) {
            if (word == name || word.has_prefix (name + "=")) {
                if (result != null || word == name || word.length == name.length + 1) {
                    throw new IOError.FAILED ("Missing or duplicate signed media parameter: %s", name);
                }
                result = word.substring (name.length + 1);
            }
        }
        if (result == null) {
            throw new IOError.FAILED ("Missing signed media parameter: %s", name);
        }
        return result;
    }

    private string mapper_command (MediaSource media, string command, string[] arguments = {}) throws GLib.Error {
        var device = media.identities[0].st_rdev;
        string[] argv = {"/usr/sbin/dmsetup", command, "--major", "%u".printf (Posix.major (device)),
                        "--minor", "%u".printf (Posix.minor (device))};
        foreach (var argument in arguments) {
            argv += argument;
        }
        return run_capture (argv);
    }

    private void check_source_mount (string path, Posix.dev_t device, string type, string root = "/") throws GLib.Error {
        bool found = false;
        foreach (var line in get_contents (File.new_for_path ("/proc/self/mountinfo")).strip ().split ("\n")) {
            var halves = line.split (" - ");
            var fields = halves[0].split (" ");
            if (fields.length >= 6 && fields[4] == path) {
                var filesystem = halves.length == 2 ? halves[1].split (" ") : new string[0];
                if (found || fields[2] != device_number (device) || fields[3] != root ||
                    !("ro" in fields[5].split (",")) || filesystem.length < 3 || filesystem[0] != type ||
                    !("ro" in filesystem[2].split (","))) {
                    throw new IOError.FAILED ("Installation source mount is not the admitted read-only filesystem");
                }
                found = true;
            }
        }
        if (!found) {
            throw new IOError.FAILED ("Installation source mount is missing");
        }
    }

    private void retain_source (MediaSource media, int slot, int parent, string name, bool directory = false) throws GLib.Error {
        int flags = Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC | Posix.O_NONBLOCK;
        if (directory) {
            flags |= Posix.O_DIRECTORY;
        }
        media.fds[slot] = Posix.openat (parent, name, flags);
        if (media.fds[slot] < 0 || Posix.fstat (media.fds[slot], out media.identities[slot]) != 0 ||
            (directory ? (!Posix.S_ISDIR (media.identities[slot].st_mode)) :
                         (!Posix.S_ISREG (media.identities[slot].st_mode) || media.identities[slot].st_size <= 0))) {
            throw new IOError.FAILED ("Could not retain regular installation source: %s", name);
        }
    }

    private void retain_media_file (MediaSource media, int slot, string directory, string? name) throws GLib.Error {
        int parent = Posix.openat (media.fds[1], directory, Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
        if (parent < 0) {
            throw new IOError.FAILED ("Could not open media directory: %s", directory);
        }
        GLib.Error? error = null;
        try {
            var selected = name ?? find_unique_file (fd_path (parent), ".raw.squashfs");
            if (selected == null) {
                throw new IOError.FAILED ("Installation squashfs missing");
            }
            retain_source (media, slot, parent, Path.get_basename (selected));
            if (media.identities[slot].st_dev != media.identities[0].st_rdev) {
                throw new IOError.FAILED ("Installation image is outside authenticated media");
            }
        } catch (GLib.Error e) {
            error = e;
        }
        if (Posix.close (parent) != 0) {
            if (error == null) {
                error = new IOError.FAILED ("Could not close media directory");
            } else {
                log_message (InstallerDaemon.LogLevel.WARN, "Closing media directory failed: %s", Posix.strerror (Posix.errno));
            }
        }
        if (error != null) {
            throw error;
        }
    }

    private void admit_media (MediaSource media, bool dave = false) throws GLib.Error {
        require_secure_boot ();
        var command_line = get_contents (File.new_for_path ("/proc/cmdline"));
        var mode = media_parameter (command_line, "vale.mode");
        if ((dave ? mode != "dave-recovery" : (mode != "normal-recovery" && mode != "dave-recovery")) ||
            media_parameter (command_line, "boot") != "vale-live" ||
            media_parameter (command_line, "live-media") != "/dev/mapper/vale-install-media") {
            throw new IOError.PERMISSION_DENIED (dave ? "Only authenticated DAVE recovery may provision" :
                                                 "Only authenticated recovery may run Normal installation");
        }
        var blocks = media_parameter (command_line, "vale.media_data_blocks");
        var offset = media_parameter (command_line, "vale.media_hash_start_block");
        var uuid = media_parameter (command_line, "vale.media_hash_partuuid");
        var root = media_parameter (command_line, "vale.media_root_hash");
        var salt = media_parameter (command_line, "vale.media_salt");
        uint64 count = 0;
        uint64 start = 0;
        if (!Regex.match_simple ("^[1-9][0-9]*$", blocks) || !uint64.try_parse (blocks, out count) || count > uint64.MAX / 4 ||
            !Regex.match_simple ("^[1-9][0-9]*$", offset) || !uint64.try_parse (offset, out start) || start <= count ||
            !Regex.match_simple ("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", uuid) ||
            !Regex.match_simple ("^[0-9a-f]{64}$", root) || !Regex.match_simple ("^[0-9a-f]{64}$", salt)) {
            throw new IOError.FAILED ("Invalid signed media dimensions or digest");
        }
        var hash = Posix.realpath ("/dev/disk/by-partuuid/" + uuid);
        Posix.Stat partition = Posix.Stat ();
        if (hash == null || Posix.stat (hash, out partition) != 0 || !Posix.S_ISBLK (partition.st_mode)) {
            throw new IOError.FAILED ("Signed media hash partition missing");
        }
        var topology = Posix.realpath ("/sys/dev/block/" + device_number (partition.st_rdev));
        uint64 sector = 0;
        if (topology == null || !File.new_for_path (topology + "/partition").query_exists () ||
            !uint64.try_parse (get_contents (File.new_for_path (topology + "/start")).strip (), out sector) ||
            sector % 4 != 0 || sector / 4 != start) {
            throw new IOError.FAILED ("Signed media hash partition offset differs");
        }
        media.backing = "/dev/" + Path.get_basename (Path.get_dirname (topology));
        if (Posix.stat (media.backing, out media.backing_identity) != 0 || !Posix.S_ISBLK (media.backing_identity.st_mode)) {
            throw new IOError.FAILED ("Signed media backing device missing");
        }
        var backing_number = device_number (media.backing_identity.st_rdev);
        media.backing_sequence = get_contents (File.new_for_path ("/sys/dev/block/" + backing_number + "/diskseq")).strip ();
        var path = Posix.realpath ("/dev/mapper/vale-install-media");
        if (path == null) {
            throw new IOError.FAILED ("Authenticated media mapper missing");
        }
        media.fds[0] = Posix.open (path, Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC | Posix.O_NONBLOCK);
        if (media.fds[0] < 0 || Posix.fstat (media.fds[0], out media.identities[0]) != 0 || !Posix.S_ISBLK (media.identities[0].st_mode)) {
            throw new IOError.FAILED ("Could not retain authenticated media mapper");
        }
        media.table = "0 %s verity 1 %s %s 2048 2048 %s %s sha256 %s %s".printf (
            (count * 4).to_string (), backing_number, backing_number, blocks, offset, root, salt
        );
        media.state = mapper_command (media, "info", {"-c", "--noheadings", "--separator", ":", "-o", "attr,events"}).strip ();
        if (!Regex.match_simple ("^L--r:[0-9]+$", media.state)) {
            throw new IOError.FAILED ("Media mapper is not active, read-only and without inactive table");
        }
        retain_source (media, 1, Posix.AT_FDCWD, "/cdrom", true);
        if (media.identities[1].st_dev != media.identities[0].st_rdev) {
            throw new IOError.FAILED ("Fixed media directory is not on the authenticated mapper");
        }
        check_media (media);
        retain_media_file (media, 2, "extra", null);
        retain_media_file (media, 3, "live", "filesystem.squashfs");
        check_media (media);
    }

    private void check_media (MediaSource media) throws GLib.Error {
        require_secure_boot ();
        Posix.Stat current = Posix.Stat ();
        if (Posix.stat ("/dev/mapper/vale-install-media", out current) != 0 ||
            current.st_rdev != media.identities[0].st_rdev || current.st_ino != media.identities[0].st_ino ||
            current.st_dev != media.identities[0].st_dev ||
            get_contents (File.new_for_path ("/sys/dev/block/" + device_number (current.st_rdev) + "/ro")).strip () != "1" ||
            get_contents (File.new_for_path ("/sys/dev/block/" + device_number (current.st_rdev) + "/dm/name")).strip () != "vale-install-media" ||
            mapper_command (media, "table") != media.table ||
            mapper_command (media, "info", {"-c", "--noheadings", "--separator", ":", "-o", "attr,events"}).strip () != media.state) {
            throw new IOError.FAILED ("Authenticated media mapping changed or differs from signed facts");
        }
        var status = mapper_command (media, "status");
        var prefix = "0 " + media.table.split (" ")[1] + " verity V";
        if (status != prefix && status != prefix + " -") {
            throw new IOError.FAILED ("Authenticated media has a corruption error");
        }
        if (Posix.stat (media.backing, out current) != 0 || current.st_rdev != media.backing_identity.st_rdev ||
            current.st_ino != media.backing_identity.st_ino || current.st_dev != media.backing_identity.st_dev ||
            get_contents (File.new_for_path ("/sys/dev/block/" + device_number (current.st_rdev) + "/diskseq")).strip () != media.backing_sequence ||
            get_contents (File.new_for_path ("/sys/dev/block/" + device_number (current.st_rdev) + "/ro")).strip () != "1") {
            throw new IOError.FAILED ("Authenticated media backing changed");
        }
        check_source_mount ("/cdrom", media.identities[0].st_rdev, "iso9660");
        if (Posix.lstat ("/cdrom", out current) != 0 || current.st_dev != media.identities[1].st_dev ||
            current.st_ino != media.identities[1].st_ino || !Posix.S_ISDIR (current.st_mode)) {
            throw new IOError.FAILED ("Fixed media mount changed");
        }
        for (int i = 0; i < media.fds.length; i++) {
            if (media.fds[i] >= 0 && (Posix.fstat (media.fds[i], out current) != 0 ||
                current.st_dev != media.identities[i].st_dev || current.st_ino != media.identities[i].st_ino ||
                current.st_size != media.identities[i].st_size || current.st_rdev != media.identities[i].st_rdev ||
                current.st_mtime != media.identities[i].st_mtime || current.st_ctime != media.identities[i].st_ctime)) {
                throw new IOError.FAILED ("Retained installation source changed");
            }
        }
    }

    private void check_definitions (string definitions) throws GLib.Error {
        // Admit only the factory directories and Flatpak source in this release.
        var keys = new HashTable<string, string> (str_hash, str_equal);
        string[] copy_files = {};
        bool partition = false;
        foreach (var raw in get_contents (File.new_for_path (definitions + "/40-root.conf")).split ("\n")) {
            var line = raw.strip ();
            if (line == "" || line.has_prefix ("#")) {
                continue;
            }
            if (line == "[Partition]" && !partition) {
                partition = true;
                continue;
            }
            int equal = line.index_of_char ('=');
            if (!partition || equal <= 0 || line.contains ("\\")) {
                throw new IOError.FAILED ("Unsupported trusted repart definition syntax");
            }
            var key = line.substring (0, equal);
            var value = line.substring (equal + 1).strip ();
            if (key == "CopyFiles") {
                copy_files += value;
                continue;
            }
            if (keys.contains (key) || !(key in new string[] {"Type", "Format", "SizeMinBytes", "Weight",
                "Encrypt", "FactoryReset", "Label"})) {
                throw new IOError.FAILED ("Unsupported or duplicate trusted repart setting: %s", key);
            }
            keys.insert (key, value);
        }
        if (keys.lookup ("Type") != "root" || keys.lookup ("Format") != "ext4" || keys.lookup ("Encrypt") != "off" ||
            copy_files.length != 2 || copy_files[0] != "/usr/share/vale/install-root:/" ||
            copy_files[1] != "/var/lib/flatpak:/var/lib/flatpak") {
            throw new IOError.FAILED ("Unexpected trusted root definition consumers");
        }
    }

    private void log_message (InstallerDaemon.LogLevel level, string format, ...) {
        var msg= format.vprintf (va_list ());

        on_log_message (level, msg);

        switch (level) {
            case TRACE:
                debug (msg);
                break;
            case DEBUG:
                debug (msg);
                break;
            case INFO:
                info (msg);
                break;
            case WARN:
                warning (msg);
                break;
            case ERROR:
                critical (msg);
                break;
            default:
                message (msg);
                break;
        }
    }

    private string? find_unique_file (string directory, string suffix) throws GLib.Error {
        string? result = null;
        try {
            var dir = File.new_for_path (directory);
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," +
                FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );

            FileInfo? info;
            while ((info = enumerator.next_file ()) != null) {
                var name = info.get_name ();
                if (name.has_suffix (suffix)) {
                    if (info.get_file_type () != FileType.REGULAR || result != null) {
                        throw new GLib.IOError.FAILED ("Expected a single regular %s file in %s", suffix, directory);
                    }
                    result = Path.build_filename (directory, name);
                }
            }
        } catch (GLib.Error e) {
            if (!(e is GLib.IOError.NOT_FOUND)) {
                throw e;
            }
        }
        return result;
    }

    private string run_capture (string[] argv) throws GLib.Error {
        var process = new Subprocess.newv (argv, STDOUT_PIPE | STDERR_PIPE);
        string stdout_buf = "";
        string stderr_buf = "";

        process.communicate_utf8 (null, null, out stdout_buf, out stderr_buf);

        if (!process.get_successful ()) {
            throw new GLib.IOError.FAILED (
                "Run command failed: %s: %s: %s",
                string.joinv (" ", argv),
                stdout_buf.strip (),
                stderr_buf.strip ()
            );
        }

        return stdout_buf.strip ();
    }

    private void run (string[] argv) throws GLib.Error {
        try {
            var process = new Subprocess.newv (argv, NONE);
            process.wait_check ();
        } catch (GLib.Error e) {
            throw new GLib.IOError.FAILED ("Run command failed: %s: %s", string.joinv (" ", argv), e.message);
        }
    }

    private void configure_encryption (string work, string definitions, bool encrypt, string password, ref string keyfile) throws GLib.Error {
        if (!encrypt) {
            log_message (InstallerDaemon.LogLevel.INFO, "No encryption");
            set_repart_encryption (definitions, "off");
            return;
        }

        log_message (InstallerDaemon.LogLevel.INFO, "Password encryption");

        set_repart_encryption (definitions, "key-file");

        keyfile = Path.build_filename (work, "root.key");
        var stream = File.new_for_path (keyfile).create (FileCreateFlags.PRIVATE);
        GLib.Error? write_error = null;
        try {
            size_t written;
            stream.write_all (password.data, out written);
            stream.flush ();
        } catch (GLib.Error e) {
            write_error = e;
        }
        try {
            stream.close ();
        } catch (GLib.Error e) {
            if (write_error == null) {
                write_error = e;
            }
        }
        if (write_error != null) {
            throw write_error;
        }

    }

    private void set_repart_encryption (string definitions, string value) throws GLib.Error {
        var path = Path.build_filename (definitions, "40-root.conf");
        var info = File.new_for_path (path).query_info (
            FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS
        );
        if (info.get_file_type () != FileType.REGULAR) {
            throw new GLib.IOError.FAILED ("Expected a regular root definition in %s", path);
        }
        string contents = "";

        FileUtils.get_contents (path, out contents);

        var regex = new Regex ("^Encrypt=.*$", MULTILINE);
        MatchInfo match;
        if (!regex.match (contents, 0, out match) || match.next ()) {
            throw new GLib.IOError.FAILED ("Expected exactly one Encrypt setting in %s", path);
        }
        contents = regex.replace (contents, contents.length, 0, "Encrypt=" + value);

        FileUtils.set_contents (path, contents);
    }

    private void cleanup (string work, string squash_mount, bool mounted, string keyfile, string live_mount, bool live_mounted) throws GLib.Error {
        log_message (InstallerDaemon.LogLevel.INFO, "Cleanup");
        GLib.Error? key_error = null;

        if (keyfile.length > 0) {
            try {
                File.new_for_path (keyfile).delete ();
            } catch (GLib.Error e) {
                if (!(e is GLib.IOError.NOT_FOUND)) {
                    key_error = e;
                }
            }
        }

        try {
            if (mounted) {
                // Never traverse the source mount if unmounting it failed.
                run ({"umount", squash_mount});
            }
            if (live_mounted) {
                run ({"umount", live_mount});
            }
            var definitions = File.new_for_path (Path.build_filename (work, "repart"));
            try {
                var enumerator = definitions.enumerate_children (
                    FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS
                );
                FileInfo? info;
                while ((info = enumerator.next_file ()) != null) {
                    definitions.get_child (info.get_name ()).delete ();
                }
                enumerator.close ();
                definitions.delete ();
            } catch (GLib.Error e) {
                if (!(e is GLib.IOError.NOT_FOUND)) {
                    throw e;
                }
            }
            try {
                File.new_for_path (squash_mount).delete ();
            } catch (GLib.Error e) {
                if (!(e is GLib.IOError.NOT_FOUND)) {
                    throw e;
                }
            }
            if (File.new_for_path (live_mount).query_exists ()) {
                File.new_for_path (live_mount).delete ();
            }
            File.new_for_path (work).delete ();
        } catch (GLib.Error e) {
            if (key_error != null) {
                log_message (InstallerDaemon.LogLevel.WARN, "Cleanup keyfile failed: %s", key_error.message);
            }
            throw e;
        }
        if (key_error != null) {
            throw key_error;
        }
    }

    public async void install_with_default_disk_layout (InstallConfig config, string disk, bool encrypt, string encryption_password, GLib.BusName sender) throws GLib.Error {
        yield authorize_operation (sender);
        try {
            log_message (InstallerDaemon.LogLevel.INFO, "Clean install to " + disk);
            yield install_in_thread (disk, encrypt, encryption_password);
        } finally {
            end_operation ();
        }
    }

    public async void install_with_custom_disk_layout (InstallConfig config, Mount[] disk_config, LuksCredentials[] credentials, GLib.BusName sender) throws GLib.Error {
        yield authorize_operation (sender);
        try {
            log_message (InstallerDaemon.LogLevel.ERROR, "Custom installations unsupported");
            throw new GLib.IOError.FAILED ("Custom installations unsupported");
        } finally {
            end_operation ();
        }
    }

    public async void install_dave (InstallConfig config, string disk, UnixInputStream owner,
                                   UnixInputStream recovery, UnixInputStream hibernate_recovery, GLib.BusName sender) throws GLib.Error {
        yield authorize_operation (sender);
        try {
            if (!DaveReadiness.allows_dave_firmware ()) {
                throw new IOError.NOT_SUPPORTED ("Dave mode requires DAVE firmware");
            }
            DaveReadiness.require_no_swap ();
            if (run_capture ({"/usr/lib/vale/vale-hibernate-counter", "launch-kind"}) != "NORMAL") {
                throw new IOError.NOT_SUPPORTED ("DAVE installation requires a verified normal firmware launch");
            }
            if (owner == recovery || owner.get_fd () == recovery.get_fd ()) {
                throw new IOError.INVALID_ARGUMENT ("Distinct owner and recovery streams required");
            }
            var identity = run_capture ({"/usr/bin/vale-tpm2-srk-verify"});
            string srk_name = "";
            foreach (var line in identity.split ("\n")) {
                if (line.has_prefix ("name=")) {
                    srk_name = line.substring (5);
                }
            }
            yield format_dave_reserved (disk, owner.get_fd (), recovery.get_fd (), hibernate_recovery.get_fd (), config, srk_name);
        } finally {
            end_operation ();
        }
    }

    internal async void format_dave_reserved (string disk, int owner, int recovery, int hibernate_recovery, InstallConfig config,
                                 string verified_srk_name) throws GLib.Error {
        if (verified_srk_name.length != 68 || !Regex.match_simple ("\\A000b[0-9a-f]{64}\\z", verified_srk_name)) {
            throw new IOError.INVALID_ARGUMENT ("Verified SRK identity required");
        }
        if (!Regex.match_simple ("\\A[A-Za-z0-9_-]{1,64}\\z", config.keyboard_layout) ||
            !Regex.match_simple ("\\A[A-Za-z0-9_-]{0,64}\\z", config.keyboard_variant)) {
            throw new IOError.INVALID_ARGUMENT ("Invalid keyboard selection");
        }
        var locales = run_capture ({"/usr/bin/locale", "-a"}).split ("\n");
        if (!(config.lang.replace (".UTF-8", ".utf8") in locales)) {
            throw new IOError.INVALID_ARGUMENT ("Selected language is not installed");
        }
        var dave = new DaveInstall ();
        dave.owner = owner;
        dave.recovery = recovery;
        dave.hibernate_recovery = hibernate_recovery;
        dave.hostname = config.hostname;
        dave.lang = config.lang;
        dave.keyboard_layout = config.keyboard_layout;
        dave.keyboard_variant = config.keyboard_variant;
        dave.srk_name = verified_srk_name;
        dave.uuid = Uuid.string_random ();
        yield install_in_thread (disk, true, "", dave);
    }

    private async void install_in_thread (string disk, bool encrypt, string password, DaveInstall? dave = null) throws GLib.Error {
        GLib.Error? install_error = null;
        SourceFunc resume = install_in_thread.callback;
        var thread = new Thread<void*> (null, () => {
            try {
                install (disk, encrypt, password, dave);
            } catch (GLib.Error e) {
                install_error = e;
            }
            Idle.add (() => { resume (); return Source.REMOVE; });
            return null;
        });
        yield;
        thread.join ();
        if (install_error != null) {
            throw install_error;
        }
    }

    private bool is_physical_disk (File disk, string name) {
        return disk.get_child ("device").query_exists () && !name.has_prefix ("sr");
    }

    private string device_number (Posix.dev_t device) {
        return "%u:%u".printf (Posix.major (device), Posix.minor (device));
    }

    private void check_unused_block (File block) throws GLib.Error {
        if (get_contents (block.get_child ("ro")).strip () != "0") {
            throw new GLib.IOError.PERMISSION_DENIED ("Destination device is read-only");
        }
        var holders = block.get_child ("holders").enumerate_children (
            FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS
        );
        bool held = holders.next_file () != null;
        holders.close ();
        if (held) {
            throw new GLib.IOError.BUSY ("Destination device has holders");
        }
    }

    private bool source_on_target (Posix.dev_t device, string target, string[] visited = {}) throws GLib.Error {
        var number = device_number (device);
        foreach (var previous in visited) {
            if (previous == number) {
                throw new GLib.IOError.FAILED ("Cyclic installation source backing devices");
            }
        }
        string[] ancestors = visited;
        ancestors += number;
        var path = Posix.realpath ("/sys/dev/block/" + number);
        if (path == null) {
            // Anonymous filesystems (tmpfs, overlayfs) have no block device.
            if (Posix.major (device) == 0) {
                return false;
            }
            throw new GLib.IOError.FAILED ("Could not identify installation source backing device");
        }
        if (path == target || path.has_prefix (target + "/")) {
            return true;
        }
        var block = File.new_for_path (path);
        if (block.get_child ("partition").query_exists ()) {
            block = File.new_for_path (Path.get_dirname (path));
        }
        var loop = block.get_child ("loop/backing_file");
        if (loop.query_exists ()) {
            int fd = Posix.open ("/dev/" + block.get_basename (), Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            if (fd < 0) {
                throw new GLib.IOError.FAILED ("Could not open installation source loop device");
            }
            Posix.dev_t device_backing = 0;
            try {
                Posix.Stat opened = Posix.Stat ();
                if (Posix.fstat (fd, out opened) != 0 || !Posix.S_ISBLK (opened.st_mode) ||
                    device_number (opened.st_rdev) != get_contents (block.get_child ("dev")).strip () ||
                    loop_backing_device (fd, out device_backing) != 0) {
                    throw new GLib.IOError.FAILED ("Could not identify installation source loop backing device");
                }
            } finally {
                Posix.close (fd);
            }
            if (source_on_target (device_backing, target, ancestors)) {
                return true;
            }
        }
        var slaves = block.get_child ("slaves").enumerate_children (
            FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS
        );
        bool on_target = false;
        FileInfo? slave;
        while ((slave = slaves.next_file ()) != null) {
            Posix.Stat backing = Posix.Stat ();
            if (Posix.stat ("/dev/" + slave.get_name (), out backing) != 0 || !Posix.S_ISBLK (backing.st_mode)) {
                throw new GLib.IOError.FAILED ("Could not identify installation source slave device");
            }
            if (source_on_target (backing.st_rdev, target, ancestors)) {
                on_target = true;
                break;
            }
        }
        slaves.close ();
        return on_target;
    }

    private void validate_target (string destination, int fd, Posix.Stat selected, string sequence, string? source = null) throws GLib.Error {
        Posix.Stat current = Posix.Stat ();
        Posix.Stat opened = Posix.Stat ();
        var name = Path.get_basename (destination);
        var block = File.new_for_path ("/sys/block/" + name);
        if (destination != "/dev/" + name || Posix.realpath (destination) != destination ||
            Posix.lstat (destination, out current) != 0 || !Posix.S_ISBLK (current.st_mode) ||
            current.st_rdev != selected.st_rdev || current.st_dev != selected.st_dev || current.st_ino != selected.st_ino ||
            Posix.fstat (fd, out opened) != 0 || !Posix.S_ISBLK (opened.st_mode) ||
            opened.st_rdev != selected.st_rdev || opened.st_dev != selected.st_dev || opened.st_ino != selected.st_ino ||
            !is_physical_disk (block, name) || block.get_child ("partition").query_exists () ||
            get_contents (block.get_child ("dev")).strip () != device_number (selected.st_rdev) ||
            get_contents (block.get_child ("diskseq")).strip () != sequence || sequence == "") {
            throw new GLib.IOError.FAILED ("Destination is not the selected whole physical device");
        }
        uint64 sectors;
        if (!uint64.try_parse (get_contents (block.get_child ("size")).strip (), out sectors) || sectors == 0) {
            throw new GLib.IOError.FAILED ("Destination device has no usable capacity");
        }
        var target = Posix.realpath (block.get_path ());
        if (target == null) {
            throw new GLib.IOError.FAILED ("Could not identify destination device topology");
        }
        var mounts = get_contents (File.new_for_path ("/proc/self/mountinfo")).strip ().split ("\n");
        foreach (var mount in mounts) {
            var fields = mount.split (" ");
            var number = fields.length >= 3 ? fields[2].split (":") : new string[0];
            uint major = 0;
            uint minor = 0;
            if (number.length != 2 || !uint.try_parse (number[0], out major) || !uint.try_parse (number[1], out minor) ||
                major > int.MAX || minor > int.MAX) {
                throw new GLib.IOError.FAILED ("Could not identify mounted devices");
            }
            // Loop/mapper aliases can keep a mounted filesystem on a raw backing
            // device without claiming that backing device exclusively.
            if (source_on_target (Posix.makedev ((int) major, (int) minor), target)) {
                throw new GLib.IOError.BUSY ("Destination device backs a mounted filesystem");
            }
        }
        var swaps = get_contents (File.new_for_path ("/proc/swaps")).strip ().split ("\n");
        if (swaps.length == 0 || !swaps[0].has_prefix ("Filename")) {
            throw new GLib.IOError.FAILED ("Could not read active swap devices");
        }
        for (int i = 1; i < swaps.length; i++) {
            var fields = Regex.split_simple ("\\s+", swaps[i]);
            Posix.Stat swap = Posix.Stat ();
            if (fields.length < 2 || Posix.stat (fields[0].compress (), out swap) != 0) {
                throw new GLib.IOError.FAILED ("Could not identify an active swap device");
            }
            var backing = Posix.S_ISBLK (swap.st_mode) ? swap.st_rdev : swap.st_dev;
            if (source_on_target (backing, target)) {
                throw new GLib.IOError.BUSY ("Destination device backs active swap");
            }
        }
        check_unused_block (block);
        var partitions = block.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? partition;
        while ((partition = partitions.next_file ()) != null) {
            var child = block.get_child (partition.get_name ());
            if (child.get_child ("partition").query_exists ()) {
                check_unused_block (child);
            }
        }
        partitions.close ();
        if (source != null) {
            Posix.Stat backing = Posix.Stat ();
            if (Posix.stat (source, out backing) != 0 || source_on_target (backing.st_dev, target)) {
                throw new GLib.IOError.BUSY ("Destination device backs the installation source");
            }
        }
    }

    private void install (string dest_dev, bool encrypt, string encryption_password, DaveInstall? dave = null) throws GLib.Error {
        Posix.Stat selected;
        if (Posix.lstat (dest_dev, out selected) != 0 || !Posix.S_ISBLK (selected.st_mode) ||
            dest_dev != "/dev/" + Path.get_basename (dest_dev) || Posix.realpath (dest_dev) != dest_dev) {
            throw new GLib.IOError.INVALID_ARGUMENT ("Destination must be a canonical block device");
        }
        // Linux's whole-device claim excludes direct filesystem, swap and mapper
        // claims on the disk/partitions, not raw opens. Check aliases separately
        // and retain the claim until cleanup completes.
        int fd = Posix.open (dest_dev, Posix.O_RDWR | Posix.O_EXCL | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
        if (fd < 0) {
            throw new GLib.IOError.BUSY ("Could not reserve destination device: %s", Posix.strerror (Posix.errno));
        }
        GLib.Error? install_error = null;
        try {
            var sequence = get_contents (File.new_for_path ("/sys/block/" + Path.get_basename (dest_dev) + "/diskseq")).strip ();
            validate_target (dest_dev, fd, selected, sequence);
            install_reserved_target (dest_dev, fd, selected, sequence, encrypt, encryption_password, dave);
        } catch (GLib.Error e) {
            install_error = e;
        }
        if (Posix.close (fd) != 0) {
            if (install_error == null) {
                throw new GLib.IOError.FAILED ("Could not close destination reservation: %s", Posix.strerror (Posix.errno));
            }
            log_message (InstallerDaemon.LogLevel.WARN, "Closing destination reservation failed: %s", Posix.strerror (Posix.errno));
        }
        if (install_error != null) {
            throw install_error;
        }
        log_message (InstallerDaemon.LogLevel.INFO, dave == null ? "Completed!" : "Installation pending commissioning");
        on_status (InstallerDaemon.Status () {
            step = InstallerDaemon.Step.BOOTLOADER,
            percent = 100
        });
    }

    private void install_reserved_target (string dest_dev, int fd, Posix.Stat selected, string sequence, bool encrypt, string encryption_password, DaveInstall? dave = null) throws GLib.Error {
        var status = InstallerDaemon.Status () {
            step = INIT,
            percent = 0
        };

        on_status (status);

        log_message (InstallerDaemon.LogLevel.INFO, "Starting installation");

        var keyfile = "";
        var work = DirUtils.mkdtemp ("/run/elementary-installer-XXXXXX");
        if (work == null) {
            throw new GLib.IOError.FAILED ("Could not create private installation directory");
        }
        var squash_mount = Path.build_filename (work, "source");
        var definitions = Path.build_filename (work, "repart");
        bool mounted = false;
        var live_mount = Path.build_filename (work, "live");
        bool live_mounted = false;
        var media = new MediaSource ();
        var root_image = new PreparedRoot ();
        uint64 swap_size = 0;
        NormalRoot? normal_plan = null;
        NormalBoot? normal_boot = null;
        uint64 sector_size = 0;

        try {
            admit_media (media, dave != null);
            var raw_squashfs = fd_path (media.fds[2]);
            validate_target (dest_dev, fd, selected, sequence, raw_squashfs);

            File.new_for_path (squash_mount).make_directory ();
            File.new_for_path (definitions).make_directory ();
            File.new_for_path (live_mount).make_directory ();
            run ({"mount", "-t", "squashfs", "-o", "loop,ro,nodev,nosuid,noexec", fd_path (media.fds[3]), live_mount});
            live_mounted = true;
            retain_source (media, 5, Posix.AT_FDCWD, live_mount, true);
            check_source_mount (live_mount, media.identities[5].st_dev, "squashfs");
            int opt = Posix.openat (media.fds[5], "opt", Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            if (opt < 0) {
                throw new IOError.FAILED ("Trusted opt directory must not be a symlink");
            }
            GLib.Error? definition_error = null;
            try {
                retain_source (media, 6, opt, "repart-target", true);
            } catch (GLib.Error e) {
                definition_error = e;
            }
            if (Posix.close (opt) != 0) {
                if (definition_error == null) {
                    definition_error = new IOError.FAILED ("Could not close trusted opt directory");
                } else {
                    log_message (InstallerDaemon.LogLevel.WARN, "Closing trusted opt directory failed: %s", Posix.strerror (Posix.errno));
                }
            }
            if (definition_error != null) {
                throw definition_error;
            }
            var source_definitions = File.new_for_path (fd_path (media.fds[6]));
            var enumerator = source_definitions.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo? info;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_file_type () != FileType.REGULAR || info.get_name () != "40-root.conf") {
                    throw new GLib.IOError.FAILED ("Unsupported repart definition: %s", info.get_name ());
                }
                source_definitions.get_child (info.get_name ()).copy (
                    File.new_for_path (Path.build_filename (definitions, info.get_name ())),
                    FileCopyFlags.NOFOLLOW_SYMLINKS
                );
            }
            enumerator.close ();

            check_definitions (definitions);
            string[] repart_args = {};

            on_log_message (InstallerDaemon.LogLevel.INFO, "Mounting squashfs: " + raw_squashfs);

            run ({"mount", "-t", "squashfs", "-o", "loop,ro,nodev,nosuid,noexec", raw_squashfs, squash_mount});
            mounted = true;

            log_message (InstallerDaemon.LogLevel.INFO, "Mounted squashfs");

            var raw_src = find_unique_file (squash_mount, ".raw");
            if (raw_src == null) {
                throw new GLib.IOError.FAILED ("Could not locate raw image inside squashfs");
            }

            retain_source (media, 4, Posix.AT_FDCWD, raw_src);
            check_source_mount (squash_mount, media.identities[4].st_dev, "squashfs");
            check_media (media);
            if (dave == null && encrypt && encryption_password.length == 0) {
                throw new IOError.INVALID_ARGUMENT ("Normal encryption requires a passphrase; DAVE is unavailable");
            }
            if (dave == null) {
                // Normal uses the authenticated producer's encrypted userspace backend.
                foreach (var path in new string[] {
                    "usr/libexec/vale-normal-hibernate",
                    "usr/lib/systemd/system/systemd-hibernate.service.d/vale.conf",
                    "usr/lib/systemd/system/systemd-hybrid-sleep.service.d/vale.conf"
                }) {
                    Posix.Stat backend;
                    if (Posix.lstat (live_mount + "/" + path, out backend) != 0 ||
                        !Posix.S_ISREG (backend.st_mode) || backend.st_dev != media.identities[5].st_dev) {
                        throw new IOError.NOT_SUPPORTED ("Missing authenticated Normal encrypted hibernation backend");
                    }
                }
                require_sleep_kernel (media, fd_path (media.fds[4]), work, false);
                normal_boot = new NormalBoot (fd_path (media.fds[4]) + "@@1048576", definitions,
                    (argv) => { return run_capture (argv); },
                    () => {
                        require_secure_boot ();
                        validate_target (dest_dev, fd, selected, sequence);
                    });
                if (!uint64.try_parse (get_contents (File.new_for_path ("/sys/dev/block/" +
                    device_number (selected.st_rdev) + "/queue/logical_block_size")).strip (), out sector_size) ||
                    (sector_size != 512 && sector_size != 4096)) {
                    throw new IOError.NOT_SUPPORTED ("Unsupported target logical sector size");
                }
                Posix.Stat contexts;
                if (Posix.lstat (live_mount + "/usr/share/factory/etc/selinux/targeted/contexts/files/file_contexts", out contexts) != 0 ||
                    !Posix.S_ISREG (contexts.st_mode) || contexts.st_dev != media.identities[5].st_dev) {
                    throw new IOError.FAILED ("Missing authenticated target SELinux file contexts");
                }
                configure_encryption (work, definitions, encrypt, encryption_password, ref keyfile);
                swap_size = normal_swap_size ();
                var path = definitions + "/40-root.conf";
                var contents = get_contents (File.new_for_path (path));
                var sizing = new Regex ("^SizeMinBytes=.*$", RegexCompileFlags.MULTILINE);
                // Leave factory ROOT space and LUKS/filesystem overhead in addition to swap.
                contents = sizing.replace (contents, contents.length, 0,
                    "SizeMinBytes=" + (swap_size + 4 * GIB).to_string ());
                FileUtils.set_contents (path, contents);
                repart_args = {"--json=short"};
            } else {
                require_dave_boot_selection ();
                // The authenticated producer's ESP is first, at 1 MiB. Reject
                // older Normal-only sources before destructive repart starts.
                run_capture ({"mtools", "-c", "mdir", "-i", fd_path (media.fds[4]) + "@@1048576",
                              "::/EFI/Linux/elementary-dave_*.efi"});
                require_sleep_kernel (media, fd_path (media.fds[4]), work, true);
                DaveReadiness.require_no_swap ();
                if (!validate_dave_credentials (dave.owner, dave.recovery, dave.hibernate_recovery, dave.hostname,
                    out dave.username, out dave.password_offset, out dave.password_size)) {
                    throw new IOError.INVALID_ARGUMENT ("Invalid DAVE credential descriptors");
                }
                // Firstboot creates a user and same-named group from these defaults.
                foreach (var database in new string[] {"passwd", "group"}) {
                    var accounts = live_mount + "/usr/share/factory/etc/" + database;
                    Posix.Stat account_file;
                    if (Posix.lstat (accounts, out account_file) != 0 ||
                        !Posix.S_ISREG (account_file.st_mode) || account_file.st_dev != media.identities[5].st_dev) {
                        throw new IOError.FAILED ("Missing authenticated factory account database");
                    }
                    foreach (var account in get_contents (File.new_for_path (accounts)).split ("\n")) {
                        if (account.has_prefix (dave.username + ":")) {
                            throw new IOError.INVALID_ARGUMENT ("DAVE owner name is already reserved");
                        }
                    }
                }
                size_dave_hibernate (dave);
                dave.bootstrap_fd = hibernate_bootstrap_fd ();
                prepare_dave_hibernate (dave, work);
                stage_dave (dave, media, work, definitions);
                repart_args = {"--defer-partitions=esp,xbootldr", "--factory-reset=no", "--json=short"};
            }

            if (encrypt) {
                prepare_root_image (root_image, work, definitions,
                    fd_path (dave == null ? media.fds[5] : dave.copy_fd), keyfile, dave);
                check_root_image (root_image);
            }

            string[] repart_command = {
                "systemd-repart",
                "--copy-from=" + fd_path (media.fds[4]),
                "--definitions=" + definitions,
                "--dry-run=yes",
                "--empty=force",
                // Offline encryption avoids mapper claims conflicting with our reservation.
                "--offline=yes",
                "--copy-source=" + fd_path (dave == null ? media.fds[5] : dave.copy_fd)
            };

            foreach (var repart_arg in repart_args) {
                repart_command += repart_arg;
            }

            var target = "/proc/%d/fd/%d".printf (Posix.getpid (), fd);
            repart_command += target;

            log_message (InstallerDaemon.LogLevel.INFO, "Validating systemd-repart plan");
            check_media (media);
            check_source_mount (live_mount, media.identities[5].st_dev, "squashfs");
            check_source_mount (squash_mount, media.identities[4].st_dev, "squashfs");
            check_root_image (root_image);
            var plan = run_capture (repart_command);
            if (dave == null) {
                normal_plan = new NormalRoot (plan, swap_size);
                if (json_integer (normal_plan.esp, "offset") % sector_size != 0 ||
                    json_integer (normal_plan.esp, "raw_size") % sector_size != 0 ||
                    json_integer (normal_plan.esp, "partno") >= uint32.MAX) {
                    throw new IOError.FAILED ("Invalid Normal ESP firmware geometry");
                }
            }
            if (dave != null) {
                dave.root_plan = dave_root_plan (plan);
                dave.hibernate_plan = dave_hibernate_plan (plan, dave);
                check_dave_stage (dave, media);
            }

            status.step = InstallerDaemon.Step.PARTITION;
            status.percent = 10;
            on_status (status);

            log_message (InstallerDaemon.LogLevel.INFO, "Wiping destination device");
            validate_target (dest_dev, fd, selected, sequence, raw_squashfs);
            // We already own the exclusive claim; wipefs must not claim it again.
            check_media (media);
            check_source_mount (live_mount, media.identities[5].st_dev, "squashfs");
            check_source_mount (squash_mount, media.identities[4].st_dev, "squashfs");
            check_root_image (root_image);
            if (dave != null) require_dave_boot_selection ();
            run ({"/usr/sbin/wipefs", "-a", "--force", target});
            validate_target (dest_dev, fd, selected, sequence, raw_squashfs);
            repart_command[3] = "--dry-run=no";

            status.step = InstallerDaemon.Step.EXTRACT;
            status.percent = 20;
            on_status (status);

            log_message (InstallerDaemon.LogLevel.INFO, "Running systemd-repart");

            check_media (media);
            check_source_mount (live_mount, media.identities[5].st_dev, "squashfs");
            check_source_mount (squash_mount, media.identities[4].st_dev, "squashfs");
            check_root_image (root_image);
            var result = run_capture (repart_command);
            check_root_image (root_image);
            if (dave != null) {
                prove_dave_root (dave, dest_dev, fd, selected, sequence, result);
                prove_dave_hibernate (dave, dest_dev, fd, selected, sequence, result);
                check_media (media);
                check_dave_stage (dave, media);
                publish_dave_boot (dave, repart_command, dest_dev, work, fd, selected, sequence);
            }

            if (dave == null) {
                var written = new NormalRoot (result, swap_size);
                foreach (var name in new string[] {"uuid", "offset", "raw_size", "partno"}) {
                    if (!written.root.get_member (name).equal (normal_plan.root.get_member (name)) ||
                        !written.esp.get_member (name).equal (normal_plan.esp.get_member (name))) {
                        throw new IOError.FAILED ("Normal ROOT or ESP differs from admitted plan");
                    }
                }
                validate_target (dest_dev, fd, selected, sequence);
                var config = provision_normal_swap (written, target, work, keyfile, swap_size, fd, fd_path (media.fds[5]));
                validate_target (dest_dev, fd, selected, sequence);
                var esp = target + "@@" + json_integer (written.esp, "offset").to_string ();
                var staged_config = work + "/repart/root-swap.conf";
                FileUtils.set_contents (staged_config, config);
                try {
                    run_capture ({"mtools", "-c", "mdir", "-i", esp, "::/EFI/Vale/"});
                } catch (GLib.Error e) {
                    run_capture ({"mtools", "-c", "mmd", "-i", esp, "::/EFI/Vale"});
                }
                run_capture ({"mtools", "-c", "mcopy", "-n", "-i", esp, staged_config, "::/EFI/Vale/root-swap.conf"});
                if (run_capture ({"mtools", "-c", "mtype", "-i", esp, "::/EFI/Vale/root-swap.conf"}) != config.strip ()) {
                    throw new IOError.FAILED ("Normal ESP swap configuration differs from ROOT");
                }
                File.new_for_path (staged_config).delete ();
                if (Posix.fsync (fd) != 0) throw new IOError.FAILED ("Could not sync Normal ESP");
                validate_target (dest_dev, fd, selected, sequence);
            }

            status.percent = 80;
            on_status (status);

            log_message (InstallerDaemon.LogLevel.INFO, "Running partprobe");

            run ({"partprobe", target});

            status.percent = 90;
            on_status (status);

            log_message (InstallerDaemon.LogLevel.INFO, "Running udevadm settle");

            run ({"udevadm", "settle"});
            if (normal_boot != null) {
                check_media (media);
                normal_boot.verify_target (target + "@@" + json_integer (normal_plan.esp, "offset").to_string (), definitions);
            }
        } catch (GLib.Error e) {
            log_message (InstallerDaemon.LogLevel.ERROR, "Installation aborted: " + e.message);
            try {
                cleanup_media (media, work, squash_mount, mounted, keyfile, live_mount, live_mounted, root_image, dave);
            } catch (GLib.Error cleanup_error) {
                log_message (InstallerDaemon.LogLevel.WARN, "Cleanup failed: %s", cleanup_error.message);
            }
            throw new GLib.IOError.FAILED ("Installation aborted: " + e.message);
        }

        cleanup_media (media, work, squash_mount, mounted, keyfile, live_mount, live_mounted, root_image, dave);
        // Publish selectors only after target writes and fallible source teardown.
        // The caller still holds the whole-disk reservation until this returns.
        if (normal_boot != null) {
            normal_boot.publish (dest_dev, (uint32) json_integer (normal_plan.esp, "partno") + 1,
                json_string (normal_plan.esp, "uuid"), json_integer (normal_plan.esp, "offset") / sector_size,
                json_integer (normal_plan.esp, "raw_size") / sector_size);
        } else if (dave != null) {
            require_dave_boot_selection ();
        }
    }

    private void close_media_fds (MediaSource media, int[] slots) throws GLib.Error {
        GLib.Error? error = null;
        foreach (var slot in slots) {
            int fd = media.fds[slot];
            media.fds[slot] = -1; // Never retry close, including EINTR.
            if (fd >= 0 && Posix.close (fd) != 0) {
                if (error == null) {
                    error = new IOError.FAILED ("Could not close retained installation source: %s", Posix.strerror (Posix.errno));
                } else {
                    log_message (InstallerDaemon.LogLevel.WARN, "Closing installation source failed: %s", Posix.strerror (Posix.errno));
                }
            }
        }
        if (error != null) {
            throw error;
        }
    }

    private void cleanup_media (MediaSource media, string work, string squash_mount, bool mounted,
                                string keyfile, string live_mount, bool live_mounted, PreparedRoot root_image, DaveInstall? dave = null) throws GLib.Error {
        GLib.Error? error = null;
        try { cleanup_root_image (root_image); } catch (GLib.Error e) { error = e; }
        if (dave != null) {
            try { cleanup_dave (dave, work); } catch (GLib.Error e) {
                if (error == null) error = e;
                else log_message (InstallerDaemon.LogLevel.WARN, "DAVE cleanup failed: %s", e.message);
            }
        }
        // All synchronous consumers have exited. Open files/directories inside
        // these private mounts must close before normal unmount can succeed.
        try {
            close_media_fds (media, {4, 6, 5});
        } catch (GLib.Error e) {
            if (error == null) error = e;
            else log_message (InstallerDaemon.LogLevel.WARN, "Source descriptor cleanup failed: %s", e.message);
        }
        try {
            cleanup (work, squash_mount, mounted, keyfile, live_mount, live_mounted);
        } catch (GLib.Error e) {
            if (error == null) {
                error = e;
            } else {
                log_message (InstallerDaemon.LogLevel.WARN, "Source cleanup failed: %s", e.message);
            }
        }
        // Retain both squashfs files and their media/mapping through teardown.
        try {
            close_media_fds (media, {3, 2, 1, 0});
        } catch (GLib.Error e) {
            if (error == null) {
                error = e;
            } else {
                log_message (InstallerDaemon.LogLevel.WARN, "Source descriptor cleanup failed: %s", e.message);
            }
        }
        if (error != null) {
            throw error;
        }
    }

    private string get_contents (File file) throws GLib.Error {
        uint8[] contents;
        file.load_contents (null, out contents, null);
        return (string) contents;
    }

    public InstallerDaemon.PartitionTable bootloader_detect () throws GLib.Error {
        log_message (InstallerDaemon.LogLevel.ERROR, "Not implemented");
        throw new GLib.IOError.FAILED ("Not implemented");
    }

    public DiskInfo get_disks (bool get_partitions = false) throws GLib.Error {
        if (get_partitions) {
            log_message (InstallerDaemon.LogLevel.ERROR, "Get partitions not implemented");
            throw new GLib.IOError.FAILED ("Get partitions not implemented");
        }

        DiskInfo disk_info = DiskInfo () {
            physical_disks = {},
            logical_disks = {}
        };

        Disk[] physical_disks = {};

        try {
            var sys_block = File.new_for_path ("/sys/block");
            var enumerator = sys_block.enumerate_children (
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NONE
            );

            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                var name = info.get_name ();

                // We only want physical disks
                if (!is_physical_disk (sys_block.get_child (name), name)) {
                    continue;
                }

                uint64 size;
                uint64 sector_size;
                bool rotational;
                bool removable;

                uint64.try_parse (get_contents (sys_block.get_child (name).get_child ("size")).strip (), out size);
                uint64.try_parse (get_contents (sys_block.get_child (name).get_child ("queue").get_child ("logical_block_size")).strip (), out sector_size);
                rotational = get_contents (sys_block.get_child (name).get_child ("queue").get_child ("rotational")).strip () == "1";
                removable = get_contents (sys_block.get_child (name).get_child ("removable")).strip () == "1";

                physical_disks += Disk () {
                    name = name,
                    partitions = {},
                    sectors = size * 512 / sector_size,
                    sector_size = sector_size,
                    rotational = rotational,
                    removable = removable,
                    device_path = Path.build_filename ("/dev", name)
                };
            }
        } catch (GLib.Error e) {
            log_message (InstallerDaemon.LogLevel.ERROR, "Failed to enumerate physical disks: %s", e.message);
            throw new GLib.IOError.FAILED ("Failed to enumerate physical disks: %s", e.message);
        }

        disk_info.physical_disks = physical_disks;

        return disk_info;
    }

    public async int decrypt_partition (string path, string pv, string password, GLib.BusName sender) throws GLib.Error {
        yield authorize_operation (sender);
        try {
            log_message (InstallerDaemon.LogLevel.ERROR, "Not implemented");
            throw new GLib.IOError.FAILED ("Not implemented");
        } finally {
            end_operation ();
        }
    }

    public Disk get_logical_device (string pv) throws GLib.Error {
        log_message (InstallerDaemon.LogLevel.ERROR, "Not implemented");
        throw new GLib.IOError.FAILED ("Not implemented");
    }

    public async void set_demo_mode_locale (string locale, GLib.BusName sender) throws GLib.Error {
        yield authorize_operation (sender);
        try {
            GLib.FileUtils.set_contents ("/etc/default/locale", "LANG=" + locale);
        } finally {
            end_operation ();
        }
    }

    public async void trigger_demo_mode (GLib.BusName sender) throws GLib.Error {
        yield authorize_operation (sender);
        try {
            var demo_mode_file = GLib.File.new_for_path ("/var/lib/lightdm/demo-mode");
            try {
                demo_mode_file.create (GLib.FileCreateFlags.NONE);
            } catch (GLib.Error e) {
                if (!(e is GLib.IOError.EXISTS)) {
                    throw e;
                }
            }
        } finally {
            end_operation ();
        }
    }
}
