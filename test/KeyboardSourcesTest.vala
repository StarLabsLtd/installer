private void keyboard_sources () {
    try {
        assert (KeyboardSources.from_layout ("us").equal (
            Variant.parse (new VariantType ("a(ss)"), "[('xkb', 'us')]")));
        assert (KeyboardSources.from_layout ("de", "nodeadkeys").equal (
            Variant.parse (new VariantType ("a(ss)"), "[('xkb', 'de+nodeadkeys')]")));
        assert (KeyboardSources.from_layout ("ru").equal (
            Variant.parse (new VariantType ("a(ss)"), "[('xkb', 'us'), ('xkb', 'ru')]")));
        assert (KeyboardSources.from_layout ("de", "ru").equal (
            Variant.parse (new VariantType ("a(ss)"), "[('xkb', 'us'), ('xkb', 'de+ru')]")));
    } catch (VariantParseError e) {
        assert_not_reached ();
    }
}

public static int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/keyboard/sources", keyboard_sources);
    return Test.run ();
}
