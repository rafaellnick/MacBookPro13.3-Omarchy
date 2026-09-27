# 11 — Maintenance and verification

## After package or kernel updates

Check the dependencies tied to the running kernel and to T1Bridge's service
contracts:

```bash
uname -r
dkms status
pacman -Q t1bridge t1bridge-dkms t1bridge-omarchy \
  libfprint-t1bridge fprintd-t1bridge tlp
systemctl --failed
systemctl status t1-touchbar-hw.service
systemctl --user status t1-touchbar.service t1bridge-auto-brightness.service
aplay -l | grep -E 'CS8409|CS42L83'
```

The low-wakeup T1Bridge patch is pinned to source commit
`81cbdf81026a16e02f0bea74735c6b029a8ffae2`. A T1Bridge upgrade may change the
source and service protocol. Rebase the patch and rerun upstream tests before
rebuilding; do not assume a clean patch application proves runtime compatibility.

## After reboot

```bash
sudo dgpu-power status
test ! -e /sys/bus/pci/devices/0000:01:00.1
systemctl status radeon-audio-remove.service \
  macbook-thunderbolt-powersave.service tlp.service
systemctl --user status dgpu-off.service
omarchy-shell ipc call touchbar-idle status
omarchy-shell ipc call idle-suspend status
```

Expected results:

- the panel driver is `i915`;
- the `DIS` vga_switcheroo line is `Off`;
- Radeon HDMI audio is absent;
- Touch Bar idle timeout is 10 seconds;
- idle suspend reports `dryRun: true`;
- lid switches resolve to `ignore` in logind configuration.

The post-boot `verify-hardware.hook` checks the most important subset and is
silent when healthy. It reports audio DKMS/codec, T1Bridge services, Wi-Fi,
Radeon power and Radeon HDMI-audio regressions.

## Reprovisioning

```bash
cd apply
./mbp133-apply.sh --list
sudo ./mbp133-apply.sh --check
sudo ./mbp133-apply.sh
sudo ./build-t1bridge-low-wakeup.sh   # optional pinned custom build
```

The installer removes the old resume hooks and fake NVMe service. It does not
select the EFI GPU mode and does not enable automatic suspend.

## Power regression checklist

For a sustained idle plateau above 12 W:

1. Confirm `dgpu-power status` says the Radeon is off.
2. Confirm PCI function `0000:01:00.1` is absent.
3. Check `macbook-thunderbolt-power status` for unused bound controllers.
4. Check CPU activity with `top` or a timed PowerTOP sample.
5. Confirm panel brightness and AC state before comparing measurements.

Do not use a single high sample as evidence. Keep the same brightness and wait
at least a minute after login or application activity.

## Scheduled maintenance

The provisioning phase enables `snapper-timeline.timer`,
`btrfs-scrub@-.timer`, `paccache.timer` and `fstrim.timer` when available.
Snapshots share the internal disk and are not backups; keep an external copy of
important data.
