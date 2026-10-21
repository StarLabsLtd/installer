/* SPDX-License-Identifier: GPL-3.0-or-later */
private void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/dave/bios-vendor", () => {
        assert (InstallerDaemon.DaveReadiness.matches_bios_vendor ("DAVE\n"));
        foreach (string vendor in new string[] {"DAVE \n", " DAVE\n", "DAVE\r\n", "DAVE\n\n", "dave\n", "EDK II\n", ""}) {
            assert (!InstallerDaemon.DaveReadiness.matches_bios_vendor (vendor));
        }
    });
    Test.add_func ("/dave/firmware-admission", () => {
#if TEST_DAVE_VISIBILITY
        assert (InstallerDaemon.DaveReadiness.allows_dave_firmware ());
#else
        string vendor = "";
        try {
            FileUtils.get_contents ("/sys/class/dmi/id/bios_vendor", out vendor);
        } catch (FileError e) { }
        assert (InstallerDaemon.DaveReadiness.allows_dave_firmware () == (vendor == "DAVE\n"));
#endif
    });
    Test.add_func ("/dave/swap-admission", () => {
        var header = "Filename\tType\tSize\tUsed\tPriority\n";
        try {
            InstallerDaemon.DaveReadiness.check_swap_contents (header);
        } catch (Error e) { Test.fail (); }
        foreach (var contents in new string[] {
            header + "/dev/zram0 partition 8388608 0 100\n",
            ""
        }) {
            try {
                InstallerDaemon.DaveReadiness.check_swap_contents (contents);
                Test.fail ();
            } catch (IOError e) {
                assert (e is IOError.PERMISSION_DENIED || e is IOError.FAILED);
            } catch (Error e) { Test.fail (); }
        }
    });
    Test.run ();
}
