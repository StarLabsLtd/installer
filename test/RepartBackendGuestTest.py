#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Three real-backend failure regressions; run manually in disposable recovery VM.

No backend test mode, private bus, executor injection or real target wipe.
See RepartBackendGuestTest.md before invoking this privileged guest-only test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET

BUS = "io.elementary.InstallerDaemon"
OBJECT = "/io/elementary/InstallerDaemon"
TARGET = Path("/dev/disk/by-id/virtio-vale-qa-target")
INVALID = "--vale-backend-regression-invalid-option"
CASES = ("real-repart", "dry-run", "busy-unmount")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=30, **kwargs)


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load(path):
    require(path.is_file() and path.stat().st_uid == 0 and
            path.stat().st_mode & 0o077 == 0, "Untrusted fixture state")
    return json.loads(path.read_text())


def save(path, value):
    temporary = path.with_suffix(".new")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def event(path, name, status=None):
    with (path.parent / "events.jsonl").open("a") as stream:
        stream.write(json.dumps(dict(time=time.time(), event=name, status=status)) + "\n")


def bus(method, *args):
    return command(["gdbus", "call", "--system", "--timeout", "10",
                    "--dest", "org.freedesktop.DBus", "--object-path",
                    "/org/freedesktop/DBus", "--method",
                    "org.freedesktop.DBus." + method, *args])


def namespace():
    return os.readlink("/proc/self/ns/mnt")


def fixture_target():
    require(os.geteuid() == 0, "Guest root required")
    require(command(["systemd-detect-virt", "--vm"]).stdout.strip() in ("kvm", "qemu"),
            "Only disposable QEMU fixture supported")
    require(namespace() != os.readlink("/proc/1/ns/mnt"), "Private mount namespace required")
    words = Path("/proc/cmdline").read_text().split()
    require("vale.mode=normal-recovery" in words and "boot=vale-live" in words and
            "live-media=/dev/mapper/vale-install-media" in words, "Normal recovery required")
    require(command(["getenforce"]).stdout.strip() == "Enforcing", "SELinux must stay enforcing")
    target = TARGET.resolve(strict=True)
    info = target.stat()
    require(stat.S_ISBLK(info.st_mode), "Fixture target is not a block device")
    sysblock = Path("/sys/class/block") / target.name
    require((sysblock / "device").exists() and not (sysblock / "partition").exists(),
            "Whole fixture disk required")
    serial = command(["lsblk", "--nodeps", "--noheadings", "-o", "SERIAL", str(target)])
    require(serial.returncode == 0 and serial.stdout.strip() == "vale-qa-target",
            "Fixture serial mismatch")
    require(int((sysblock / "size").read_text()) * 512 == 64 * 1024**3,
            "Expected fresh 64GiB fixture")
    require(not list(sysblock.glob(target.name + "*")), "Partitioned fixture refused")
    signatures = command(["wipefs", "--no-act", "--noheadings", str(target)])
    require(signatures.returncode == 0 and not signatures.stdout.strip(),
            "Disk signature check failed or found existing data")
    return target, info.st_rdev


def work_from(path):
    require(re.fullmatch(r"/run/elementary-installer-[A-Za-z0-9]+", str(path)),
            "Unexpected backend work directory")
    require(path.resolve() == path and path.is_dir(), "Work directory alias")
    return str(path)


def fd(path, state, kind):
    require(re.fullmatch(r"/proc/" + str(state["daemon_pid"]) + r"/fd/[0-9]+", path),
            "Unexpected source/target FD")
    info = os.stat(path)
    require(kind(info.st_mode), "Wrong FD type")
    return info


def mount_id(path):
    entries = [line.split()[0] for line in Path("/proc/self/mountinfo").read_text().splitlines()
               if line.split()[4] == str(path)]
    require(len(entries) == 1, "Expected exact private mount")
    return entries[0]


def tool(path, role, args):
    state = load(path)
    require(namespace() == state["namespace"] and
            os.getppid() == state["daemon_pid"], "Wrong tool caller/namespace")
    if role == "partprobe":
        event(path, "UNEXPECTED_AFTER_FAILURE")
        return 125  # Late continuation tripwire; provisioning precedes partprobe.
    if role == "wipefs":
        require(len(args) == 3 and args[:2] == ["-a", "--force"], "Unknown wipe call")
        require(fd(args[2], state, stat.S_ISBLK).st_rdev == state["target_rdev"],
                "Wrong wipe target")
        event(path, "WIPE_ATTEMPT")
        return 0  # Never open the target or invoke real wipefs.
    if role == "repart":
        if len(args) == 9 and args[:6] == ["--offline=yes", "--empty=create", "--size=258M",
                                         "--factory-reset=no", "--dry-run=no", "--split=yes"]:
            root = Path(args[8]).parent
            state["work"] = work_from(root.parent)
            require(root.name == "root-image" and args[8] == str(root / "disk.raw") and
                    not Path(args[8]).exists() and
                    args[6] == "--definitions=" + str(root / "repart"), "Unknown factory call")
            require(command(["findmnt", "-n", "-o", "FSTYPE", "--mountpoint", str(root)]).stdout.strip()
                    == "tmpfs" and os.statvfs(root).f_blocks * os.statvfs(root).f_frsize
                    == 768 * 1024**2, "Factory storage is not bounded private tmpfs")
            require(args[7].startswith("--copy-source="), "Missing factory source")
            fd(args[7].split("=", 1)[1], state, stat.S_ISDIR)
            save(path, state)
            result = subprocess.run([state["repart"], *args], timeout=180)
            event(path, "FACTORY_OK" if result.returncode == 0 else "FACTORY_FAILED", result.returncode)
            return result.returncode
        require(len(args) == 8 and args[0].startswith("--copy-from=") and
                args[1] == "--definitions=" + state["work"] + "/repart" and
                args[2] in ("--dry-run=yes", "--dry-run=no") and
                args[3:5] == ["--empty=force", "--offline=yes"] and
                args[5].startswith("--copy-source=") and args[6] == "--json=short",
                "Unknown destination repart call")
        fd(args[0].split("=", 1)[1], state, stat.S_ISREG)
        fd(args[5].split("=", 1)[1], state, stat.S_ISDIR)
        require(fd(args[7], state, stat.S_ISBLK).st_rdev == state["target_rdev"], "Wrong target")
        if args[2] == "--dry-run=yes" and state["case"] == "real-repart":
            result = subprocess.run([state["repart"], *args], timeout=180)
            event(path, "PLAN_OK" if result.returncode == 0 else "PLAN_FAILED", result.returncode)
            return result.returncode
        require(args[2] == "--dry-run=yes" or state["case"] == "real-repart",
                "Unexpected actual repart")
        result = subprocess.run([state["repart"], INVALID], timeout=30)
        require(result.returncode != 0, "Real repart unexpectedly accepted invalid option")
        event(path, "REPART_FAILED" if args[2] == "--dry-run=no" else "DRY_RUN_FAILED",
              result.returncode)
        return result.returncode
    require(role == "umount" and len(args) == 1, "Unknown tool invocation")
    destination = Path(args[0])
    work = work_from(destination.parent)
    require(destination.name in ("root-image", "source", "live") and
            state.get("work", work) == work, "Unknown unmount")
    state["work"] = work
    save(path, state)
    if state["case"] == "busy-unmount" and destination.name == "source":
        before = mount_id(destination)
        helper = subprocess.Popen([sys.executable, __file__, "_hold", str(path), str(destination)],
                                  start_new_session=True)
        state["busy_pid"] = helper.pid
        state["busy_start"] = Path(f"/proc/{helper.pid}/stat").read_text().split()[21]
        save(path, state)
        deadline = time.monotonic() + 10
        while not (path.parent / "busy.ready").exists():
            require(helper.poll() is None and time.monotonic() < deadline, "Busy helper not ready")
            time.sleep(0.05)
        result = subprocess.run([state["umount"], str(destination)], timeout=30)
        require(result.returncode != 0 and mount_id(destination) == before,
                "Expected real busy unmount with retained mount")
        event(path, "SOURCE_UMOUNT_FAILED", result.returncode)
        return result.returncode
    event(path, "UMOUNT_" + destination.name)
    return subprocess.run([state["umount"], *args], timeout=30).returncode


def hold(path, destination):
    state = load(path)
    require(namespace() == state["namespace"] and str(destination) == state["work"] + "/source",
            "Wrong busy mount")
    os.chdir(destination)
    (path.parent / "busy.ready").touch()
    deadline = time.monotonic() + 900
    while not (path.parent / "busy.release").exists() and time.monotonic() < deadline:
        time.sleep(0.05)


def stop(process):
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)


def run(args):
    target, rdev = fixture_target()
    require(not args.output.exists(), "Output must be a new private directory")
    require(args.daemon.is_file() and os.access(args.daemon, os.X_OK) and
            digest(args.daemon) == args.daemon_sha256, "Daemon identity mismatch")
    require(bus("NameHasOwner", BUS).stdout.strip() == "(false,)", "Stop existing guest daemon first")
    args.output.mkdir(mode=0o700)
    statefile = args.output / "state.json"
    real_repart = command(["sh", "-c", "command -v systemd-repart"]).stdout.strip()
    real_umount = command(["sh", "-c", "command -v umount"]).stdout.strip()
    require(Path(real_repart).is_absolute() and Path(real_umount).is_absolute(), "Missing real tools")
    state = dict(case=args.case, namespace=namespace(), target_rdev=rdev, target=str(target),
                 repart=real_repart, umount=real_umount, daemon_pid=0)
    save(statefile, state)
    tools = args.output / "bin"
    tools.mkdir()
    for name, role in (("systemd-repart", "repart"), ("umount", "umount"),
                       ("partprobe", "partprobe"), ("inert-wipefs", "wipefs")):
        wrapper = tools / name
        wrapper.write_text("#!/bin/sh\nexec /usr/bin/python3 " + " ".join(map(shlex.quote,
                           [str(Path(__file__).resolve()), "_tool", str(statefile), role])) + ' "$@"\n')
        wrapper.chmod(0o700)
    trace = monitor = None
    bound = False
    signals = []
    ready = threading.Event()
    lost_owner = threading.Event()
    report = dict(result="INCONCLUSIVE", case=args.case, daemon_sha256=digest(args.daemon),
                  namespace=namespace(), target=str(target), real_repart_sha256=digest(real_repart),
                  real_umount_sha256=digest(real_umount),
                  daemon_file_label=command(["ls", "-Zd", str(args.daemon)]).stdout.strip(),
                  daemon_mount=command(["findmnt", "-n", "-o", "TARGET,OPTIONS",
                                        "--target", str(args.daemon)]).stdout.strip(),
                  caller_label=Path("/proc/self/attr/current").read_text().strip())
    try:
        require(command(["mount", "--bind", str(tools / "inert-wipefs"), "/usr/sbin/wipefs"]).returncode == 0,
                "Cannot bind inert wipe tool")
        bound = True
        installed, recorder = os.stat("/usr/sbin/wipefs"), os.stat(tools / "inert-wipefs")
        require((installed.st_dev, installed.st_ino) == (recorder.st_dev, recorder.st_ino),
                "Absolute wipefs does not resolve to recorder")
        env = dict(os.environ, PATH=str(tools) + ":" + os.defpath, LC_ALL="C")
        trace = subprocess.Popen(["strace", "-ff", "-ttt", "-yy", "-e",
                                  "trace=openat,openat2,close,getdents64,unlink,unlinkat,rmdir,umount2",
                                  "-o", str(args.output / "cleanup.trace"), str(args.daemon)],
                                 env=env, stdout=(args.output / "daemon.stdout").open("w"),
                                 stderr=(args.output / "daemon.stderr").open("w"), start_new_session=True)
        deadline = time.monotonic() + 15
        while bus("NameHasOwner", BUS).stdout.strip() != "(true,)":
            require(trace.poll() is None and time.monotonic() < deadline,
                    "Daemon did not acquire bus; inspect confinement/loader failure")
            time.sleep(0.05)
        owner = bus("GetConnectionUnixProcessID", BUS)
        match = re.fullmatch(r"\(uint32 (\d+),\)\s*", owner.stdout)
        require(match is not None, "Cannot establish actual daemon PID")
        state["daemon_pid"] = int(match[1])
        require(digest(f"/proc/{match[1]}/exe") == args.daemon_sha256 and
                os.readlink(f"/proc/{match[1]}/ns/mnt") == namespace(), "Wrong bus owner")
        save(statefile, state)
        report["daemon_label"] = Path(f"/proc/{match[1]}/attr/current").read_text().strip()
        xml = command(["gdbus", "introspect", "--system", "--xml", "--dest", BUS,
                       "--object-path", OBJECT])
        interface = ET.fromstring(xml.stdout).find(f"interface[@name='{BUS}']")
        require(interface is not None, "Missing real interface")
        method = interface.find("method[@name='InstallWithDefaultDiskLayout']")
        require(method is not None and [v.get("type") for v in method.findall("arg")
                if v.get("direction") == "in"] == ["(ssssbb)", "s", "b", "s"], "Wrong method signature")
        monitor = subprocess.Popen(["stdbuf", "-oL", "gdbus", "monitor", "--system", "--dest", BUS,
                                    "--object-path", OBJECT], stdout=subprocess.PIPE,
                                   stderr=(args.output / "monitor.stderr").open("w"), text=True,
                                   env=env, start_new_session=True)
        def collect():
            with (args.output / "signals.log").open("w") as out:
                for line in monitor.stdout:
                    signals.append(line)
                    out.write(line)
                    out.flush()
                    if "is owned by" in line:
                        ready.set()
                    if "does not have an owner" in line or "has no owner" in line:
                        lost_owner.set()
        reader = threading.Thread(target=collect, daemon=True)
        reader.start()
        require(ready.wait(10), "Signal subscription not ready")
        config = "('vale-regression', 'us', '', " + repr(args.locale) + ", false, false)"
        reply = subprocess.run(["gdbus", "call", "--system", "--interactive", "--timeout", "600",
                                "--dest", BUS, "--object-path", OBJECT, "--method",
                                BUS + ".InstallWithDefaultDiskLayout", config, str(target), "false", ""],
                               text=True, capture_output=True, timeout=620, env=env)
        (args.output / "call.stdout").write_text(reply.stdout)
        (args.output / "call.stderr").write_text(reply.stderr)
        # Name loss follows emitted signals on this monitor connection. Drain it
        # before asserting absence of completion; do not race a queued signal.
        stop(trace)
        require(lost_owner.wait(10), "Monitor did not observe daemon name loss")
        stop(monitor)
        reader.join(timeout=5)
        entries = [json.loads(line) for line in (args.output / "events.jsonl").read_text().splitlines()]
        names = [entry["event"] for entry in entries]
        report["events"] = names
        injected = "REPART_FAILED" if args.case == "real-repart" else "DRY_RUN_FAILED"
        require("FACTORY_OK" in names and injected in names, "Intended boundary not reached")
        report["result"] = "FAIL"
        require(reply.returncode != 0 and INVALID in reply.stderr, "Actual failure did not reach async reply")
        require("Completed!" not in "".join(signals) and
                not re.search(r"\.OnStatus\s+\(\(5,\s*100\)", "".join(signals)), "False completion")
        expected = ["FACTORY_OK", "PLAN_OK", "WIPE_ATTEMPT", "REPART_FAILED"] if args.case == "real-repart" else ["FACTORY_OK", "DRY_RUN_FAILED"]
        require([n for n in names if n in expected] == expected and
                names.count("WIPE_ATTEMPT") == (1 if args.case == "real-repart" else 0) and
                "UNEXPECTED_AFTER_FAILURE" not in names, "Incorrect failure/wipe ordering")
        if args.case == "busy-unmount":
            failure = next(v for v in entries if v["event"] == "SOURCE_UMOUNT_FAILED")
            state = load(statefile)
            mount_id(Path(state["work"]) / "source")
            suffix = []
            for file in args.output.glob("cleanup.trace.*"):
                for line in file.read_text().splitlines():
                    if re.match(r"\d+\.\d+ ", line) and float(line.split()[0]) >= failure["time"]:
                        suffix.append(line)
            require(any("umount2(" in line and "EBUSY" in line and
                        state["work"] + "/source" in line
                        for file in args.output.glob("cleanup.trace.*")
                        for line in file.read_text().splitlines()), "No source umount EBUSY trace")
            require(not any(re.search(r"(getdents64|unlink|unlinkat|rmdir)\(", line) and
                            state["work"] in line for line in suffix), "Traversal after failed unmount")
            require("UMOUNT_live" not in names[names.index("SOURCE_UMOUNT_FAILED") + 1:],
                    "Live teardown continued after raw-source failure")
            require("Cleanup failed" in "".join(signals), "Cleanup error not observed")
        report["result"] = "PASS"
    except Exception as error:
        report["reason"] = str(error)
    finally:
        stop(monitor)
        stop(trace)
        state = load(statefile)
        (args.output / "busy.release").touch()
        helper_error = None
        if "busy_pid" in state:
            pid = state["busy_pid"]
            def helper_alive():
                try:
                    fields = Path(f"/proc/{pid}/stat").read_text().split()
                except FileNotFoundError:
                    return False
                require(fields[21] == state["busy_start"], "Busy PID changed; do not signal it")
                return fields[2] != "Z"
            try:
                deadline = time.monotonic() + 5
                while helper_alive() and time.monotonic() < deadline:
                    time.sleep(0.05)
                if helper_alive():
                    os.kill(pid, signal.SIGTERM)
                    deadline = time.monotonic() + 5
                    while helper_alive() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    require(not helper_alive(), "Busy helper did not exit")
            except Exception as error:
                helper_error = str(error)
        teardown = []
        if "work" in state:
            for name in ("source", "live", "root-image"):
                path = Path(state["work"]) / name
                if any(line.split()[4] == str(path) for line in Path("/proc/self/mountinfo").read_text().splitlines()):
                    teardown.append(dict(path=str(path), exit=command([real_umount, str(path)]).returncode))
        if bound:
            teardown.append(dict(path="/usr/sbin/wipefs", exit=command([real_umount, "/usr/sbin/wipefs"]).returncode))
        report["teardown"] = teardown
        if helper_error or any(item["exit"] for item in teardown):
            report["result"] = "FAIL"
            report["reason"] = helper_error or "Owned mount teardown failed; retain state, do not recursively delete"
        save(args.output / "result.json", report)
    print(json.dumps(report))
    return 0 if report["result"] == "PASS" else (77 if report["result"] == "INCONCLUSIVE" else 1)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "_tool":
            sys.exit(tool(Path(sys.argv[2]), sys.argv[3], sys.argv[4:]))
        if len(sys.argv) > 1 and sys.argv[1] == "_hold":
            hold(Path(sys.argv[2]), Path(sys.argv[3]))
            sys.exit(0)
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("case", choices=CASES)
        parser.add_argument("--daemon", type=Path, required=True)
        parser.add_argument("--daemon-sha256", required=True)
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--locale", default="en_US.utf8")
        arguments = parser.parse_args()
        arguments.daemon = arguments.daemon.resolve(strict=True)
        arguments.output = arguments.output.absolute()
        sys.exit(run(arguments))
    except Exception as error:
        print("INCONCLUSIVE: " + str(error), file=sys.stderr)
        sys.exit(77)
