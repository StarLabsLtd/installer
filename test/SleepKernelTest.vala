/* SPDX-License-Identifier: GPL-3.0-or-later */
private const string HIBERNATION = "CONFIG_HIBERNATION=y\nCONFIG_HIBERNATION_SNAPSHOT_DEV=y\nCONFIG_ENCRYPTED_HIBERNATION=y\n";

private const string SHARED = "CONFIG_SUSPEND=y\n# CONFIG_PM_SLEEP_S2IDLE is not set\nCONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y\n" + HIBERNATION;
private const string DAVE = "root=dissect vale.mode=dave suspend=off";

private void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/sleep/shared-dave-kernel", () => {
        try {
            InstallerDaemon.SleepKernel.require_dave_hibernation (SHARED, DAVE.data);
        } catch (Error e) { Test.fail (); }
    });
    Test.add_func ("/sleep/reject-incomplete-kernels", () => {
        foreach (var config in new string[] {
            "CONFIG_SUSPEND=y\n" + HIBERNATION,
            "CONFIG_SUSPEND=y\nCONFIG_PM_SLEEP_S2IDLE=y\n" + HIBERNATION,
            HIBERNATION,
            "CONFIG_SUSPEND=y\n# CONFIG_PM_SLEEP_S2IDLE is not set\nCONFIG_HIBERNATION=y\n"
        }) {
            try {
                InstallerDaemon.SleepKernel.require_dave_hibernation (config, DAVE.data);
                Test.fail ();
            } catch (IOError e) { assert (e is IOError.NOT_SUPPORTED); }
              catch (Error e) { Test.fail (); }
        }
    });
    Test.add_func ("/sleep/reject-conflicting-config", () => {
        try {
            InstallerDaemon.SleepKernel.require_dave_hibernation (
                "# CONFIG_SUSPEND is not set\n" + SHARED, DAVE.data);
            Test.fail ();
        } catch (IOError e) { assert (e is IOError.FAILED); }
          catch (Error e) { Test.fail (); }
    });
    Test.add_func ("/sleep/reject-unguarded-dave-command-line", () => {
        foreach (var command_line in new string[] {
            "vale.mode=dave", "suspend=off", "vale.mode=dave suspend=on",
            DAVE + " suspend=off", DAVE + " suspend", DAVE + " vale.mode=dave",
            "vale.mode=dave -- suspend=off", "vale.mode=dave suspend=\"off\"",
            DAVE + "\n", "vale.mode=dave-recovery suspend=off",
            string.nfill (2048, 'x') + " " + DAVE
        }) {
            try {
                InstallerDaemon.SleepKernel.require_dave_hibernation (SHARED, command_line.data);
                Test.fail ();
            } catch (IOError e) { assert (e is IOError.NOT_SUPPORTED); }
              catch (Error e) { Test.fail (); }
        }
    });
    Test.add_func ("/sleep/uki-command-line-padding", () => {
        var padded = new uint8[DAVE.length + 2];
        Memory.copy (padded, DAVE.data, DAVE.length);
        try {
            InstallerDaemon.SleepKernel.require_dave_hibernation (SHARED, padded);
        } catch (Error e) { Test.fail (); }
        padded[4] = 0;
        try {
            InstallerDaemon.SleepKernel.require_dave_hibernation (SHARED, padded);
            Test.fail ();
        } catch (IOError e) { assert (e is IOError.NOT_SUPPORTED); }
          catch (Error e) { Test.fail (); }
    });
    Test.add_func ("/sleep/normal-encrypted-backend", () => {
        try {
            InstallerDaemon.SleepKernel.require_normal_hibernation (SHARED);
        } catch (Error e) { Test.fail (); }
        foreach (var config in new string[] {
            "CONFIG_HIBERNATION=y\n# CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY is not set\n",
            "CONFIG_HIBERNATION=y\nCONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y\n",
            "CONFIG_HIBERNATION=y\nCONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT=y\n",
            "# CONFIG_HIBERNATION is not set\n",
            "CONFIG_SUSPEND=y\n# CONFIG_PM_SLEEP_S2IDLE is not set\nCONFIG_HIBERNATION=y\n",
            "CONFIG_SUSPEND=y\nCONFIG_PM_SLEEP_S2IDLE=y\n" + HIBERNATION,
            HIBERNATION
        }) {
            try {
                InstallerDaemon.SleepKernel.require_normal_hibernation (config);
                Test.fail ();
            } catch (IOError e) { assert (e is IOError.NOT_SUPPORTED); }
              catch (Error e) { Test.fail (); }
        }
    });
    Test.run ();
}
