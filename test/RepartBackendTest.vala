/* SPDX-License-Identifier: GPL-3.0-or-later */

private enum FailurePoint {
    DRY_RUN,
    REAL_REPART
}

private class TestExecutor : InstallerDaemon.RepartExecutor {
    internal FailurePoint failure_point;
    internal string media;
    internal int repart_calls;
    internal int wipe_calls;
    internal int unmount_calls;
    internal bool fail_unmount;
    internal string keyfile = "";
    internal string mount_path = "";

    internal TestExecutor (FailurePoint failure_point, string media, bool fail_unmount = false) {
        this.failure_point = failure_point;
        this.media = media;
        this.fail_unmount = fail_unmount;
    }

    internal override string capture (string[] argv) throws GLib.Error {
        if (argv[0] == "findmnt") {
            return media;
        }
        assert (argv[0] == "systemd-repart");
        repart_calls++;
        foreach (var arg in argv) {
            if (arg.has_prefix ("--key-file=")) {
                keyfile = arg.substring (11);
            }
        }
        if ((failure_point == DRY_RUN && repart_calls == 1) ||
            (failure_point == REAL_REPART && repart_calls == 2)) {
            throw new IOError.FAILED (repart_calls == 1 ? "dry run rejected" : "real repart rejected");
        }
        return "accepted";
    }

    internal override void run (string[] argv) throws GLib.Error {
        if (argv[0] == "mount") {
            mount_path = argv[argv.length - 1];
            FileUtils.set_contents (Path.build_filename (mount_path, "image.raw"), "image");
            FileUtils.set_contents (Path.build_filename (mount_path, "mounted-sentinel"), "mounted");
        } else if (argv[0] == "/usr/sbin/wipefs") {
            wipe_calls++;
        } else if (argv[0] == "umount") {
            unmount_calls++;
            if (fail_unmount) {
                throw new IOError.FAILED ("test unmount failure");
            }
            FileUtils.remove (Path.build_filename (mount_path, "image.raw"));
            FileUtils.remove (Path.build_filename (mount_path, "mounted-sentinel"));
        }
    }
}

private class Fixture : Object {
    internal string root;
    internal string definitions;
    internal string media;
    internal string work_template;

    internal Fixture () {
        root = DirUtils.mkdtemp (Path.build_filename (Environment.get_tmp_dir (), "repart-backend-test-XXXXXX"));
        definitions = Path.build_filename (root, "definitions");
        media = Path.build_filename (root, "media");
        var extra = Path.build_filename (media, "extra");
        DirUtils.create_with_parents (definitions, 0700);
        DirUtils.create_with_parents (extra, 0700);
        try {
            FileUtils.set_contents (Path.build_filename (definitions, "40-root.conf"), "[Partition]\nEncrypt=off\n");
            FileUtils.set_contents (Path.build_filename (extra, "install.raw.squashfs"), "image");
        } catch (FileError e) {
            assert_not_reached ();
        }
        work_template = Path.build_filename (root, "work-XXXXXX");
    }

    internal void remove () {
        remove_tree (File.new_for_path (root));
    }
}

private void remove_tree (File file) {
    try {
        var enumerator = file.enumerate_children (FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? info;
        while ((info = enumerator.next_file ()) != null) {
            var child = file.get_child (info.get_name ());
            if (info.get_file_type () == FileType.DIRECTORY) {
                remove_tree (child);
            } else {
                child.delete ();
            }
        }
        enumerator.close ();
        file.delete ();
    } catch (Error e) {
        assert_not_reached ();
    }
}

private void run_failure (FailurePoint point, bool fail_unmount = false) {
    var fixture = new Fixture ();
    var executor = new TestExecutor (point, fixture.media, fail_unmount);
    var backend = new InstallerDaemon.RepartBackend.for_test (
        executor, fixture.definitions, fixture.work_template
    );
    bool completed = false;
    backend.on_log_message.connect ((level, message) => {
        if (message == "Completed!") completed = true;
    });

    try {
        backend.install_with_default_disk_layout (InstallerDaemon.InstallConfig (), "/dev/test-disk", true, "secret");
        assert_not_reached ();
    } catch (Error e) {
        assert (point == DRY_RUN ? "dry run rejected" in e.message : "real repart rejected" in e.message);
    }

    assert (!completed);
    assert (executor.repart_calls == (point == DRY_RUN ? 1 : 2));
    assert (executor.wipe_calls == (point == DRY_RUN ? 0 : 1));
    assert (executor.unmount_calls == 1);
    assert (executor.keyfile != "");
    assert (!FileUtils.test (executor.keyfile, FileTest.EXISTS));
    if (fail_unmount) {
        assert (FileUtils.test (Path.build_filename (executor.mount_path, "mounted-sentinel"), FileTest.EXISTS));
    } else {
        assert (!FileUtils.test (executor.mount_path, FileTest.EXISTS));
    }
    fixture.remove ();
}

public int main (string[] args) {
    Test.init (ref args);
    GLib.Log.set_always_fatal (GLib.LogLevelFlags.LEVEL_ERROR);
    Test.add_func ("/repart-backend/dry-run-stops-before-wipe", () => run_failure (DRY_RUN));
    Test.add_func ("/repart-backend/real-repart-prevents-success", () => run_failure (REAL_REPART));
    Test.add_func ("/repart-backend/failed-unmount-does-not-traverse-mount", () => run_failure (DRY_RUN, true));
    return Test.run ();
}
