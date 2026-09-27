# 04 — Display and GPU power

The internal panel is muxed to the Intel HD 530. This is the low-power mode and
means the Radeon-wired external display outputs are unavailable.

## Selecting the iGPU

`gpu-mode` writes Apple's `gpu-power-prefs` EFI variable. The selection takes
effect only after reboot and persists until changed or NVRAM is reset.

```bash
sudo gpu-mode status
sudo gpu-mode igpu    # select Intel for the next boot
sudo gpu-mode dgpu    # restore Radeon/external display for the next boot
```

If a selection produces a black screen, reset NVRAM with Command-Option-P-R.
The installer deliberately does not write this variable.

At session startup, `~/.config/uwsm/env-hyprland` finds the DRM card whose eDP
connector has real modes and pins `AQ_DRM_DEVICES` to its `/dev/dri/cardN`
node. Card numbers are not stable. A PCI by-path cannot be passed directly
because Aquamarine treats colons as separators.

## Removing unused Radeon functions

The Radeon HDMI-audio function at `0000:01:00.1` is removed before graphical
login. `radeon-audio-remove` checks the exact model, PCI IDs, drivers, Intel
`boot_vga` state and Radeon D0 state first. A persistent marker prevents an
incomplete attempt from being repeated automatically.

After the graphical session starts, the user `dgpu-off.service` waits two
seconds and calls the guarded `dgpu-power off`. The helper verifies:

- the panel is on `i915`;
- the Radeon is bound to `amdgpu`;
- no process holds its card or render node;
- a previous attempt did not trip the circuit breaker.

Only then does it ask `vga_switcheroo` to cut the Radeon rails. The expected
state is:

```text
IGD:+:Pwr
DIS: :Off:0000:01:00.0
```

The sudoers rule permits only `/usr/local/sbin/dgpu-power off` for members of
`wheel`. It does not grant general passwordless root access.

## Shutdown behavior

The Radeon stays off during logout, shutdown and reboot. An earlier unit used
`ExecStop=/usr/local/sbin/dgpu-power on`; amdgpu tried to resume firmware after
gmux had already removed access to the card and systemd hung at “the system will
restart now.” Removing that stop action fixed shutdown and reboot. EFI
initializes the card on the next boot.

## Verification

```bash
sudo dgpu-power status
cat /sys/kernel/debug/vgaswitcheroo/switch
test ! -e /sys/bus/pci/devices/0000:01:00.1
systemctl --user status dgpu-off.service
```

Never write `OFF` directly to the switch file. The first unguarded attempt left
amdgpu in an uninterruptible wait and required a hard power cycle.
