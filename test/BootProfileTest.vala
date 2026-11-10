/* SPDX-License-Identifier: GPL-3.0-or-later */
private string command (string[] argv) throws GLib.Error {
    return InstallerDaemon.RepartCommand.capture (argv);
}

private void check_profile (bool dave) {
    string? work = null;
    try {
        work = DirUtils.make_tmp ("installed-boot-profile-XXXXXX");
        var image = work + "/esp.img";
        command ({"truncate", "-s", "8M", image});
        command ({"mformat", "-i", image, "::"});
        command ({"mmd", "-i", image, "::/EFI", "::/EFI/Linux"});
        var payload = work + "/payload";
        FileUtils.set_contents (payload, "public profile fixture");
        string[] names = {"elementary_123.efi", "elementary-normal-commission_123.efi",
                          "elementary-dave_123.efi", "unrelated.efi"};
        foreach (var name in names) {
            command ({"mcopy", "-i", image, payload, "::/EFI/Linux/" + name});
        }
        InstallerDaemon.NormalBoot.select_profile (image, dave, command);
        var entries = command ({"mtools", "-c", "mdir", "-b", "-i", image, "::/EFI/Linux"});
        assert (entries.contains ("elementary_123.efi") == !dave);
        assert (entries.contains ("elementary-normal-commission_123.efi") == !dave);
        assert (entries.contains ("elementary-dave_123.efi") == dave);
        assert (entries.contains ("unrelated.efi"));
        InstallerDaemon.NormalBoot.select_profile (image, dave, command);
        assert (command ({"mtools", "-c", "mdir", "-b", "-i", image, "::/EFI/Linux"}) == entries);
    } catch (GLib.Error e) {
        Test.message (e.message);
        Test.fail ();
    } finally {
        if (work != null) {
            try { command ({"rm", "-rf", "--", work}); } catch (GLib.Error e) { Test.fail (); }
        }
    }
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/boot-profile/normal", () => check_profile (false));
    Test.add_func ("/boot-profile/dave", () => check_profile (true));
    return Test.run ();
}
