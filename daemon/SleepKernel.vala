/* SPDX-License-Identifier: GPL-3.0-or-later */
internal class InstallerDaemon.SleepKernel {
    internal static void require_dave_hibernation (string config, uint8[] command_line) throws GLib.Error {
        require_kernel (config);
        // Match the producer's literal command-line syntax and x86 input limit.
        int length = command_line.length;
        while (length > 0 && command_line[length - 1] == 0) length--;
        if (length == 0 || length >= 2048) {
            throw new IOError.NOT_SUPPORTED ("Invalid Dave target command line");
        }
        var text = new StringBuilder ();
        for (int i = 0; i < length; i++) {
            var c = command_line[i];
            if (c < 0x20 || c >= 0x7f || c == '\"' || c == '\'') {
                throw new IOError.NOT_SUPPORTED ("Nonliteral Dave target command line");
            }
            text.append_c ((char) c);
        }
        bool suspend = false;
        bool mode = false;
        foreach (var word in text.str.split (" ")) {
            var key = word.split ("=", 2)[0];
            if (word == "--") {
                throw new IOError.NOT_SUPPORTED ("Dave target command-line delimiter is not supported");
            }
            if (key == "suspend") {
                if (suspend || word != "suspend=off") {
                    throw new IOError.NOT_SUPPORTED ("Invalid Dave target suspend policy");
                }
                suspend = true;
            } else if (key == "vale.mode") {
                if (mode || word != "vale.mode=dave") {
                    throw new IOError.NOT_SUPPORTED ("Invalid Dave target boot mode");
                }
                mode = true;
            }
        }
        if (!suspend || !mode) {
            throw new IOError.NOT_SUPPORTED ("Dave target requires signed vale.mode=dave and suspend=off");
        }
    }

    internal static void require_normal_hibernation (string config) throws GLib.Error {
        require_kernel (config);
    }

    private static void require_kernel (string config) throws GLib.Error {
        var keys = new HashTable<string, string> (str_hash, str_equal);
        foreach (var line in config.split ("\n")) {
            string key;
            string value;
            if (line.has_prefix ("CONFIG_")) {
                var setting = line.split ("=", 2);
                if (setting.length != 2) throw new IOError.FAILED ("Invalid target kernel configuration");
                key = setting[0];
                value = setting[1];
            } else if (line.has_prefix ("# CONFIG_") && line.has_suffix (" is not set")) {
                key = line.substring (2, line.length - 13);
                value = "n";
            } else {
                continue;
            }
            if (keys.contains (key)) throw new IOError.FAILED ("Duplicate target kernel configuration: %s", key);
            keys.insert (key, value);
        }
        if (keys.lookup ("CONFIG_SUSPEND") != "y" ||
            keys.lookup ("CONFIG_PM_SLEEP_S2IDLE") != "y" ||
            keys.lookup ("CONFIG_HIBERNATION") != "y" ||
            keys.lookup ("CONFIG_HIBERNATION_SNAPSHOT_DEV") != "y" ||
            keys.lookup ("CONFIG_ENCRYPTED_HIBERNATION") != "y") {
            throw new IOError.NOT_SUPPORTED (
                "Installation requires the shared target kernel with encrypted snapshots"
            );
        }
    }
}
