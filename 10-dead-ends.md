# 10 — Dead ends and unsafe experiments

These results are recorded to prevent a later reinstall or kernel update from
repeating tests that already caused hangs, crashes or misleading conclusions.

## Suspend and Radeon manipulation

| Attempt | Result |
|---|---|
| s2idle with Radeon already off | Resume errors and roughly 20 W draw |
| Power Radeon on in a pre-suspend hook | Hard crash; hook was disarmed |
| Remove the whole Radeon PCI GPU while awake | Rails remained on and draw rose to 20–22 W |
| Unbind/remove amdgpu after gmux power-off | Unsafe: driver teardown accesses hardware whose rails are gone |
| Raw `apple-gmux` debugfs writes | Bypass driver state; no safe synchronization with amdgpu |
| Set Radeon `d3cold_allowed` in an “NVMe fix” service | Misnamed and ineffective; the target was GPU PCI state, not NVMe |
| Reload input, Wi-Fi and Touch Bar drivers after every sleep | Treats symptoms and adds ordering races; cannot repair GPU/T1 PM failures |

The working awake path is narrow: boot with Intel selected, remove only Radeon
HDMI audio while the GPU is accessible, wait for the graphical session to
release the Radeon DRM nodes, then use the guarded vga_switcheroo helper.

## dGPU shutdown handling

Restoring Radeon power from `ExecStop` caused reboot and shutdown to hang at the
Omarchy splash or “the system will restart now.” Leave the card off. Firmware
restores it at the next boot.

## Power measurements

- A 5.1 W Intel package reading is not 5.1 W at the battery.
- Instantaneous BAT0 values jump with scheduler and display activity.
- Removing a visible process to improve a screenshot does not establish an
  idle configuration.
- Replacing the worn battery improves capacity and may stabilize telemetry; it
  does not eliminate the panel, T1, SSD or regulator load.

## GPU mode trade-off

The internal panel on Intel with Radeon powered off is the best working battery
configuration. External display connectors are wired to Radeon, so they do not
work in this mode. Dynamic switching comparable to macOS is not available on
this gmux/Polaris Linux stack.

## T1Bridge and suspend

T1Bridge makes Touch Bar and Touch ID functional while awake. Its current
upstream support does not include system suspend/resume. Restarting services
after wake does not solve a transport or kernel PM failure during suspend.

## Hibernate

Firmware refuses S4, so hibernate and suspend-then-hibernate are not recovery
paths for this machine.
