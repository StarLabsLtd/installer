/* SPDX-License-Identifier: GPL-3.0-or-later */
public class InstallModeView : AbstractInstallerView {
    public bool dave_selected { get; private set; default = false; }

    public InstallModeView () {
        Object (cancellable: true);
    }

    construct {
        title = _("Choose Installation Mode");
        title_area.append (new Gtk.Label (title) { wrap = true });
        var normal = new Gtk.CheckButton.with_label (_("Normal Install"));
        var dave = new Gtk.CheckButton.with_label (_("Dave mode"));
        dave.group = normal;
        normal.active = true;
        content_area.append (normal);
        content_area.append (dave);
        var description = _("Normal Install offers optional drive encryption. Dave mode uses one password for your account and drive encryption, and hibernates instead of suspending.");
        content_area.append (new Gtk.Label (description) {
            wrap = true, xalign = 0
        });
        var next = new Gtk.Button.with_label (_("Continue"));
        action_box_end.append (next);
        normal.toggled.connect (() => { next.sensitive = normal.active || dave.active; });
        dave.toggled.connect (() => { next.sensitive = normal.active || dave.active; });
        next.clicked.connect (() => {
            dave_selected = dave.active;
            next_step ();
        });
    }
}
