/* SPDX-License-Identifier: GPL-3.0-or-later */
// Exercise the production owner form with inert admission and installation boundaries.
namespace Installer {
    public class App : Object { public static bool test_mode = true; }
    public class Daemon : Object {
        public static uint calls;
        [CCode (cname = "vale_credentials_validate", cheader_filename = "OwnerCredentials.h")]
        private static extern bool validate_credentials (int owner, int recovery, int hibernate,
            string hostname, out string username, out uint64 offset, out uint64 size) throws Error;
        public static Daemon get_default () { return new Daemon (); }
        public async void install_dave (InstallerDaemon.InstallConfig config, string disk,
            UnixInputStream owner, UnixInputStream recovery, UnixInputStream hibernate) throws Error {
            calls++;
            string username;
            uint64 offset, size;
            assert (validate_credentials (owner.get_fd (), recovery.get_fd (), hibernate.get_fd (),
                config.hostname, out username, out offset, out size));
            assert (username == "vale" && size == 9);
            throw new IOError.FAILED ("Fixture backend refusal");
        }
    }
}
namespace InstallerDaemon {
    internal class DaveReadiness {
        internal static void require_no_swap () throws GLib.Error { }
    }
    public struct InstallConfig {
        public string hostname;
        public string keyboard_layout;
        public string keyboard_variant;
        public string lang;
        public bool modify_boot_order;
        public bool install_drivers;
    }
}
public class Configuration : Object {
    private static Configuration instance;
    public string disk = "unused";
    public string keyboard_layout = "us";
    public string? keyboard_variant = null;
    public string lang = "en";
    public string? country = "US";
    public bool install_drivers = false;
    public static unowned Configuration get_default () {
        if (instance == null) instance = new Configuration ();
        return instance;
    }
}
namespace LocaleHelper {
    public async bool language2locale (string language, out string? locale) {
        locale = "en_US.UTF-8";
        return true;
    }
}
private Gtk.Widget? control (Gtk.Widget root, string label) {
    if (root is Gtk.Label && ((Gtk.Label) root).label == label) {
        return ((Gtk.Label) root).mnemonic_widget;
    }
    if (root is Gtk.Button && ((Gtk.Button) root).label == label) return root;
    if (root is Gtk.CheckButton && ((Gtk.CheckButton) root).label == label) return root;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = control (child, label);
        if (found != null) return found;
    }
    return null;
}
private bool message (Gtk.Widget root, string fragment) {
    if (root is Gtk.Label && ((Gtk.Label) root).label.contains (fragment)) return true;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        if (message (child, fragment)) return true;
    }
    return false;
}
private Gtk.Entry field (Gtk.Widget root, string label) {
    var widget = control (root, label);
    assert (widget is Gtk.Entry);
    return (Gtk.Entry) widget;
}
public static int main (string[] args) {
    if (!Gtk.init_check ()) return 77;
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var view = new OwnerView ();
    var navigation = new Adw.NavigationView ();
    navigation.add (view);
    var window = new Gtk.Window () { child = navigation, default_width = 850, default_height = 600 };
    window.present ();
    var loop = new MainLoop ();
    Timeout.add (200, () => { loop.quit (); return Source.REMOVE; });
    loop.run ();
    var username = field (view, "Username");
    var name = field (view, "Full Name");
    var hostname = field (view, "Computer Name");
    var password = field (view, "Owner Password");
    var confirmation = field (view, "Confirm Password");
    var recovery = field (view, "Drive Recovery Credential");
    assert (control (view, "Hibernation Recovery Credential") == null);
    var saved = (Gtk.CheckButton) control (view, "I saved the drive recovery credential");
    var submit = (Gtk.Button) control (view, "Erase and Install");
    assert (saved != null && submit != null);
    username.text = "owner";
    name.text = "Test User";
    hostname.text = "fixture";
    recovery.text = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    password.text = "short";
    confirmation.text = password.text;
    saved.active = true;
    assert (!submit.sensitive && message (view, "at least 8"));
    username.text = "star";
    password.text = "star-quart77!";
    confirmation.text = password.text;
    var feedback = password.get_next_sibling () as Gtk.Label;
    assert (feedback != null && feedback.label != "");
    assert (password.has_css_class ("error") && !submit.sensitive);
    username.text = "owner";
    assert (feedback.label == "" && !password.has_css_class ("error") && submit.sensitive);
    password.text = "quartzLemon!47.Nebula";
    confirmation.text = password.text;
    assert (submit.sensitive);
    confirmation.text = "different";
    assert (!submit.sensitive && message (view, "do not match"));
    confirmation.text = password.text;
    hostname.text = "invalid name";
    assert (!submit.sensitive && message (view, "computer name"));
    hostname.text = "fixture";
    username.text = "Invalid";
    assert (!submit.sensitive && message (view, "lowercase"));
    username.text = "owner";
    saved.active = false;
    assert (!submit.sensitive && message (view, "Save the drive"));
    saved.active = true;
    assert (submit.sensitive);
    foreach (var key in new Gtk.Entry[] {recovery}) {
        assert (key.buffer is Gtk.PasswordEntryBuffer);
        assert (key.visibility && !key.editable);
        int width, height;
        key.create_pango_layout (key.text).get_pixel_size (out width, out height);
        assert (key.get_width () >= width + 16);
    }
    submit.clicked ();
    assert (Installer.Daemon.calls == 0);
    assert (password.text == "" && confirmation.text == "" && recovery.text == "");
    assert (!submit.sensitive);
    Installer.App.test_mode = false;
    var failed = new OwnerView ();
    navigation.push (failed);
    Timeout.add (200, () => { loop.quit (); return Source.REMOVE; });
    loop.run ();
    field (failed, "Username").text = "vale";
    field (failed, "Full Name").text = "vale";
    field (failed, "Computer Name").text = "horizon";
    // A nine-character password must reach the backend before its refusal.
    field (failed, "Owner Password").text = "P7x!M2q@R";
    field (failed, "Confirm Password").text = field (failed, "Owner Password").text;
    var failed_saved = (Gtk.CheckButton) control (failed, "I saved the drive recovery credential");
    failed_saved.active = true;
    var failed_submit = (Gtk.Button) control (failed, "Erase and Install");
    assert (failed_submit.sensitive);
    failed_submit.clicked ();
    Timeout.add (200, () => { loop.quit (); return Source.REMOVE; });
    loop.run ();
    assert (Installer.Daemon.calls == 1);
    assert (message (failed, "DAVE installation is unavailable"));
    assert (!message (failed, "Fixture backend refusal"));
    assert (field (failed, "Owner Password").text == "");
    assert (field (failed, "Confirm Password").text == "");
    assert (field (failed, "Drive Recovery Credential").text == "");
    assert (!failed_saved.active && !failed_submit.sensitive);
    assert (!message (failed, "at least 8"));
    window.destroy ();
    return 0;
}
