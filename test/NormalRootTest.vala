/* SPDX-License-Identifier: GPL-3.0-or-later */
private const string ROOT = "{\"type\":\"root-x86-64\",\"label\":\"elementary-root\",\"uuid\":\"12345678-1234-1234-1234-123456789abc\",\"offset\":1073741824,\"raw_size\":5368709120,\"partno\":2}";
private const string ESP = "{\"type\":\"esp\",\"uuid\":\"87654321-1234-1234-1234-123456789abc\",\"offset\":1048576,\"raw_size\":536870912,\"partno\":1}";

[CCode (cname = "vale_swapfile_allocate", cheader_filename = "SwapFile.h")]
private extern int allocate_swap (int fd, uint64 size);
[CCode (cname = "vale_swapfile_offset", cheader_filename = "SwapFile.h")]
private extern int swap_offset (int fd, uint64 size, out uint64 offset);

private void assert_invalid_install_settings (string lang, string layout, string variant,
                                              string[] locales) {
    try {
        InstallerDaemon.NormalRoot.validate_install_settings (lang, layout, variant, locales);
        Test.fail ();
    } catch (Error e) { assert (e is IOError); }
}

private void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/normal/partition-admission", () => {
        try {
            new InstallerDaemon.NormalRoot ("[" + ROOT + "," + ESP + "]", 16777216);
        } catch (Error e) { Test.fail (); }
        foreach (var data in new string[] {
            "[" + ROOT + "]", "[" + ROOT + "," + ESP + "," + ESP + "]",
            "[" + ROOT + "," + ROOT + "," + ESP + "]",
            "[" + ROOT + "," + ESP.replace ("1048576", "1073741824") + "]",
            "[" + ROOT.replace ("5368709120", "4096") + "," + ESP + "]",
            "[" + ROOT + "," + ESP.replace ("1048576", "\"1048576\"") + "]"
        }) {
            try {
                new InstallerDaemon.NormalRoot (data, 16777216);
                Test.fail ();
            } catch (Error e) { assert (e is IOError); }
        }
    });
    Test.add_func ("/normal/plain-and-encrypted-config", () => {
        try {
            var plan = new InstallerDaemon.NormalRoot ("[" + ROOT + "," + ESP + "]", 16777216);
            foreach (var luks in new string[] {"none", "01234567-1234-1234-1234-0123456789ab"}) {
                var config = plan.swap_config (luks, 4096, 16777216);
                assert (config == "ROOT_PARTUUID=12345678-1234-1234-1234-123456789abc\nROOT_LUKS_UUID=" +
                    luks + "\nRESUME_OFFSET=4096\nSWAP_SIZE=16777216\n");
            }
            try {
                plan.swap_config ("none\nEXTRA=1", 4096, 16777216);
                Test.fail ();
            } catch (IOError e) { }
        } catch (Error e) { Test.fail (); }
    });
    Test.add_func ("/normal/install-settings-admission", () => {
        var locales = new string[] {"en_US.utf8", "C.utf8"};
        try {
            InstallerDaemon.NormalRoot.validate_install_settings ("en_US.UTF-8", "gb", "", locales);
        } catch (Error e) { Test.fail (); }
        assert_invalid_install_settings ("en_US.UTF-8\nLANG=C", "gb", "", locales);
        assert_invalid_install_settings ("fr_FR.UTF-8", "gb", "", locales);
        assert_invalid_install_settings ("en_US.UTF-8", "gb\nOption", "", locales);
        assert_invalid_install_settings ("en_US.UTF-8", "gb", "variant\"\n", locales);
        assert_invalid_install_settings ("en_US.UTF-8", "vale-invalid-layout", "", locales);
        assert_invalid_install_settings ("en_US.UTF-8", "gb", "vale-invalid-variant", locales);
    });
    Test.add_func ("/normal/install-settings-publication", () => {
        string? root = null;
        try {
            root = DirUtils.make_tmp ("normal-settings-XXXXXX");
            DirUtils.create (root + "/etc", 0755);
            InstallerDaemon.NormalRoot.write_install_settings (root, "en_GB.UTF-8", "gb", "extd");
            string locale;
            string keyboard;
            FileUtils.get_contents (root + "/etc/locale.conf", out locale);
            FileUtils.get_contents (root + "/etc/X11/xorg.conf.d/00-keyboard.conf", out keyboard);
            assert (locale == "LANG=en_GB.UTF-8\n");
            assert (keyboard.contains ("Section \"InputClass\"\n"));
            assert (keyboard.contains ("Option \"XkbLayout\" \"gb\"\n"));
            assert (keyboard.contains ("Option \"XkbVariant\" \"extd\"\n"));
            assert (!FileUtils.test (root + "/etc/vconsole.conf", FileTest.EXISTS));
            try {
                InstallerDaemon.NormalRoot.write_install_settings (root, "en_GB.UTF-8", "gb\n", "");
                Test.fail ();
            } catch (IOError e) { }
            assert (FileUtils.test (root + "/etc/locale.conf", FileTest.EXISTS));
            FileUtils.remove (root + "/etc/locale.conf");
            FileUtils.remove (root + "/etc/X11/xorg.conf.d/00-keyboard.conf");
            DirUtils.remove (root + "/etc/X11/xorg.conf.d");
            DirUtils.remove (root + "/etc/X11");
            DirUtils.remove (root + "/etc");
            File.new_for_path (root).delete ();
        } catch (Error e) { Test.fail (); }
    });
    Test.add_func ("/normal/install-settings-replaces-factory-symlinks", () => {
        string? root = null;
        string? outside = null;
        try {
            root = DirUtils.make_tmp ("normal-settings-links-XXXXXX");
            DirUtils.create (root + "/etc", 0755);
            outside = DirUtils.make_tmp ("normal-settings-outside-XXXXXX");
            FileUtils.set_contents (outside + "/sentinel", "outside ROOT stays unchanged\n");
            File.new_for_path (root + "/etc/X11/xorg.conf.d").make_directory_with_parents ();
            assert (Posix.symlink (outside + "/sentinel", root + "/etc/locale.conf") == 0);
            assert (Posix.symlink (outside + "/sentinel", root + "/etc/X11/xorg.conf.d/00-keyboard.conf") == 0);

            InstallerDaemon.NormalRoot.write_install_settings (root, "en_GB.UTF-8", "gb", "");
            string contents;
            FileUtils.get_contents (outside + "/sentinel", out contents);
            assert (contents == "outside ROOT stays unchanged\n");
            Posix.Stat stat;
            assert (Posix.lstat (root + "/etc/locale.conf", out stat) == 0 && Posix.S_ISREG (stat.st_mode));
            assert (Posix.lstat (root + "/etc/X11/xorg.conf.d/00-keyboard.conf", out stat) == 0 &&
                    Posix.S_ISREG (stat.st_mode));
            FileUtils.remove (root + "/etc/locale.conf");
            FileUtils.remove (root + "/etc/X11/xorg.conf.d/00-keyboard.conf");
            DirUtils.remove (root + "/etc/X11/xorg.conf.d");
            DirUtils.remove (root + "/etc/X11");

            // A factory directory symlink must be refused rather than followed.
            assert (Posix.symlink (outside, root + "/etc/X11") == 0);
            try {
                InstallerDaemon.NormalRoot.write_install_settings (root, "en_GB.UTF-8", "gb", "");
                Test.fail ();
            } catch (IOError e) { }
            assert (!FileUtils.test (root + "/etc/locale.conf", FileTest.EXISTS));
            assert (!FileUtils.test (outside + "/xorg.conf.d", FileTest.EXISTS));
            FileUtils.remove (root + "/etc/X11");
            DirUtils.remove (root + "/etc");
            File.new_for_path (root).delete ();
            FileUtils.remove (outside + "/sentinel");
            File.new_for_path (outside).delete ();
        } catch (Error e) { Test.fail (); }
    });
    Test.add_func ("/normal/config-publication", () => {
        string? root = null;
        try {
            root = DirUtils.make_tmp ("normal-root-XXXXXX");
            DirUtils.create (root + "/etc", 0755);
            var plan = new InstallerDaemon.NormalRoot ("[" + ROOT + "," + ESP + "]", 16777216);
            var config = plan.swap_config ("none", 4096, 16777216);
            InstallerDaemon.NormalRoot.write_config (root, config);
            string contents;
            FileUtils.get_contents (root + "/etc/vale/root-swap.conf", out contents);
            assert (contents == config);
            try {
                InstallerDaemon.NormalRoot.write_config (root, config);
                Test.fail ();
            } catch (IOError e) { }
            FileUtils.remove (root + "/etc/vale/root-swap.conf");
            DirUtils.remove (root + "/etc/vale");
            assert (Posix.symlink (root, root + "/etc/vale") == 0);
            try {
                InstallerDaemon.NormalRoot.write_config (root, config);
                Test.fail ();
            } catch (IOError e) { }
            assert (!FileUtils.test (root + "/root-swap.conf", FileTest.EXISTS));
            FileUtils.remove (root + "/etc/vale");
            DirUtils.remove (root + "/etc");
            DirUtils.remove (root);
        } catch (Error e) { Test.fail (); }
    });
    Test.add_func ("/normal/qualified-root-publication", () => {
        var path = Environment.get_variable ("VALE_TEST_ROOT");
        if (path == null) {
            Test.skip ("Requires a private mounted plain or encrypted ext4 ROOT");
            return;
        }
        int fd = -1;
        try {
            const uint64 SIZE = 16 * 1024 * 1024;
            fd = Posix.open (path + "/swapfile", Posix.O_CREAT | Posix.O_EXCL | Posix.O_RDWR | Posix.O_NOFOLLOW, 0600);
            assert (fd >= 0 && allocate_swap (fd, SIZE) == 0);
            uint64 offset;
            assert (swap_offset (fd, SIZE, out offset) == 0);
            string luks = "none";
            var outer = Environment.get_variable ("VALE_TEST_LUKS_DEVICE");
            if (outer != null) {
                var query = new Subprocess (SubprocessFlags.STDOUT_PIPE, "cryptsetup", "luksUUID", outer);
                query.communicate_utf8 (null, null, out luks, null);
                assert (query.get_successful ());
                luks = luks.strip ();
                assert (Uuid.string_is_valid (luks));
            }
            var plan = new InstallerDaemon.NormalRoot ("[" + ROOT + "," + ESP + "]", SIZE);
            var config = plan.swap_config (luks, offset, SIZE);
            DirUtils.create (path + "/etc", 0755);
            InstallerDaemon.NormalRoot.write_config (path, config);
            string saved;
            FileUtils.get_contents (path + "/etc/vale/root-swap.conf", out saved);
            assert (saved == config);
            assert (saved.contains ("ROOT_LUKS_UUID=" + luks + "\n"));
            assert (saved.contains ("RESUME_OFFSET=" + offset.to_string () + "\n"));
            Test.message ("Qualified %s ROOT swapfile and published actual page offset", outer == null ? "plain" : "LUKS2");
        } catch (Error e) { Test.fail (); }
        if (fd >= 0) Posix.close (fd);
    });
    Test.run ();
}
