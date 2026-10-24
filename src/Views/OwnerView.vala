/* SPDX-License-Identifier: GPL-3.0-or-later */
public class OwnerView : AbstractInstallerView {
    public signal void installation_finished ();
    [CCode (cname = "vale_recovery_generate", cheader_filename = "OwnerCredentials.h")]
    private static extern string generate_recovery () throws GLib.Error;
    [CCode (cname = "vale_owner_credentials_fd", cheader_filename = "OwnerCredentials.h")]
    private static extern int owner_fd (string username, string full_name, string hostname, string password) throws GLib.Error;
    [CCode (cname = "vale_recovery_fd", cheader_filename = "OwnerCredentials.h")]
    private static extern int recovery_fd (string recovery) throws GLib.Error;
    [CCode (cname = "vale_owner_password_valid", cheader_filename = "OwnerCredentials.h")]
    private static extern bool password_valid (string username, string password);

    private Gtk.Entry username;
    private Gtk.Entry full_name;
    private Gtk.Entry hostname;
    private Gtk.Entry password;
    private Gtk.Entry confirmation;
    private Gtk.Entry recovery;
    private Gtk.Entry hibernate_recovery;
    private Gtk.CheckButton acknowledged;
    private Gtk.Button submit;
    private Gtk.Label status;
    private Gtk.Spinner spinner;
    private bool pending = false;

    public OwnerView () {
        Object (cancellable: true);
    }

    construct {
        title = _("DAVE Owner and Recovery");
        title_area.append (new Gtk.Label (title) { wrap = true });
        title_area.append (new Gtk.Label (_("Your account password also unlocks the encrypted drive. Keep both recovery credentials separately.")) { wrap = true });
        spinner = new Gtk.Spinner () { visible = false };
        title_area.append (spinner);
        content_area.spacing = 6;
        username = entry (_("Username"));
        full_name = entry (_("Full Name"));
        hostname = entry (_("Computer Name"));
        password = entry (_("Owner Password"), true);
        confirmation = entry (_("Confirm Password"), true);
        recovery = entry (_("Drive Recovery Credential"), true);
        recovery.visibility = true;
        recovery.editable = false;
        hibernate_recovery = entry (_("Hibernation Recovery Credential"), true);
        hibernate_recovery.visibility = true;
        hibernate_recovery.editable = false;
        acknowledged = new Gtk.CheckButton.with_label (_("I saved BOTH recovery credentials separately"));
        content_area.append (acknowledged);
        status = new Gtk.Label (null) { wrap = true, xalign = 0 };
        content_area.append (status);
        submit = new Gtk.Button.with_label (_("Erase and Install")) { sensitive = false };
        action_box_end.append (submit);
        foreach (var field in new Gtk.Entry[] {username, full_name, hostname, password, confirmation}) {
            field.changed.connect (update_submit);
        }
        acknowledged.toggled.connect (update_submit);
        shown.connect (() => {
            try {
                // The generated temporary is erased before its allocation is freed.
                InstallerDaemon.DaveReadiness.require_no_swap ();
                recovery.text = "";
                hibernate_recovery.text = "";
                acknowledged.active = false;
                var value = generate_recovery ();
                recovery.text = value;
                wipe (value);
                value = generate_recovery ();
                hibernate_recovery.text = value;
                wipe (value);
            } catch (GLib.Error e) {
                status.label = _("Recovery credential generation failed. Go back and try again.");
            }
            update_submit ();
        });
        hidden.connect (clear_secrets);
        submit.clicked.connect (() => request_installation.begin ());
    }

    [CCode (cname = "explicit_bzero", cheader_filename = "string.h")]
    private static extern void clear_bytes (void* data, size_t size);

    private static void wipe (string value) {
        clear_bytes ((void*) value, value.length);
    }

    private Gtk.Entry entry (string label, bool secret = false) {
        var field = new Gtk.Entry ();
        if (secret) {
            field.buffer = new Gtk.PasswordEntryBuffer ();
            field.visibility = false;
        }
        content_area.append (new Gtk.Label (label) { xalign = 0, mnemonic_widget = field });
        content_area.append (field);
        return field;
    }

    private bool valid_fields () {
        return Regex.match_simple ("\\A[a-z_][a-z0-9_-]{0,31}\\z", username.text) &&
            Regex.match_simple ("\\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z", hostname.text) &&
            full_name.text.length > 0 && full_name.text.length <= 256 && !full_name.text.contains (":") &&
            !full_name.text.contains ("\n") && !full_name.text.contains ("\r") &&
            password.text.length >= 12 && password.text.length <= 511 &&
            !password.text.contains ("\n") && !password.text.contains ("\r") &&
            password.text == confirmation.text && recovery.text.length == 64 &&
            hibernate_recovery.text.length == 64 && recovery.text != hibernate_recovery.text &&
            password.text != recovery.text && password.text != hibernate_recovery.text && acknowledged.active &&
            password_valid (username.text, password.text);
    }

    private void update_submit () {
        submit.sensitive = !pending && valid_fields ();
    }

    private void clear_secrets () {
        password.text = "";
        confirmation.text = "";
        recovery.text = "";
        hibernate_recovery.text = "";
        acknowledged.active = false;
    }

    private async void request_installation () {
        if (pending || !valid_fields ()) return;
        if (Installer.App.test_mode) {
            clear_secrets ();
            status.label = _("Test mode does not install to disk.");
            return;
        }
        pending = true;
        can_pop = false;
        content_area.sensitive = false;
        action_box_end.sensitive = false;
        status.label = _("Installing…");
        spinner.visible = true;
        spinner.start ();
        update_submit ();
        GLib.UnixInputStream? owner = null;
        GLib.UnixInputStream? key = null;
        GLib.UnixInputStream? hibernate_key = null;
        try {
            InstallerDaemon.DaveReadiness.require_no_swap ();
            owner = new GLib.UnixInputStream (owner_fd (username.text, full_name.text, hostname.text, password.text), true);
            key = new GLib.UnixInputStream (recovery_fd (recovery.text), true);
            hibernate_key = new GLib.UnixInputStream (recovery_fd (hibernate_recovery.text), true);
            clear_secrets ();
            unowned var current = Configuration.get_default ();
            var disk = current.disk;
            var config = InstallerDaemon.InstallConfig () {
                hostname = hostname.text,
                keyboard_layout = current.keyboard_layout,
                keyboard_variant = current.keyboard_variant ?? "",
                lang = "en_US.UTF-8",
                modify_boot_order = true,
                install_drivers = current.install_drivers
            };
            string? locale;
            var language = current.lang;
            if (current.country != null && current.country != "") language += "_" + current.country;
            if (yield LocaleHelper.language2locale (language, out locale)) {
                if (locale != null) config.lang = locale;
            }
            yield Installer.Daemon.get_default ().install_dave (config, disk, owner, key, hibernate_key);
            installation_finished ();
        } catch (GLib.Error e) {
            // Never expose arbitrary remote error text in a credential flow.
            status.label = _("DAVE installation is unavailable. Go back to enter fresh credentials; no fallback installation was requested.");
        } finally {
            if (owner != null) { try { owner.close (); } catch (GLib.Error e) {} }
            if (key != null) { try { key.close (); } catch (GLib.Error e) {} }
            if (hibernate_key != null) { try { hibernate_key.close (); } catch (GLib.Error e) {} }
            clear_secrets ();
            pending = false;
            can_pop = true;
            spinner.stop ();
            spinner.visible = false;
            content_area.sensitive = true;
            action_box_end.sensitive = true;
            update_submit ();
        }
    }
}
