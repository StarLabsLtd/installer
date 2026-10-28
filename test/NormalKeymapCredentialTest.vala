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
        "cz-qwerty cz,us pc105 qwerty, terminate:ctrl_alt_bksp\n" +
        "us us pc105 - terminate:ctrl_alt_bksp\n";
    try {
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "de", "") == "de");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "de", "nodeadkeys") ==
                "de-latin1-nodeadkeys");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "gb", "") == "uk");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "ru", "") == "ru");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "ua", "") == "ua-utf");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "bg", "") == "bg_pho-utf8");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "cz", "qwerty") == "cz-qwerty");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "us", "") == "us");
        try {
            InstallerDaemon.NormalKeymapCredential.map_xkb_layout (MAP, "de", "qwertz");
            assert_not_reached ();
        } catch (GLib.IOError.NOT_SUPPORTED e) { }
        try {
            InstallerDaemon.NormalKeymapCredential.map_xkb_layout (
                "ru ru,us pc105 - terminate:ctrl_alt_bksp\n", "us", "");
            assert_not_reached ();
        } catch (GLib.IOError.NOT_SUPPORTED e) { }
        try {
            InstallerDaemon.NormalKeymapCredential.map_xkb_layout ("de de pc105 -\n", "de", "");
            assert_not_reached ();
        } catch (GLib.IOError.INVALID_DATA e) { }

        var canonical_path = Environment.get_variable ("VALE_TEST_KBD_MODEL_MAP");
        if (canonical_path != null) {
            string canonical;
            FileUtils.get_contents (canonical_path, out canonical);
            assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (canonical, "de", "") == "de");
            assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (canonical, "gb", "") == "uk");
            assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (canonical, "us", "") == "us");
            assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (canonical, "ru", "") == "ru");
        assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (canonical, "ua", "") == "ua-utf");
            assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (
                canonical, "bg", "") == "bg_pho-utf8");
            assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (
                canonical, "cz", "qwerty") == "cz-qwerty");
            assert (InstallerDaemon.NormalKeymapCredential.map_xkb_layout (
                canonical, "de", "nodeadkeys") == "de-latin1-nodeadkeys");
        }
    } catch (GLib.Error e) { assert_not_reached (); }
}

private void test_encryption_input_and_esp_copy () {
    string? work = null;
    try {
        work = DirUtils.make_tmp ("normal-keymap-credential-XXXXXX");
        var args_path = Path.build_filename (work, "args");
        var input_path = Path.build_filename (work, "input");
        var command = Path.build_filename (work, "systemd-creds-test");
        FileUtils.set_contents (command,
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$VALE_TEST_ARGS\"\n" +
            "for arg do output=$arg; done\ncat > \"$VALE_TEST_INPUT\"\n" +
            "printf 'test-credential' > \"$output\"\n");
        assert (Posix.chmod (command, 0700) == 0);
        Environment.set_variable ("VALE_TEST_ARGS", args_path, true);
        Environment.set_variable ("VALE_TEST_INPUT", input_path, true);

        var credential = InstallerDaemon.NormalKeymapCredential.encrypt ("de", work, command);
        string input;
        string args;
        FileUtils.get_contents (input_path, out input);
        FileUtils.get_contents (args_path, out args);
        assert (input == "de"); // The credential payload must not contain a newline.
        assert (args == "encrypt\n--with-key=tpm2\n--tpm2-pcrs=\n--name=vconsole.keymap\n-\n" +
                        credential + "\n");

        var image = make_image (work);
        var staging = Path.build_filename (work, "readback");
        File.new_for_path (staging).make_directory ();
        InstallerDaemon.NormalKeymapCredential.copy_to_new_esp (credential, image, 0, staging);
        var readback = Path.build_filename (work, "actual.cred");
        run ({"mcopy", "-i", image, "::/loader/credentials/vconsole.keymap.cred", readback});
        string actual;
        FileUtils.get_contents (readback, out actual);
        assert (actual == "test-credential");

        try {
            InstallerDaemon.NormalSeedCarrier.sync_target_and_remove_staged (-1, null, credential);
            assert_not_reached ();
        } catch (GLib.Error e) { }
        assert (File.new_for_path (credential).query_exists ());
        int fd = Posix.open (image, Posix.O_RDWR | Posix.O_CLOEXEC);
        assert (fd >= 0);
        InstallerDaemon.NormalSeedCarrier.sync_target_and_remove_staged (fd, null, credential);
        assert (!File.new_for_path (credential).query_exists ());
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

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/normal-keymap/exact-xkb-map", test_mapping);
    Test.add_func ("/normal-keymap/credential-and-esp-publication", test_encryption_input_and_esp_copy);
    return Test.run ();
}
