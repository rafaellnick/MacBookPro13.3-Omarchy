# 07 — Keyboard, trackpad and fingerprint input

The internal keyboard and trackpad use `applespi` over the same SPI controller.
They currently work while the machine is awake, but intermittent sticky input
has been observed. That issue remains open and should be investigated without
mixing it into the completed power work.

## Sticky input symptom

A key or pointer action can occasionally behave as though it remained active.
Useful evidence for the next investigation is the kernel log around the event,
the libinput event stream and whether both keyboard and trackpad fail together:

```bash
sudo libinput debug-events
journalctl -kf | grep -Ei 'applespi|spi|input|hid'
grep -A8 -E 'Apple SPI (Keyboard|Touchpad)' /proc/bus/input/devices
```

Avoid reloading `applespi` as an automatic sleep hook. That old workaround was
created for a resume desynchronization, and automatic suspend is now blocked.
Reloading the shared driver also temporarily removes both internal input
devices. If manual recovery is ever necessary, have an external input device or
an existing remote shell available first.

## Function keys

`/etc/modprobe.d/hid_apple.conf` controls conventional Apple keyboard behavior.
Touch Bar key layout is rendered by T1Bridge and no longer uses the
`apple_ib_tb` module parameter described in older revisions of this repository.

## Touch ID

Touch ID is provided by `libfprint-t1bridge` and `fprintd-t1bridge`. The
Touch Bar idle plugin publishes a lock-auth mode so the fingerprint surface
stays available when the lock screen blanks the main panel.

```bash
fprintd-list "$USER"
fprintd-verify "$USER"
systemctl status fprintd.service
```

Enrollment and matching remain subject to the T1Bridge package's supported
PAM integrations; the sensor should not be probed by manually changing the T1
USB configuration.

## Verification

```bash
grep -E 'Apple SPI (Keyboard|Touchpad)' /proc/bus/input/devices
basename "$(readlink -f /sys/bus/spi/devices/spi-APP000D:00/driver)"
journalctl -b -k | grep -i applespi
```
