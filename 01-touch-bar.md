# 01 — T1Bridge, Touch Bar and Touch ID

The legacy `appleibridge`/`apple_ib_tb` configuration has been replaced by
[T1Bridge](https://github.com/standardagents/t1bridge). The working package set
is:

```text
t1bridge 0.1.12-1
t1bridge-dkms 0.1.12-1
t1bridge-omarchy 0.2.2-1
libfprint-t1bridge 1.94.100-20
fprintd-t1bridge 1.94.5-17
```

T1Bridge brings up the T1 USB transport, DRM device, NCM interface, xART/keybag
services and broker. `t1-touchbar-hw.service` owns the privileged hardware side;
the user `t1-touchbar.service` renders the controls. The Omarchy desktop
provider supplies volume, media and display state; its cached wrapper is
installed in `/usr/local/lib/t1bridge`. Touch ID is exposed through the patched
libfprint/fprintd packages.

## Touch Bar idle blanking

`local.touchbar-idle` uses Wayland's idle-notify protocol and publishes a small
state file under `$XDG_RUNTIME_DIR`. The cached desktop-provider wrapper adds
T1Bridge's display-power capability to its normal status reply:

- after 10 seconds without input, mode `0` blanks the OLED;
- normal activity publishes mode `1` and restores it;
- while the lock screen is active, mode `2` keeps it available for fingerprint
  authentication, even if the main panel has blanked.

This avoids the previous usability problem where a keyboard press was required
before the fingerprint sensor would work. It also prevents a renderer restart
from falling back to built-in menus: the custom provider and renderer are
systemd drop-ins, so they are reapplied on every start.

The active cloned `omarchy.lock` service publishes its lock state. The tracked
patch is based on Omarchy 4.0.4 and the apply script installs it only when it
matches cleanly; a future Omarchy lock-service change must be reviewed rather
than patched blindly.

## Lower wakeup rate

The source patch in
[`apply/assets/source-patches/t1bridge-low-wakeup.patch`](apply/assets/source-patches/t1bridge-low-wakeup.patch)
is pinned to upstream commit `81cbdf81026a16e02f0bea74735c6b029a8ffae2`,
the source used by package 0.1.12. It changes three polling intervals:

| Loop | Upstream | Patched |
|---|---:|---:|
| hardware session revalidation | 50 ms | 250 ms |
| active renderer receive poll | 5 ms | 20 ms |
| display-off renderer poll | 5 ms | 250 ms |
| desktop-provider child wait | 5 ms | 20 ms |

Measured renderer wakeups fell from roughly 164/s to 36/s while active and to
about 4/s with the OLED off. All 95 renderer tests passed before installation.
Build and install the patch with:

```bash
cd apply
sudo ./build-t1bridge-low-wakeup.sh
```

The helper checks out the exact commit, applies the patch, runs the renderer
tests, builds both binaries, installs them under `/usr/local/lib/t1bridge/`, and
adds service drop-ins. Rebase and retest the patch before using it with a newer
T1Bridge release.

## Brightness

The automatic-brightness wrapper keeps the package's ambient-light policy but
polls every 10 seconds and caps the panel at 10% while discharging. It does not
change the AC curve. The current configuration keeps keyboard backlight at zero
when it is not needed.

## Verification

```bash
systemctl status t1-touchbar-hw.service
systemctl --user status t1-touchbar.service t1bridge-auto-brightness.service
fprintd-list "$USER"
omarchy-shell ipc call touchbar-idle status
journalctl -b -u t1-touchbar-hw.service
```

T1Bridge upstream currently does not promise system suspend/resume support.
That limitation is handled as a system policy in [05-sleep-and-resume.md](05-sleep-and-resume.md),
not with service restart hooks.
