# 05 — Sleep and resume

Automatic suspend is disabled because the current kernel, gmux and T1Bridge
combination is not reliable on this MacBookPro13,3. The machine is stable while
awake and shuts down cleanly; claiming suspend is fixed would trade those known
properties for intermittent crashes and high-power resumes.

## What was observed

The platform exposes `s2idle`; firmware refuses S4 hibernation. Several s2idle
tests completed the apparent sleep transition but failed on resume:

- the powered-off Radeon changed from inaccessible/D3hot state to a broken D0
  state and emitted amdgpu errors;
- whole-machine draw rose to about 20 W after wake;
- Thunderbolt NHI callbacks failed after D3cold on some runs;
- enabling the Radeon immediately before suspend caused a hard crash;
- T1Bridge upstream documents system suspend/resume as unsupported.

The resulting policy is explicit:

```ini
# /etc/systemd/logind.conf.d/99-macbook-suspend-safety.conf
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

The Omarchy `local.idle-suspend` plugin remains installed for diagnostics but
its shell entry has `"dryRun": true`. It logs what it would have done and never
calls `systemctl suspend`.

## Thunderbolt power policy

`macbook-thunderbolt-powersave.service` monitors both Alpine Ridge controllers.
On battery, an NHI is unbound only if its paired xHCI controller is healthy and
no external device is attached. It is rebound on AC or when an attachment is
detected. This saves awake power and removes unused NHI drivers from the
suspend callback graph, but it does not make suspend supported.

The accompanying system-sleep hook disables asynchronous device suspend for a
manually requested cycle and restores it afterward. It is kept as preparation
for future kernel work; automatic entry is still blocked.

## Why old hooks were removed

The previous `applespi-reload`, `brcmfmac-reload` and `touchbar-resume` hooks
treated resume symptoms after the fact. They increased ordering complexity and
cannot repair a Radeon or T1 failure inside the kernel suspend path. The fake
`omarchy-nvme-suspend-fix.service` was also removed: despite its name, it wrote
the Radeon PCI function's `d3cold_allowed` attribute and did nothing to NVMe.

## What a real fix requires

The next useful experiment belongs in the kernel PM path: a model-specific
amdgpu/gmux quirk or direct-complete integration that keeps callbacks away from
a card whose rails have already been cut. It must also account for T1Bridge's
unsupported suspend state. No stock userspace setting can selectively remove
amdgpu suspend callbacks while retaining the safe awake configuration.

Until that work exists and survives repeated cold-boot, sleep, wake and power
measurements, use screen lock plus manual shutdown. Do not re-enable lid or
idle suspend merely because one cycle happens to work.

## Verification

```bash
systemd-analyze cat-config systemd/logind.conf | grep -E 'HandleLidSwitch'
omarchy-shell ipc call idle-suspend status   # dryRun must be true
systemctl status macbook-thunderbolt-powersave.service
sudo macbook-thunderbolt-power status
```
