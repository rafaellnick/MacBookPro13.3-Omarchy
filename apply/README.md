# apply/ — reproducible provisioning

`mbp133-apply.sh` applies every adaptation this MacBookPro13,3 needs on Omarchy.

```bash
./mbp133-apply.sh --list        # what it does, no root needed
sudo ./mbp133-apply.sh --check  # dry run — changes nothing
sudo ./mbp133-apply.sh          # apply everything except the bootloader
```

## Design

**Assets are exact copies, not retyped.** `assets/` holds byte-for-byte copies
of the 27 files taken from the working machine. The script installs those. This
avoids transcription drift between what is documented, what is installed, and
what actually works.

**Idempotent.** Every item is compared before writing. A second run on a correct
machine reports `0 applied, 44 already correct, 0 warnings, 0 failed`.

**Phase-scoped.** `--phase touchbar` (or `wifi`, `sleep`, `power`, `shell`,
`maintenance`, `packages`, `audio-dkms`) applies one area. Phase names match the
numbered documentation modules in `../`.

**Refuses the wrong hardware.** It exits if `product_name` is not
`MacBookPro13,3`. Fan ranges, GPU mux behaviour, iBridge HID handling and codec
IDs are all model-specific.

## Things it deliberately does *not* do

| | Why |
|---|---|
| Edit the bootloader by default | The one step that can leave the machine unbootable. Opt in with `--allow-bootloader --phase bootloader`; it backs up `/etc/default/limine` first |
| Overwrite the Wi-Fi NVRAM file | That file carries **this machine's MAC**. Only `ccode`/`regrev` are patched in place, with a backup |
| Overwrite `shell.json` | It is your bar layout. The plugin and fan widget are inserted surgically; everything else is untouched |
| Reproduce the DisplayPort link fixes | Deliberately reverted — see `../04-display-and-gpu.md` |
| `pacman -Sy` | A partial upgrade is how you get headers for a kernel you are not running, and DKMS silently building against the wrong tree |

## What needs a reboot

- Wi-Fi regulatory change (or stop NetworkManager and reload `brcmfmac`)
- Any kernel command-line change
- `modprobe.d` changes

## After running

```bash
sudo ./mbp133-apply.sh --check   # should report 0 applied
mbp133-t1-check                  # 0 failures (1 known-false warning, ../01 §1.2)
```

The script's own `Verify` section runs 8 runtime assertions at the end of every
invocation — DKMS built for the running kernel, codec bound, modules loaded,
sleep hooks present, s2idle selected, GPU clamped.
