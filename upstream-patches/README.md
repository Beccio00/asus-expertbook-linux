# Upstream patches

Four submission-ready patches that bring this ASUS B9406CAA into the
existing upstream quirk infrastructure — same shape as the entries
already shipped for Dell, Lenovo, and other ASUS models.

When all four land upstream, the touchpad quirk and audio DKMS overlay become
redundant. `display-fix` can shed its PSR / Panel Replay workaround then, while
its separate DPCD-backlight setting remains until the kernel selects the right
backlight interface for this panel automatically.

## The four patches

### `0001-drm-i915-Add-Panel-Replay-quirk-for-ASUS-ExpertBook-.patch`

- **Tree:** `torvalds/linux` → `drivers/gpu/drm/i915/display/intel_quirks.c`
- **Mailing list:** `intel-xe@lists.freedesktop.org` (Cc: `intel-gfx@lists.freedesktop.org`)
- **What it does:** adds an `intel_dpcd_quirks[]` entry for PCI subsystem
  `0x1043:0x15e4` + panel sink IEEE OUI `0x00:0xaa:0x01` calling
  `quirk_disable_edp_panel_replay`. Same shape as the existing Dell XPS
  14 DA14260 / XPS 16 DA16260 entries (both now in mainline) — upstream
  keeps growing this list with per-device disables; there is no "make
  Panel Replay actually work"
  upstream patch, even from Intel's own engineers ("disabled by default,
  at least until the underlying issue can be sorted out", per Phoronix
  for the Dell entry).
- **Replaces:** the PSR / Panel Replay portion of `display-fix`; the separate
  DPCD-backlight setting remains until panel brightness works automatically.

### `0002-ASoC-Intel-sof_sdw-Add-quirk-for-ASUS-ExpertBook-Ult.patch`

- **Tree:** `torvalds/linux` → `sound/soc/intel/boards/sof_sdw.c`
- **Mailing list:** `linux-sound@vger.kernel.org` (Cc: `alsa-devel@alsa-project.org`)
- **What it does:** adds a `sof_sdw_ssid_quirk_table[]` entry for PCI
  subsystem `0x1043:0x15e4` flagging `SOC_SDW_SIDECAR_AMPS`. The SSID
  table is where ASUS Zenbook S14 / S16 and Lenovo P1 / P16 entries
  already live; ours fits in by ASUS subsystem-vendor sort order. Other
  ASUS entries use `SOC_SDW_CODEC_MIC` because they have only the
  CS42L43 codec; ours is structurally closer to Lenovo 0x3821
  (`SOC_SDW_SIDECAR_AMPS` only, cs42l43 + sidecar amps).
- **Unlike the Panel Replay one, this is a real "enable" patch** — once
  applied, ALSA UCM can match the resulting card to a HiFi profile and the
  speaker amps engage through the standard PipeWire path. The mic-mute LED
  works through UCM; this laptop exposes no Linux device for the F1
  speaker-mute LED.
- **Complements:** the combined-codec UCM that is already upstream in
  `alsa-ucm-conf 1.2.16`.

### `0003-libinput-quirks-Add-PixArt-093A-4F05-touchpad.patch`

- **Tree:** `freedesktop.org/libinput/libinput` → `quirks/30-vendor-pixart.quirks`
- **Where to send:** GitLab MR at <https://gitlab.freedesktop.org/libinput/libinput>
- **What it does:** disables `ABS_MT_PRESSURE` / `ABS_PRESSURE` for the
  PixArt I2C-HID `093A:4F05` haptic touchpad. Same shape as the Asus
  UX302LA quirk already in `50-system-asus.quirks`.
- **Replaces:** `touchpad-fix`'s `local-overrides.quirks`. The hwdb
  pressure-clamp file stays useful as belt-and-suspenders since not
  every libinput consumer reads `local-overrides.quirks` on every
  device-open path.

### `0004-soundwire-dmi-quirks-Disable-ghost-rt722-on-ASUS-Exp.patch`

- **Tree:** `torvalds/linux` → `drivers/soundwire/dmi-quirks.c`
- **Mailing list:** `linux-sound@vger.kernel.org` (Cc: `alsa-devel@alsa-project.org`)
- **What it does:** adds a `DMI_MATCH(DMI_SYS_VENDOR "ASUS", DMI_BOARD_NAME
  "B9406CAA")` entry to `adr_remap_quirk_table[]` pointing at the existing
  `ghost_realtek` `adr_remap`, which remaps the phantom rt722 `_ADR`
  `0x000330025d072201` → `0` so the SoundWire core skips it. This is the
  fix that lets the card probe at all — **distinct from `0002`**, which
  only un-silences a card that already probed. The `ghost_realtek` array
  and its infra come from a5bec626b985 ("soundwire: dmi-quirks: Disable
  ghost Realtek devices"), which landed in mainline **after 7.1** (in the
  7.2 merge window) and covers ASUS UX5406AA + Lenovo 83QK/83SF but **not**
  the B9406CAA. Verified against `torvalds/linux` master: the block exists,
  our board does not — so this one-entry addition is all that is needed.
- **Without it:** on 7.1's function-topology card builder the ghost rt722
  produces a duplicate `SDW3-Playback-SimpleJack` DAI →
  `kobject_add -EEXIST` → `sof_sdw probe -12` → empty `/proc/asound/cards`.
- **Replaces:** `audio-fix`'s `asus-expertbook-sof-sdw` DKMS overlay, which
  currently filters the same exact RT722 only when the core reports it as
  `UNATTACHED`. Once this lands on your running kernel, that overlay is no
  longer needed.

## Other research findings (not new patches, but relevant)

| Question | Finding |
|---|---|
| Is there a `sof_sdw` patch elsewhere in mainline that might already match us by SSID? | No. Searched master + drm-intel-next + linux-next. `0x15e4` / `B9406CAA` / `EXPERTBOOK` appear nowhere in upstream kernel. |
| Did the ghost-Realtek disable (a5bec626b985) reach a kernel that covers us? | Its infrastructure reached 7.2, but its DMI table still matches ASUS UX5406AA + Lenovo 83QK/83SF — **no B9406CAA**. So `0004` is still required; until it lands, `audio-fix` carries the board-scoped SOF DKMS overlay. |
| Is there a kernel-level "make Panel Replay work on Dell" patch we missed? | No. Confirmed by reading `drm-intel-next` `intel_quirks.c` — that branch is *adding more* per-device disable entries (Dell XPS 16 DA16260), not enabling Panel Replay. Phoronix coverage of the Linux 7.1 patch is explicit: "disabled by default, at least until the underlying issue can be sorted out". |
| Is there a generic upstream Wi-Fi 7 BE211 fix Omarchy bundles that we should mirror? | Omarchy's fix is **not** a kernel patch — it's the same `options iwlwifi disable_11be=Y` modprobe drop-in this repo's `wifi-fix` now ships. EHT/802.11be is broken on BE211 and there is no upstream EHT fix in mainline `iwlwifi`/`iwlmld` as of 7.1-rc7, so disabling EHT (Wi-Fi 6 fallback) is the current best practice on both. |
| Has `linux-firmware-cirrus` shipped our subsystem ID? | **Yes, in `20260410-1` (extra/core repo).** Older `1:20260309-1` (cachyos epoch) does not. The newer package contains: `cs35l56-b0-dsp1-misc-104315e4-l2u{0,1}.bin.zst` plus a `cs35l56-b0-dsp1-misc-104315e4.wmfw.zst` symlink → `cs35l56/CS35L56_Rev3.13.4.wmfw.zst`. The shipping content is byte-identical to the files audio-fix carries (verified via sha256). When CachyOS bumps their epoch to `1:20260410+`, the firmware blobs in `audio-fix/` become redundant and the module can shed them. |
| Does the panel firmware bug have a fix in upstream xe? | Not for our model. The `intel_psr.c` codepath that times out (`Timed out waiting PSR idle state`) has had several touch-ups in 6.18-6.20 but none gates by panel sink OUI / DPCD revision in a way that helps us. The cleanest fix remains the per-device disable our 0001 adds. |

## Hardware identifiers used

| Field | Value | Source |
|---|---|---|
| PCI audio subsystem | `0x1043:0x15e4` | `lspci -nnvk -d ::0403` |
| eDP panel sink IEEE OUI | `0x00 0xaa 0x01` | DPCD register 0x300 (read via `/dev/drm_dp_aux0`) |
| EDID manufacturer | `SDC` (Samsung Display Corp) | EDID bytes 8-9: `0x4c83` |
| EDID product code | `0x4217` | EDID bytes 10-11 (LE) |
| DMI sys_vendor | `ASUS` | `/sys/class/dmi/id/sys_vendor` |
| DMI product_name | `ASUS EXPERTBOOK B9406CAA` | `/sys/class/dmi/id/product_name` |
| Touchpad | `093A:4F05` (ACPI `ASCP1D80`) | `/proc/bus/input/devices` |

## How to test (without rebuilding the kernel)

The libinput patch needs no rebuild — just place the new section into
`/etc/libinput/local-overrides.quirks`. We already do that in
`touchpad-fix` (and `libinput quirks list /dev/input/event9` confirms
it's loaded).

The three kernel patches (`0001`, `0002`, `0004`) need a rebuild. With the
CachyOS kernel sources cloned (e.g. under
`~/Developers/kernel-build/linux-cachyos/`), the PKGBUILD's `prepare()`
already loops over every `*.patch` in `source=` and applies it, so adding
our patches to the source array is all that's needed.

```sh
cd ~/Developers/kernel-build/linux-cachyos/linux-cachyos
cp ~/Developers/asus-expertbook-linux/upstream-patches/000{1,2,4}*.patch .
# Edit PKGBUILD: append the three filenames to the source=() array
# Then:
makepkg -si           # ~30-60 minutes; installs at the end
sudo reboot
# Boot and verify:
./patch.sh status display-fix      # cmdline marker no longer needed
./patch.sh status audio-fix        # HiFi card present; DKMS no longer needed after 0004
cat /proc/asound/cards             # 0004: card present without the DKMS overlay
dmesg | grep -i remapped           # 0004: "remapped _ADR 0x...072201 as 0x0"
```

If they all work, remove the corresponding local workarounds and submit the patches to
their respective mailing lists.

## How to submit (once verified)

Each patch is in `git format-patch` body style. For the kernel:

```sh
git send-email --to=<list> --cc=<maintainers> upstream-patches/0001-...patch
```

(Configure `git send-email` first, or paste body into the mailing-list
webform.)

For libinput: fork on GitLab, branch, apply `0003-...patch`, push, MR.
