// Compile the production views with inert power actions.
namespace Utils {
    public static uint restart_calls;
    public static string get_pretty_name () {
        return "Vale";
    }
    public static void restart () {
        restart_calls++;
    }
    public static void shutdown () {}
}

namespace Installer {
    public class App : Object {
        public static bool test_mode = false;
    }
}

private bool has_label (Gtk.Widget widget, string text) {
    if (widget is Gtk.Label && ((Gtk.Label) widget).label == text) {
        return true;
    }
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        if (has_label (child, text)) {
            return true;
        }
    }
    return false;
}

public static int main (string[] args) {
    if (!Gtk.init_check ()) {
        return 77;
    }
    Adw.init ();
    var normal = new SuccessView ();
    var dave = new SuccessView (true);
    var loop = new MainLoop ();
    Timeout.add_seconds (32, () => {
        loop.quit ();
        return Source.REMOVE;
    });
    loop.run ();
    assert_cmpuint (Utils.restart_calls, CompareOperator.EQ, 1);
    assert (normal != null);
    assert (has_label (dave, "Remove the installation media and select the installed drive in your firmware boot menu to finish commissioning."));
    return 0;
}
