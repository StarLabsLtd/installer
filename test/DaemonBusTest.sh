#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

bus=$(dbus-daemon --session --fork --print-address=1 --print-pid=1)
DBUS_SYSTEM_BUS_ADDRESS=$(printf '%s\n' "$bus" | head -n 1)
bus_pid=$(printf '%s\n' "$bus" | tail -n 1)
export DBUS_SYSTEM_BUS_ADDRESS
daemon_pid=
cleanup() {
    if [ -n "$daemon_pid" ]; then
        kill "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    kill "$bus_pid" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

"$1" &
daemon_pid=$!
has_owner() {
    gdbus call --address "$1" --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner io.elementary.InstallerDaemon
}

for _ in $(seq 1 50); do
    if [ "$(has_owner "$DBUS_SYSTEM_BUS_ADDRESS")" = '(true,)' ]; then
        break
    fi
    sleep 0.1
done
test "$(has_owner "$DBUS_SYSTEM_BUS_ADDRESS")" = '(true,)'
test "$(has_owner "$DBUS_SESSION_BUS_ADDRESS")" = '(false,)'

# The privileged backend must remain available while a long install runs.
sleep 15
kill -0 "$daemon_pid"
test "$(has_owner "$DBUS_SYSTEM_BUS_ADDRESS")" = '(true,)'
