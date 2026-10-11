/*-
 * Copyright 2019 elementary, Inc (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: Corentin Noël <corentin@elementary.io>
 */

public class Installer.KeyboardLayout : GLib.Object {



    public string name { get; construct; }
    public string original_name { get; construct; }
    public string display_name {
        get {
            return dgettext ("xkeyboard-config", original_name);
        }
    }

    private GLib.ListStore variants_store;

    public KeyboardLayout (string name, string original_name) {
        Object (name: name, original_name: original_name);
    }

    construct {
        variants_store = new GLib.ListStore (typeof (KeyboardVariant));
        variants_store.append (new KeyboardVariant (this, null, null));
    }

    public void add_variant (string name, string original_name) {
        var variant = new KeyboardVariant (this, name, original_name);
        variants_store.insert_sorted (variant, (GLib.CompareDataFunc<GLib.Object>) KeyboardVariant.compare);
    }

    public bool has_variants () {
        return variants_store.get_n_items () > 1;
    }

    public unowned GLib.ListStore get_variants () {
        return variants_store;
    }

    public GLib.Variant to_gsd_variant () {
        return KeyboardSources.from_layout (name);
    }

    public static int compare (KeyboardLayout a, KeyboardLayout b) {
        return a.display_name.collate (b.display_name);
    }

    public static GLib.ListStore get_all () {
        var layout_store = new GLib.ListStore (typeof (KeyboardLayout));

        var xkb_context = new Rxkb.Context (NO_FLAGS);
        xkb_context.parse_default_ruleset ();

        var xkb_layout = xkb_context.get_first_layout ();
        while (xkb_layout != null) {
            var layout = new KeyboardLayout (xkb_layout.get_name (), xkb_layout.get_description ());
            layout_store.insert_sorted (layout, (GLib.CompareDataFunc<GLib.Object>) KeyboardLayout.compare);

            var next_layout = xkb_layout.next ();
            while (next_layout != null && next_layout.get_variant () != null) {
                layout.add_variant (next_layout.get_variant (), next_layout.get_description ());

                next_layout = next_layout.next ();
            }

            xkb_layout = next_layout;
        }

        return layout_store;
    }
}
