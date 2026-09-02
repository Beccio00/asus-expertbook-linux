# keyboard-backlight-fix

> **Superseded.** On BIOS `B9406CAA.312` with mainline `asus-wmi`, keyboard
> brightness already reaches the EC and this module does nothing useful. It
> refuses to install unless forced. The v1.x diagnosis below turned out to be
> wrong; the correction is the point of this document.
>
> If you want the backlight to follow the ambient light sensor, that is a
> different module: [`keyboard-backlight-auto`](../keyboard-backlight-auto/).

## What v1.x claimed

That the ASUS BIOS ships a broken `SLKB` ACPI method which clamps
OS-initiated brightness writes to zero, so the KDE slider, `brightnessctl` and
direct `/sys` writes all silently no-op while the Fn hotkeys keep working. The
fix was to run `asusd`, which supposedly translated writes into the OEM-tested
`0x100..0x103` range.

## What is actually true

Measured on **2026-09-02**, BIOS `B9406CAA.312`, Linux `7.2.0`, with `asusctl`
**not installed**, `/etc/asusd` absent and `asusd` inactive:

| Path | Result |
|---|---|
| `echo 0/1/2/3 > /sys/class/leds/asus::kbd_backlight/brightness` | **Works.** The keyboard visibly steps through all four levels. |
| KDE PowerDevil slider | **Works**, for the same reason. |
| `cat /sys/class/leds/asus::kbd_backlight/brightness` | **Always `0`**, whatever was written. |
| `busctl … UPower.KbdBacklight GetBrightness` | **Always `0`** — it reads the same attribute. |
| `brightnessctl -d asus::kbd_backlight info` | **Always `0` (0%)** — likewise. |

The write path is fine. The **read** path is broken — the opposite way round
from what v1.x documented.

## Where the old analysis went wrong

The `SLKB` disassembly itself was accurate. The mistake was about which branch
Linux reaches:

```c
Method (SLKB, 1, NotSerialized) {
    If    ((Arg0 >= 0x0100) && (Arg0 <= 0x0106)) { Local0 = (Arg0 - 0x0100) }
    ElseIf((Arg0 >= 0x80)   && (Arg0 <= 0x83))   { Local0 = (Arg0 - 0x80) * 0x21 ... }
    ElseIf((Arg0 >= Zero)   && (Arg0 <= 0x03))   { Local0 = Zero }   // never reached
    STBC (Zero, Local0)
    Return (One)
}
```

Mainline `asus-wmi` never writes the bare `0..3` range that the third branch
clamps:

```c
static void kbd_led_update(struct asus_wmi *asus)
{
	int ctrl_param = 0;

	scoped_guard(spinlock_irqsave, &asus_ref.lock)
		ctrl_param = 0x80 | (asus->kbd_led_wk & 0x7F);
	asus_wmi_set_devstate(ASUS_WMI_DEVID_KBD_BACKLIGHT, ctrl_param, NULL);
}
```

`0x80 | level` lands in `0x80..0x83` — SLKB's **second** branch, the one v1.x
itself documented as working. The buggy branch is unreachable from this driver,
so `asusd`'s range translation had nothing to fix.

The real defect is on the way back:

```c
static int kbd_led_read(struct asus_wmi *asus, int *level, int *env)
{
	retval = asus_wmi_get_devstate_bits(asus, ASUS_WMI_DEVID_KBD_BACKLIGHT,
					    0xFFFF);
	if (retval == 0x8000)
		retval = 0;
	...
	if (level)
		*level = retval & 0x7F;
```

The firmware's query returns nothing usable, so `*level` is always 0 and every
consumer of the LED node reports a dark keyboard regardless of its real state.
`asusd` does not fix this — it is a firmware read path, not a range problem.

### One thing that *does* report the real level

The defect is in the *query* path only. The LED class's sibling attribute
**`brightness_hw_changed`** reports the true brightness whenever the **EC**
changes it — an Fn keypress. Verified on 2026-09-02 by watching the system bus
while the keys were pressed:

```
member=BrightnessChangedWithSource   int32 1   string "internal"
member=BrightnessChangedWithSource   int32 2   string "internal"
member=BrightnessChangedWithSource   int32 3   string "internal"
```

That is UPower relaying `brightness_hw_changed`, and it is what raises KDE's
on-screen display when you press the key. It is a *notification* of what the
hardware just did, not a queryable current state, so it does not repair
`cat brightness` — but it is enough for
[`keyboard-backlight-auto`](../keyboard-backlight-auto/) to stay in sync with a
level you set by hand.

Worth noting for the same reason: the Fn keys emit **no input event** on any of
the fifteen `/dev/input/event*` devices. `brightness_hw_changed` is the only
signal.

### The v1.x status check was a false negative by construction

It wrote a brightness level and read it back, treating a mismatch as proof the
backlight was broken:

```
sysfs write test:      FAILED — wrote 1, read back 0 (SLKB clamp; asusd not translating)
```

Since the read is *always* 0, that check reported `FAILED` on a perfectly
working backlight. It has been removed. There is no way to verify the write
path from software; the only honest test is to write a level and look at the
keyboard.

## Known side effect of the broken read

`systemd-backlight@leds:asus::kbd_backlight` saves the read-back value at
shutdown — always `0` — and restores it at boot, so the keyboard comes up dark
every time regardless of the level you left it at.
[`keyboard-backlight-auto`](../keyboard-backlight-auto/) is ordered `After=`
that unit and overrides it within a second.

## What remains unknown

Whether OS-initiated control was genuinely broken on BIOS `B9406CAA.304`, the
firmware this module was written against. The reference machine has since moved
to `B9406CAA.312` (2026-06-15) and 304 is no longer available to test. What can
be said is that the *mechanism* v1.x blamed cannot have been the cause, because
the driver never used the branch in question.

That uncertainty is why the module is kept rather than deleted: if a sibling
model or an older BIOS really does have a dead software path, the `asusd`
scaffolding is still here.

## Install (only if you actually need it)

The module skips itself by default. Force it only if your backlight genuinely
does not respond to the KDE slider *or* to a direct sysfs write that you have
confirmed by eye:

```sh
sudo KBF_FORCE=1 ./patch.sh install keyboard-backlight-fix
```

That installs the `xyz.ljones.Asusd` D-Bus activation file (ASUS ships a
`Type=dbus` unit without one, so `asusd` never auto-starts), an
`acpi_call` modules-load drop-in, `asusctl` from `extra`, and creates
`/etc/asusd` — which `asusd` refuses to start without.

`acpi_call-dkms` is AUR-only and needs an interactive sudo prompt during
`makepkg`, which a scripted hook can't supply:

```sh
paru -S acpi_call-dkms
```

## Status

```sh
./patch.sh status keyboard-backlight-fix
```

```
  BIOS:                  B9406CAA.312
  write path:            0x80|level via asus-wmi — SLKB OEM branch, works
  sysfs read-back:       reads 0 — firmware GET is broken, expected
  asusctl pkg:           not installed (not required)
  superseded by:         keyboard-backlight-auto (active)
```

## Uninstall

```sh
./patch.sh uninstall keyboard-backlight-fix
```

Removes the activation file and the modules-load drop-in and stops `asusd`,
leaving `asusctl` and `acpi_call-dkms` installed for reversibility:

```sh
sudo pacman -Rns asusctl
paru -Rns acpi_call-dkms
```

## Upstream tracking

`asus-armoury` (mainline Linux 6.19+) is gaining keyboard firmware-attributes
that would expose the backlight under
`/sys/class/firmware-attributes/asus-armoury/attributes/kbd_*` — Denis Benato's
LKML series, posted 2025-12-25. That is worth watching for a *readable* level,
which is the defect that actually remains.

Not there yet. On the reference machine (kernel **7.2.0**) `asus-armoury`
exposes only `charge_mode` and `pending_reboot`:

```sh
ls /sys/class/firmware-attributes/asus-armoury/attributes/ | grep -i kbd
```
