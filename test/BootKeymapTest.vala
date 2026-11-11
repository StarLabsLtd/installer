/* SPDX-License-Identifier: GPL-3.0-or-later */

private void run (string[] argv) throws GLib.Error {
    InstallerDaemon.RepartCommand.capture (argv);
}

private string make_image (string work) throws GLib.Error {
    var path = Path.build_filename (work, "esp.img");
    int fd = Posix.open (path, Posix.O_CREAT | Posix.O_EXCL | Posix.O_RDWR | Posix.O_CLOEXEC, 0600);
    assert (fd >= 0 && Posix.ftruncate (fd, 32 * 1024 * 1024) == 0 && Posix.close (fd) == 0);
    run ({"mformat", "-i", path, "::"});
    run ({"mmd", "-i", path, "::/loader"});
    return path;
}

private void test_mapping () {
    const string MAP = "# consolelayout xlayout xmodel xvariant xoptions\n" +
        "de de pc105 - terminate:ctrl_alt_bksp\n" +
        "de-latin1 de pc105 - terminate:ctrl_alt_bksp\n" +
        "de-latin1-nodeadkeys de pc105 nodeadkeys terminate:ctrl_alt_bksp\n" +
        "uk gb pc105 - terminate:ctrl_alt_bksp\n" +
        "ru ru,us pc105 - terminate:ctrl_alt_bksp\n" +
        "ua-utf ua,us pc105 - terminate:ctrl_alt_bksp\n" +
        "bg_pho-utf8 bg,us pc105 ,phonetic terminate:ctrl_alt_bksp\n" +
        "bg_bds-utf8 bg,us pc105 - terminate:ctrl_alt_bksp\n" +
        "cz-qwerty cz,us pc105 qwerty, terminate:ctrl_alt_bksp\n" +
        "us us pc105 - terminate:ctrl_alt_bksp\n";
    try {
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "de", "") == "de");
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "de", "nodeadkeys") ==
                "de-latin1-nodeadkeys");
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "gb", "") == "uk");
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "ru", "") == "ru");
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "ua", "") == "ua-utf");
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "bg", "") == "bg_bds-utf8");
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "cz", "qwerty") == "cz-qwerty");
        assert (InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "us", "") == "us");
        try {
            InstallerDaemon.BootKeymap.map_xkb_layout (MAP, "de", "qwertz");
            assert_not_reached ();
        } catch (GLib.IOError.NOT_SUPPORTED e) { }
        try {
            InstallerDaemon.BootKeymap.map_xkb_layout (
                "ru ru,us pc105 - terminate:ctrl_alt_bksp\n", "us", "");
            assert_not_reached ();
        } catch (GLib.IOError.NOT_SUPPORTED e) { }
        try {
            InstallerDaemon.BootKeymap.map_xkb_layout ("de de pc105 -\n", "de", "");
            assert_not_reached ();
        } catch (GLib.IOError.INVALID_DATA e) { }

        var canonical_path = Environment.get_variable ("VALE_TEST_KBD_MODEL_MAP");
        if (canonical_path != null) {
            string canonical;
            FileUtils.get_contents (canonical_path, out canonical);
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (canonical, "de", "") == "de");
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (canonical, "gb", "") == "uk");
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (canonical, "us", "") == "us");
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (canonical, "ru", "") == "ru");
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (canonical, "ua", "") == "ua-utf");
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (
                canonical, "bg", "") == "bg_bds-utf8");
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (
                canonical, "cz", "qwerty") == "cz-qwerty");
            assert (InstallerDaemon.BootKeymap.map_xkb_layout (
                canonical, "de", "nodeadkeys") == "de-latin1-nodeadkeys");
        }
    } catch (GLib.Error e) { assert_not_reached (); }
}

private void test_stage_and_esp_copy () {
    string? work = null;
    try {
        work = DirUtils.make_tmp ("boot-keymap-XXXXXX");
        var source = Path.build_filename (work, "catalog");
        File.new_for_path (source).make_directory ();
        var input = Path.build_filename (source, "uk.addon.efi");
        FileUtils.set_contents (input, "inert-signed-addon-fixture");
        Posix.Stat stat;
        assert (Posix.lstat (source, out stat) == 0);
        var addon = InstallerDaemon.BootKeymap.stage ("uk", source, stat.st_dev, work);
        var image = make_image (work);
        var staging = Path.build_filename (work, "readback");
        File.new_for_path (staging).make_directory ();
        InstallerDaemon.BootKeymap.copy_to_new_esp (addon, image, 0, staging);
        var readback = Path.build_filename (work, "actual.efi");
        run ({"mcopy", "-i", image, "::/loader/addons/vale-keymap.addon.efi", readback});
        string actual;
        FileUtils.get_contents (readback, out actual);
        assert (actual == "inert-signed-addon-fixture");
        try {
            InstallerDaemon.BootKeymap.sync_target_and_remove_staged (-1, addon);
            assert_not_reached ();
        } catch (GLib.Error e) { }
        assert (File.new_for_path (addon).query_exists ());
        int fd = Posix.open (image, Posix.O_RDWR | Posix.O_CLOEXEC);
        assert (fd >= 0);
        InstallerDaemon.BootKeymap.sync_target_and_remove_staged (fd, addon);
        assert (!File.new_for_path (addon).query_exists ());
        assert (Posix.close (fd) == 0);
    } catch (GLib.Error e) {
        Test.message (e.message);
        assert_not_reached ();
    } finally {
        if (work != null) {
            try { run ({"rm", "-rf", "--", work}); } catch (GLib.Error e) { }
        }
    }
}

private void test_invalid_catalog () {
    string? work = null;
    try {
        work = DirUtils.make_tmp ("boot-keymap-refuse-XXXXXX");
        Posix.Stat stat;
        assert (Posix.lstat (work, out stat) == 0);
        foreach (var name in new string[] {"../uk", "uk rd.break", "missing", ""}) {
            try {
                InstallerDaemon.BootKeymap.stage (name, work, stat.st_dev, work);
                assert_not_reached ();
            } catch (GLib.Error e) { }
        }
        var input = Path.build_filename (work, "uk.addon.efi");
        FileUtils.set_contents (input, "fixture");
        try {
            InstallerDaemon.BootKeymap.stage ("uk", work, stat.st_dev + 1, work);
            assert_not_reached ();
        } catch (GLib.Error e) { }
        File.new_for_path (input).delete ();
        assert (Posix.symlink ("anything", input) == 0);
        try {
            InstallerDaemon.BootKeymap.stage ("uk", work, stat.st_dev, work);
            assert_not_reached ();
        } catch (GLib.Error e) { }
        assert (!File.new_for_path (work + "/vale-keymap.addon.efi").query_exists ());
    } catch (GLib.Error e) {
        Test.message (e.message);
        assert_not_reached ();
    } finally {
        if (work != null) {
            try { run ({"rm", "-rf", "--", work}); } catch (GLib.Error e) { }
        }
    }
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/normal-keymap/exact-xkb-map", test_mapping);
    Test.add_func ("/normal-keymap/addon-and-esp-publication", test_stage_and_esp_copy);
    Test.add_func ("/normal-keymap/invalid-catalog", test_invalid_catalog);
    return Test.run ();
}
