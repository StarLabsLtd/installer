/* SPDX-License-Identifier: GPL-3.0-or-later */

private void run (string[] argv) throws GLib.Error {
    InstallerDaemon.RepartCommand.capture (argv);
}

private string make_image (string directory, string name) throws GLib.Error {
    var path = Path.build_filename (directory, name);
    int fd = Posix.open (path, Posix.O_CREAT | Posix.O_EXCL | Posix.O_RDWR | Posix.O_CLOEXEC, 0600);
    assert (fd >= 0);
    assert (Posix.ftruncate (fd, 32 * 1024 * 1024) == 0);
    assert (Posix.close (fd) == 0);
    run ({"mformat", "-i", path, "::"});
    return path;
}

private void test_counter_listing () {
    try {
        assert (InstallerDaemon.NormalSeedCarrier.counter_is_present (
            "- 0x81000001\n- 0x1801100\n"));
        assert (!InstallerDaemon.NormalSeedCarrier.counter_is_present ("- 0x81000001\n"));
        assert (!InstallerDaemon.NormalSeedCarrier.counter_is_present (""));
        try {
            InstallerDaemon.NormalSeedCarrier.counter_is_present ("TPM unavailable\n");
            assert_not_reached ();
        } catch (GLib.Error e) { }
    } catch (GLib.Error e) { assert_not_reached (); }
}

private void test_preflight () {
    try {
        InstallerDaemon.NormalSeedCarrier.require_carrier (false, false);
        InstallerDaemon.NormalSeedCarrier.require_carrier (true, true);
        try {
            InstallerDaemon.NormalSeedCarrier.require_carrier (true, false);
            assert_not_reached ();
        } catch (GLib.IOError.BUSY e) { }
    } catch (GLib.Error e) { assert_not_reached (); }
}

private void test_esp_offsets () {
    const string TABLE = "{\"partitiontable\":{\"label\":\"gpt\",\"sectorsize\":512,\"partitions\":[" +
        "{\"start\":2048,\"size\":1048576,\"type\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\"}," +
        "{\"start\":1050624,\"size\":4096,\"type\":\"linux-swap\"}]}}";
    try {
        var offsets = InstallerDaemon.NormalSeedCarrier.esp_offsets (TABLE);
        assert (offsets.length == 1 && offsets[0] == 1048576);
        var dos = InstallerDaemon.NormalSeedCarrier.esp_offsets (
            "{\"partitiontable\":{\"label\":\"dos\",\"sectorsize\":512,\"partitions\":[" +
            "{\"start\":2048,\"size\":1048576,\"type\":\"ef\"}]}}");
        assert (dos.length == 1 && dos[0] == 1048576);
        try {
            InstallerDaemon.NormalSeedCarrier.esp_offsets (
                TABLE.replace ("2048", "-1"));
            assert_not_reached ();
        } catch (GLib.Error e) { }
        try {
            InstallerDaemon.NormalSeedCarrier.esp_offsets ("{\"partitiontable\":{\"label\":\"gpt\"}}");
            assert_not_reached ();
        } catch (GLib.Error e) { }
    } catch (GLib.Error e) { assert_not_reached (); }
}

private void test_stage_and_copy () {
    string? work = null;
    try {
        work = DirUtils.make_tmp ("normal-seed-carrier-XXXXXX");
        var source = make_image (work, "source.img");
        var destination = make_image (work, "destination.img");
        run ({"mmd", "-i", source, "::/EFI"});
        run ({"mmd", "-i", source, "::/EFI/Vale"});
        run ({"mmd", "-i", destination, "::/EFI"});
        run ({"mmd", "-i", destination, "::/EFI/Vale"});

        var expected = new uint8[128];
        for (int i = 0; i < expected.length; i++) expected[i] = (uint8) (i ^ 0x5a);
        var fixture = Path.build_filename (work, "fixture");
        FileUtils.set_data (fixture, expected);
        run ({"mcopy", "-i", source, fixture, "::/EFI/Vale/normal-seed"});

        var staged = InstallerDaemon.NormalSeedCarrier.stage_from_target (source, {0}, work);
        assert (staged != null);
        InstallerDaemon.NormalSeedCarrier.copy_to_new_esp (staged, destination, 0, work);
        var actual_path = Path.build_filename (work, "actual");
        run ({"mcopy", "-o", "-i", destination, "::/EFI/Vale/normal-seed", actual_path});
        uint8[] actual;
        FileUtils.get_data (actual_path, out actual);
        assert (actual.length == expected.length);
        for (int i = 0; i < actual.length; i++) assert (actual[i] == expected[i]);

        var changed = new uint8[128];
        for (int i = 0; i < changed.length; i++) changed[i] = (uint8) (i ^ 0xa5);
        FileUtils.set_data (fixture, changed);
        run ({"mcopy", "-o", "-i", source, fixture, "::/EFI/Vale/normal-seed"});
        var restaged = InstallerDaemon.NormalSeedCarrier.stage_from_target (source, {0}, work);
        assert (restaged != null);
        uint8[] restaged_data;
        FileUtils.get_data (restaged, out restaged_data);
        assert (restaged_data.length == changed.length);
        for (int i = 0; i < changed.length; i++) assert (restaged_data[i] == changed[i]);
        InstallerDaemon.NormalSeedCarrier.copy_to_new_esp (restaged, destination, 0, work);
        run ({"mcopy", "-o", "-i", destination, "::/EFI/Vale/normal-seed", actual_path});
        FileUtils.get_data (actual_path, out actual);
        for (int i = 0; i < changed.length; i++) assert (actual[i] == changed[i]);

        try {
            InstallerDaemon.NormalSeedCarrier.stage_from_target (source, {0, 0}, work);
            assert_not_reached ();
        } catch (GLib.IOError.BUSY e) { }

        var oversized = new uint8[4097];
        FileUtils.set_data (fixture, oversized);
        run ({"mcopy", "-o", "-i", source, fixture, "::/EFI/Vale/normal-seed"});
        try {
            InstallerDaemon.NormalSeedCarrier.stage_from_target (source, {0}, work);
            assert_not_reached ();
        } catch (GLib.Error e) {
            assert (e.message.contains ("exceeds 4096 bytes"));
        }
    } catch (GLib.Error e) {
        Test.message (e.message);
        assert_not_reached ();
    } finally {
        if (work != null) {
            try { run ({"rm", "-rf", "--", work}); } catch (GLib.Error e) { }
        }
    }
}

private void test_missing_carrier () {
    string? work = null;
    try {
        work = DirUtils.make_tmp ("normal-seed-missing-XXXXXX");
        var source = make_image (work, "source.img");
        assert (InstallerDaemon.NormalSeedCarrier.stage_from_target (source, {0}, work) == null);
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
    Test.add_func ("/normal-seed/counter-listing", test_counter_listing);
    Test.add_func ("/normal-seed/preflight", test_preflight);
    Test.add_func ("/normal-seed/esp-offsets", test_esp_offsets);
    Test.add_func ("/normal-seed/stage-copy-verify", test_stage_and_copy);
    Test.add_func ("/normal-seed/missing", test_missing_carrier);
    return Test.run ();
}
