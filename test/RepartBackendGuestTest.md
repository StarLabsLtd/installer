# Actual repart-backend failure regressions

Run manually, **only in a fresh disposable QEMU Normal recovery guest**. This is
not a host/Meson unit test and must not be added to ordinary package `%check`.
Use the existing signed-media launcher with one vCPU, a new blank64GiB target
(serial `vale-qa-target`), isolated software TPM and private firmware variables.
Do not reuse an installed/preserved guest disk or its TPM. No host passthrough.

The runner invokes the actual asynchronous `InstallWithDefaultDiskLayout` on
system D-Bus with real Polkit. There is no production test flag, executor hook,
private bus or copied backend implementation. It forwards bounded factory ROOT
preparation and the admitted dry-run to real repart. Absolute `/usr/sbin/wipefs`
is replaced **inside its private mount namespace** by an inert recorder. Unknown
repart calls are rejected. A partprobe guard detects unexpected late continuation and stops later boot
publication; it is not a pre-provisioning guard. No actual destination repart
or wipe is allowed.

## Existing-artifact route

The authenticated1225 INTERNAL TEST IMAGE can supply media and dependencies.
Use the **existing155 RPM's exact daemon**, extracted as a regular executable
into a guest-private path; record RPM, daemon and ISO hashes. Do not replace
libraries, plugins, the installed daemon, policy or media. Matching ELF needed
libraries, undefined symbols and symbol versions support this route, but do not
replace actual guest loader/SELinux verification. Normal source admission checks
remain authoritative; the old media is an explicit substitution, not current155
installed-image acceptance. Historical154 is Normal-source-equivalent but a154
run must not be labelled actual155 execution.

Keep SELinux enforcing. Record the executable's label and mount options first;
if the private path is noexec or execution is denied, stop and retain the denial.
Do not use permissive mode, policy changes, loader tricks or authentication bypass.
The selected Normal kernel admission requires CONFIG_SUSPEND, PM_SLEEP_S2IDLE,
HIBERNATION, HIBERNATION_SNAPSHOT_DEV and ENCRYPTED_HIBERNATION all enabled. The
actual daemon still validates the trusted source kernel/UKI and SELinux contexts.

## Guest-only execution

Stop the existing guest daemon; prevent its ordinary service activation racing
the test with a **guest runtime-only** mask if necessary. Do not change bus or
Polkit policy. Verify an installed locale, e.g. `locale -a`. Keep credentials out
of command lines/logs; these cases deliberately use unencrypted Normal and an
empty password. The controller connects until the real async error reply.

For each case, use a new output path and a fresh private mount namespace:

```sh
# INSIDE DISPOSABLE RECOVERY GUEST ONLY; substitute verified absolute paths/hash.
unshare --mount --propagation private -- \
  python3 /run/backend-tests/RepartBackendGuestTest.py real-repart \
  --daemon /run/backend-tests/io.elementary.installer-daemon \
  --daemon-sha256 VERIFIED155DAEMONSHA256 --output /run/backend-real-repart
```

Run `real-repart` first as the admitted-plan control, then `dry-run` and
`busy-unmount` with separate output directories. No additional package build,
new image, signing or real installation is involved. Existing stock guest tools
required: Python3, gdbus/stdbuf, strace, mount/umount/unshare/findmnt, real
systemd-repart, lsblk, systemd-detect-virt and getenforce. No new test engine.

- `dry-run`: factory preparation succeeds; destination dry-run invokes real
  repart with an invalid option. Require its diagnostic in the async error,
  no wipe attempt and no completion.
- `real-repart`: real dry-run succeeds and backend reaches inert wipe; actual
  destination repart invokes the real invalid-option failure. Require that
  ordering, propagated error and no completion.
- `busy-unmount`: same dry-run failure, then a separate helper holds cwd inside
  the actual raw-source mount. Real umount must fail, leave the mount present,
  and produce EBUSY in syscall trace. Require no subsequent source/repart
  traversal or live-source unmount, and no completion. Earlier root-image
  cleanup is allowed.

Exit0/PASS requires the intended injection boundary, not merely any failed call.
Exit77 is INCONCLUSIVE (admission, confinement, fixture or prerequisite failure);
exit1 is FAIL after reaching the boundary. Retain result.json, static event
markers, async response, signals, daemon output and FD-resolved cleanup traces.
The runner does not claim whole-disk unchanged hashes or encrypted-key custody.
Use only the unmodified, identity-bound daemon: this fixture does not contain
arbitrary source mutants that fabricate valid repart JSON. In the selected
Normal path, provisioning precedes partprobe. The real invalid-option failure
has no valid result JSON; the test requires its original diagnostic in the
async error, rather than accepting an unrelated later parser/provisioning error.

Teardown stops only spawned process groups, releases the recorded busy helper,
and normally unmounts only recorded backend mounts and its wipefs binding. It
never recursively deletes a work tree, lazy/force-unmounts, or kills by process
name. If teardown fails, retain guest state and inspect; discard only the
separately owned disposable fixture after evidence capture. Restore the guest
runtime service mask if keeping the guest. Source-mutant before-controls are
not implemented or claimed; they require a separately reviewed build scope.
