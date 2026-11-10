/* SPDX-License-Identifier: GPL-3.0-or-later */
public class OwnerView : AbstractInstallerView {
    public signal void installation_finished ();
    [CCode (cname = "vale_recovery_generate", cheader_filename = "OwnerCredentials.h")]
    private static extern string generate_recovery () throws GLib.Error;
    [CCode (cname = "vale_owner_credentials_fd", cheader_filename = "OwnerCredentials.h")]
    private static extern int owner_fd (string username, string full_name, string hostname, string password) throws GLib.Error;
    [CCode (cname = "vale_recovery_fd", cheader_filename = "OwnerCredentials.h")]
    private static extern int recovery_fd (string recovery) throws GLib.Error;
    [CCode (cname = "vale_owner_password_error", cheader_filename = "OwnerCredentials.h")]
    private static extern string? password_policy_error (string username, string password);

    private Gtk.Entry username;
    private Gtk.Entry full_name;
    private Gtk.Entry hostname;
    private Gtk.Entry password;
    private Gtk.Label password_feedback;
    private Gtk.Entry confirmation;
    private Gtk.Entry recovery;
    private Gtk.Entry hibernate_recovery;
    private Gtk.CheckButton acknowledged;
    private Gtk.Button submit;
    private Gtk.Label status;
    private Gtk.Label validation;
    private Gtk.Spinner spinner;
    private bool pending = false;

    public OwnerView () {
        Object (cancellable: true);
    }

    construct {
        title = _("DAVE Owner and Recovery");
        body_area.orientation = Gtk.Orientation.VERTICAL;
        body_area.homogeneous = false;
        title_area.valign = Gtk.Align.START;
        title_area.remove_css_class (Granite.STYLE_CLASS_H2_LABEL);
        var heading = new Gtk.Label (title) { wrap = true };
        heading.add_css_class (Granite.STYLE_CLASS_H2_LABEL);
        title_area.append (heading);
        title_area.append (new Gtk.Label (_("Your account password also unlocks the encrypted drive. Keep both recovery credentials separately.")) { wrap = true });
        spinner = new Gtk.Spinner () { visible = false };
        title_area.append (spinner);
        content_area.spacing = 6;
        content_clamp.child = null;
        content_clamp.vexpand = true;
        content_clamp.child = new Gtk.ScrolledWindow () {
            child = content_area,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vscrollbar_policy = Gtk.PolicyType.AUTOMATIC
        };
        username = entry (_("Username"));
        full_name = entry (_("Full Name"));
        hostname = entry (_("Computer Name"));
        password = entry (_("Owner Password"), true);
        password.placeholder_text = _("At least 12 characters");
        password_feedback = new Gtk.Label (null) {
            wrap = true,
            xalign = 0,
            max_width_chars = 42
        };
        password_feedback.add_css_class ("error");
        content_area.append (password_feedback);
        confirmation = entry (_("Confirm Password"), true);
        recovery = entry (_("Drive Recovery Credential"), true);
        recovery.visibility = true;
        recovery.editable = false;
        hibernate_recovery = entry (_("Hibernation Recovery Credential"), true);
        hibernate_recovery.visibility = true;
        hibernate_recovery.editable = false;
        foreach (var field in new Gtk.Entry[] {recovery, hibernate_recovery}) {
            field.width_chars = 64;
            field.max_width_chars = 64;
            field.add_css_class ("monospace");
        }
        acknowledged = new Gtk.CheckButton.with_label (_("I saved BOTH recovery credentials separately"));
        content_area.append (acknowledged);
        status = new Gtk.Label (null) { wrap = true, xalign = 0 };
        content_area.append (status);
        submit = new Gtk.Button.with_label (_("Erase and Install")) { sensitive = false };
        validation = new Gtk.Label (null) {
            wrap = true,
            xalign = 0,
            max_width_chars = 42
        };
        action_box_start.append (validation);
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

    private string? validation_error () {
        if (!Regex.match_simple ("\\A[a-z_][a-z0-9_-]{0,31}\\z", username.text)) {
            return _("Use a username of up to 32 lowercase letters, numbers, underscores or hyphens, starting with a letter or underscore.");
        }
        if (!Regex.match_simple ("\\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z", hostname.text)) {
            return _("Use a computer name of up to 63 letters, numbers or hyphens, starting and ending with a letter or number.");
        }
        if (full_name.text.length > 256) {
            return _("The full name is too long.");
        }
        if (full_name.text.length == 0 || full_name.text.contains (":") ||
            full_name.text.contains ("\n") || full_name.text.contains ("\r")) {
            return _("Enter a full name without colons or line breaks.");
        }
        if (password.text.length > 511) {
            return _("The password is too long.");
        }
        if (password.text.length < 12 ||
            password.text.contains ("\n") || password.text.contains ("\r")) {
            return _("Use a password of at least 12 characters, without line breaks.");
        }
        if (password.text != confirmation.text) {
            return _("The passwords do not match.");
        }
        var policy_error = password_policy_error (username.text, password.text);
        if (policy_error != null) {
            return policy_error;
        }
        if (recovery.text.length != 64 || hibernate_recovery.text.length != 64 ||
            recovery.text == hibernate_recovery.text) {
            return _("Recovery credentials are unavailable. Go back and try again.");
        }
        if (password.text == recovery.text || password.text == hibernate_recovery.text) {
            return _("Use a password different from either recovery credential.");
        }
        if (!acknowledged.active) {
            return _("Save both recovery credentials separately, then confirm that you have saved them.");
        }
        return null;
    }

    private void update_submit () {
        var error = validation_error ();
        var policy_error = password.text == "" ? null : password_policy_error (username.text, password.text);
        password_feedback.label = pending ? "" : policy_error ?? "";
        if (!pending && policy_error != null) {
            password.add_css_class ("error");
        } else {
            password.remove_css_class ("error");
        }
        validation.label = pending || error == policy_error ? "" : error ?? "";
        submit.sensitive = !pending && error == null;
    }

    private void clear_secrets () {
        password.text = "";
        confirmation.text = "";
        recovery.text = "";
        hibernate_recovery.text = "";
        acknowledged.active = false;
    }

    private async void request_installation () {
        if (pending || validation_error () != null) {
            return;
        }
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
