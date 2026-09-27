# Reproducible provisioning

`mbp133-apply.sh` installs the stable awake configuration documented in the
repository. It refuses hardware other than `MacBookPro13,3`, compares files
before replacing them and supports phase-scoped dry runs.

```bash
./mbp133-apply.sh --list
sudo ./mbp133-apply.sh --check
sudo ./mbp133-apply.sh
sudo ./mbp133-apply.sh --phase touchbar
```

Phases are `packages`, `audio-dkms`, `touchbar`, `wifi`, `sleep`, `power`,
`shell` and `maintenance`. `bootloader` is opt-in with
`--allow-bootloader --phase bootloader`.

## Safety boundaries

- The installer never changes the EFI GPU preference. Use `sudo gpu-mode igpu`
  after reading [the GPU documentation](../04-display-and-gpu.md).
- Automatic lid and idle suspend remain disabled because resume is unreliable.
- Obsolete `applespi`, `brcmfmac` and Touch Bar resume hooks are removed.
- The misnamed `omarchy-nvme-suspend-fix.service` is disabled and removed.
- The dGPU user unit has no power-on stop action, which avoids shutdown hangs.
- Passwordless sudo is limited to the guarded `dgpu-power off` command.
- The Wi-Fi NVRAM file is patched in place so its machine-specific data is not
  overwritten.
- The global wireless-regdb country is activated as BR in place; other active
  country settings trigger a warning for manual review.
- Shell integration uses user overrides and edits `shell.json` as JSON.
- Lock-state integration patches an existing user clone of `omarchy.lock`; it
  warns and leaves the clone untouched if the Omarchy 4.0.4 patch no longer
  matches.

The script checks the official-repository dependencies with `pacman`. T1Bridge
packages come from their Arch package repository and are reported if missing;
the root installer does not invoke an AUR helper.

## Optional T1Bridge low-wakeup build

The compiled custom binaries are not stored in Git. Build them from the pinned
upstream commit with:

```bash
sudo ./build-t1bridge-low-wakeup.sh
```

The helper clones T1Bridge, checks out
`81cbdf81026a16e02f0bea74735c6b029a8ffae2`, applies the tracked patch, runs the
renderer tests, builds both services and installs systemd drop-ins. It requires
network access and the Rust toolchain, which is why the normal apply script
does not run it implicitly.

## What requires a reboot

- changing EFI GPU mode;
- kernel command-line changes;
- kernel/DKMS updates;
- Wi-Fi regulatory changes unless the driver is deliberately reloaded.

Run `sudo ./mbp133-apply.sh --check` after provisioning. Any `WOULD` line is a
configuration difference; `not` lines in the final verification block describe
runtime state and may require a login or reboot before they become true.

`sudo ./verify-limine-hashes.py` checks every active and snapshot EFI digest in
the generated Limine config. It reads files only and exits nonzero if a target
is missing or its BLAKE2b digest is stale.
