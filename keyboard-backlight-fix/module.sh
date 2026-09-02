# keyboard-backlight-fix module manifest.  ── OPTIONAL, AND ALMOST CERTAINLY
#                                             UNNECESSARY — see below ──
#
# HISTORY / CORRECTION (2026-09-02)
# ---------------------------------
# Versions 1.x of this module claimed that OS-initiated keyboard-backlight
# writes were clamped to zero by a firmware bug, and shipped asusd as the
# workaround. Re-measured on the reference machine, that diagnosis does not
# hold. Both the claim and the workaround are retained here only for older
# firmware; the module now refuses to install unless forced.
#
# What was measured, with asusctl NOT installed, /etc/asusd absent and asusd
# inactive (BIOS B9406CAA.312, Linux 7.2.0):
#
#   * Writing 0, 1, 2 and 3 to /sys/class/leds/asus::kbd_backlight/brightness
#     changes the keyboard illumination across the full range, confirmed by
#     eye. The KDE PowerDevil slider works for the same reason.
#   * Reading that node back returns 0 every time, whatever was written.
#     UPower's KbdBacklight.GetBrightness and `brightnessctl` agree, because
#     all three read the same sysfs attribute.
#
# So the write path is fine and the READ path is broken — the opposite way
# round from what v1.x documented.
#
# WHY THE OLD ANALYSIS WAS WRONG
# ------------------------------
# The SLKB disassembly itself was right; the claim about which branch Linux
# reaches was not. Mainline asus-wmi never writes the bare 0..3 range:
#
#   static void kbd_led_update(struct asus_wmi *asus)
#   {
#           int ctrl_param = 0;
#
#           scoped_guard(spinlock_irqsave, &asus_ref.lock)
#                   ctrl_param = 0x80 | (asus->kbd_led_wk & 0x7F);
#           asus_wmi_set_devstate(ASUS_WMI_DEVID_KBD_BACKLIGHT, ctrl_param, NULL);
#   }
#
# 0x80 | level lands in 0x80..0x83, which is SLKB's *second* branch — the one
# v1.x already documented as working. The buggy `ElseIf ((Arg0 >= Zero) &&
# (Arg0 <= 0x03)) { Local0 = Zero }` branch is unreachable from this driver.
# asusd's range translation therefore had nothing to fix.
#
# The residual defect is on the way back in:
#
#   static int kbd_led_read(struct asus_wmi *asus, int *level, int *env)
#   {
#           retval = asus_wmi_get_devstate_bits(asus, ASUS_WMI_DEVID_KBD_BACKLIGHT,
#                                               0xFFFF);
#           if (retval == 0x8000)
#                   retval = 0;
#           ...
#           if (level)
#                   *level = retval & 0x7F;
#
# The firmware's query returns nothing usable, so *level is always 0. asusd
# does not fix this either — it is a firmware read path, not a range problem.
#
# The defect is in the QUERY path only. The LED's sibling attribute
# brightness_hw_changed does report the real level whenever the EC changes it
# (an Fn keypress) — verified 2026-09-02 by watching UPower relay
# BrightnessChangedWithSource(1|2|3, "internal") on the system bus, which is
# also what raises KDE's on-screen display. It is a notification of what the
# hardware just did, not a queryable state, so `cat brightness` stays broken;
# but keyboard-backlight-auto uses it to stay in sync with a hand-set level.
# The Fn keys themselves emit no input event on any of the 15 event devices.
#
# Visible consequence worth knowing about: systemd-backlight@leds:asus::
# kbd_backlight saves the read-back value at shutdown, which is always 0, so
# every boot restores a dark keyboard. keyboard-backlight-auto is ordered
# After= it and overrides it within a second.
#
# WHAT REMAINS UNKNOWN
# --------------------
# Whether OS control was genuinely broken under the BIOS this module was
# written against (B9406CAA.304). The reference machine has since been updated
# to B9406CAA.312 (2026-06-15) and 304 is no longer available to test. What can
# be said is that the *mechanism* v1.x blamed cannot have been the cause, and
# that on 312 nothing here is needed.
#
# The v1.x status check was a false negative by construction: it wrote a level
# and read it back, and the read is always 0, so it reported FAILED on a
# perfectly working backlight. That check is gone.

MODULE_NAME="keyboard-backlight-fix"
MODULE_DESC="(superseded) asusd workaround for OS-initiated keyboard backlight writes"
MODULE_VERSION="2.0.0"

MODULE_FILES=(
  "xyz.ljones.Asusd.service:/usr/share/dbus-1/system-services/xyz.ljones.Asusd.service"
  "acpi_call.conf:/etc/modules-load.d/acpi_call.conf"
)

_kbf_led=/sys/class/leds/asus::kbd_backlight/brightness

module_install() {
  if [[ ${KBF_FORCE:-0} != 1 ]]; then
    echo "  This module is superseded and does nothing useful on BIOS B9406CAA.312"
    echo "  with mainline asus-wmi: the driver writes 0x80|level, which SLKB handles"
    echo "  correctly, so keyboard brightness already reaches the EC without asusd."
    echo "  What is actually broken is reading the level back, which asusd cannot fix."
    echo
    echo "  If your keyboard backlight genuinely does not respond to the KDE slider"
    echo "  or to a direct sysfs write, install it anyway with:"
    echo "      sudo KBF_FORCE=1 ./patch.sh install keyboard-backlight-fix"
    echo
    echo "  See ./keyboard-backlight-fix/README.md for the full measurement."
    return 10
  fi

  mod_install_files

  echo "  installing asusctl (extra repo)"
  pacman -S --needed --noconfirm asusctl 2>&1 | tail -3 || true

  echo "  ensuring /etc/asusd directory exists (asusd refuses to start without it)"
  install -d -m 0755 /etc/asusd

  echo "  reloading dbus daemon (pick up the new activation file)"
  systemctl reload dbus 2>/dev/null || systemctl reload dbus.socket 2>/dev/null || true

  echo
  echo "  acpi_call-dkms is in the AUR. paru/yay needs an interactive sudo prompt"
  echo "  during makepkg->install which a scripted hook can't supply. Run separately:"
  echo "      paru -S acpi_call-dkms"
  echo

  if ! lsmod | grep -q '^acpi_call'; then
    modprobe acpi_call 2>/dev/null && echo "  loaded acpi_call now" \
      || echo "  acpi_call not yet installed — skip"
  fi

  if ! systemctl is-active --quiet asusd; then
    busctl --system call xyz.ljones.Asusd /xyz/ljones/Asusd \
      org.freedesktop.DBus.Peer Ping >/dev/null 2>&1 || \
      systemctl start asusd 2>/dev/null || true
  fi
}

module_post_uninstall() {
  echo "  reloading dbus daemon (drop the activation file)"
  systemctl reload dbus 2>/dev/null || systemctl reload dbus.socket 2>/dev/null || true

  if systemctl is-active --quiet asusd; then
    echo "  stopping asusd (was bus-activated; only auto-starts again if reinstalled)"
    systemctl stop asusd 2>/dev/null || true
  fi

  echo
  echo "  Packages (asusctl, acpi_call-dkms) left installed for revert without"
  echo "  re-fetching. Remove fully with:"
  echo "    sudo pacman -Rns asusctl"
  echo "    paru -Rns acpi_call-dkms"
}

module_status_extra() {
  local bios
  bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
  [[ -n $bios ]] && printf '  BIOS:                  %s%s%s\n' "$c_dim" "$bios" "$c_off"

  printf '  write path:            %s0x80|level via asus-wmi — SLKB OEM branch, works%s\n' \
    "$c_ok" "$c_off"

  # Reading the node back is broken in firmware. Report it as the known,
  # expected defect it is — NOT as a failure, and never as a write test: the
  # v1.x check wrote a value, read back 0, and wrongly declared the backlight
  # dead. There is no way to verify the write path from software; the only
  # honest test is to write a level and look at the keyboard.
  local readback="n/a"
  [[ -r $_kbf_led ]] && readback="$(cat "$_kbf_led" 2>/dev/null)"
  printf '  sysfs read-back:       %sreads %s — firmware GET is broken, expected%s\n' \
    "$c_dim" "$readback" "$c_off"
  printf '  brightness_hw_changed: %sdoes report real levels on EC changes%s\n' \
    "$c_dim" "$c_off"

  if pacman -Q asusctl >/dev/null 2>&1; then
    printf '  asusctl pkg:           %s%s (not required)%s\n' \
      "$c_dim" "$(pacman -Q asusctl | awk '{print $2}')" "$c_off"
    local asusd_state
    asusd_state="$(systemctl is-active asusd 2>/dev/null || true)"
    printf '  asusd:                 %s%s%s\n' "$c_dim" "${asusd_state:-unknown}" "$c_off"
  else
    printf '  asusctl pkg:           %snot installed (not required)%s\n' "$c_ok" "$c_off"
  fi

  if systemctl is-active --quiet kbd-backlight-auto 2>/dev/null; then
    printf '  superseded by:         %skeyboard-backlight-auto (active)%s\n' "$c_ok" "$c_off"
  else
    printf '  see also:              %skeyboard-backlight-auto (ambient-light control)%s\n' \
      "$c_dim" "$c_off"
  fi
}
