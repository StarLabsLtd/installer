/* SPDX-License-Identifier: GPL-3.0-or-later */

private void assert_failure (string[] argv, string expected) {
    try {
        InstallerDaemon.RepartCommand.capture (argv);
        assert_not_reached ();
    } catch (Error e) {
        assert_true (expected in e.message);
    }
}

private void test_success () {
    try {
        assert (InstallerDaemon.RepartCommand.capture ({ "sh", "-c", "printf success" }) == "success");
    } catch (Error e) {
        assert_not_reached ();
    }
}

private void test_nonzero () {
    assert_failure ({ "sh", "-c", "printf rejected >&2; exit 23" }, "exited with status 23: rejected");
}

private void test_success_stderr () {
    try {
        assert (InstallerDaemon.RepartCommand.capture ({
            "sh", "-c", "printf '[]'; printf 'Randomizing partition UUIDs\\n' >&2"
        }) == "[]");
    } catch (Error e) {
        assert_not_reached ();
    }
}

private void test_signal () {
    assert_failure ({ "sh", "-c", "kill -TERM $$" }, "terminated by signal");
}

private void test_launch_failure () {
    assert_failure ({ "/this/program/does/not/exist" }, "No such file");
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/repart-command/success", test_success);
    Test.add_func ("/repart-command/success-stderr", test_success_stderr);
    Test.add_func ("/repart-command/nonzero", test_nonzero);
    Test.add_func ("/repart-command/signal", test_signal);
    Test.add_func ("/repart-command/launch-failure", test_launch_failure);
    return Test.run ();
}
