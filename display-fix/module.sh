# shellcheck shell=bash
# display-fix module manifest.
#
# ASUS ExpertBook Ultra (B9406CAA) Panther Lake iGPU + xe driver hangs the
# eDP-1 display engine when the panel uses Panel Replay Selective Update.
# Symptoms in dmesg:
#   xe 0000:00:02.0: [drm] *ERROR* Timed out waiting PSR idle state
#   xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] DSB 0 timed out waiting for idle
#   kwin_wayland: Pageflip timed out! This is a bug in the xe kernel driver
# and the internal panel goes black until reboot.
#
# Fix: disable PSR / Panel Replay and force the panel's VESA DPCD backlight
# interface (`xe.enable_dpcd_backlight=2`) via kernel cmdline. The latter fixes
# the B9406CAA case where sysfs brightness changes but panel luminance does not.
# modprobe.d
# alone is NOT enough on this distro — xe loads from initramfs before
# /etc/modprobe.d is honoured, so the params have to land on the kernel
# cmdline. We install a managed `limine-entry-tool` drop-in and regenerate the
# Limine entries. This is the CachyOS source of truth; `/etc/default/limine`
# is not used by current limine-mkinitcpio-hook releases.
#
# We still drop the modprobe.d file as belt-and-suspenders for any future
# scenario where xe is rmmod'd and re-loaded post-boot.
#
# Upstream status: there is NO dedicated upstream tracker for this PTL
# PSR2 selective-fetch / DSB display hang. It is reproduced locally on
# linux-cachyos 7.0.11 and linux-cachyos-rc 7.1-rc7. (drm/xe #7513 is a
# related but DISTINCT Lunar Lake PMC-firmware shutdown bug — "rare
# shutdown under load", label platform: LNL, leaves a BERT Hardware Error
# and is NOT cured by disabling PSR — so it is NOT this bug.) The cmdline
# workaround below is therefore still required on every current kernel.

MODULE_NAME="display-fix"
MODULE_DESC="B9406CAA xe: stable panel plus working DPCD brightness control"
MODULE_VERSION="1.2.0"

MODULE_FILES=(
  "xe-disable-psr.conf:/etc/modprobe.d/xe-disable-psr.conf"
  "limine-display.conf:/etc/limine-entry-tool.d/90-asus-expertbook-linux-display.conf"
)

_df_remove_legacy_block() {
  local legacy="/etc/default/limine"
  local begin="# >>> asus-expertbook-linux display-fix >>>"
  local end="# <<< asus-expertbook-linux display-fix <<<"

  if [[ -f $legacy ]] && grep -qF "$begin" "$legacy" && \
     grep -qF "$end" "$legacy"; then
    sed -i "/^${begin}$/,/^${end}$/d" "$legacy"
    log "[display-fix] removed the obsolete managed block from $legacy"
  fi
}

_df_regen_limine() {
  if command -v limine-update >/dev/null 2>&1; then
    log "[display-fix] regenerating Limine entries"
    limine-update
  elif command -v limine-mkinitcpio >/dev/null 2>&1; then
    log "[display-fix] regenerating Limine initramfs entries"
    limine-mkinitcpio
  else
    die "[display-fix] Limine tooling not found; kernel parameters were not activated"
  fi
}

module_post_install() {
  _df_remove_legacy_block
  _df_regen_limine
  echo
  echo "Reboot to apply: xe will load with PSR disabled and VESA DPCD backlight forced."
}

module_post_uninstall() {
  _df_remove_legacy_block
  _df_regen_limine
  echo
  echo "Reboot to revert: PSR will be re-enabled and the lockup may recur."
}

module_status_extra() {
  local backlight_value="" token

  if grep -q 'xe\.enable_psr=0' /proc/cmdline 2>/dev/null; then
    printf '  cmdline: %sxe.enable_psr=0 active in current boot%s\n' "$c_ok" "$c_off"
  else
    if [[ -f /etc/limine-entry-tool.d/90-asus-expertbook-linux-display.conf ]]; then
      printf '  cmdline: %sLimine drop-in installed — reboot to apply%s\n' "$c_warn" "$c_off"
    else
      printf '  cmdline: %sxe.enable_psr not on kernel cmdline%s\n' "$c_warn" "$c_off"
    fi
  fi

  while IFS= read -r token; do
    if [[ $token == xe.enable_dpcd_backlight=* ]]; then
      backlight_value="${token#*=}"
    fi
  done < <(tr ' ' '\n' </proc/cmdline 2>/dev/null)

  if [[ $backlight_value == 2 ]]; then
    printf '  backlight:%s xe.enable_dpcd_backlight=2 active (forced VESA interface)%s\n' \
      "$c_ok" "$c_off"
  elif [[ -n $backlight_value ]]; then
    printf '  backlight:%s effective xe.enable_dpcd_backlight=%s (expected 2)%s\n' \
      "$c_warn" "$backlight_value" "$c_off"
  elif [[ -f /etc/limine-entry-tool.d/90-asus-expertbook-linux-display.conf ]]; then
    printf '  backlight:%s DPCD fix staged — reboot to apply%s\n' "$c_warn" "$c_off"
  else
    printf '  backlight:%s xe.enable_dpcd_backlight=2 is not active%s\n' "$c_warn" "$c_off"
  fi

  if [[ -r /sys/kernel/debug/dri/0/i915_edp_psr_status ]]; then
    local mode
    mode="$(awk -F': ' '/^PSR mode:/ {print $2; exit}' /sys/kernel/debug/dri/0/i915_edp_psr_status 2>/dev/null)"
    if [[ -n "$mode" ]]; then
      case "$mode" in
        disabled*) printf '  panel:   %sPSR mode: %s%s\n' "$c_ok" "$mode" "$c_off" ;;
        *)         printf '  panel:   %sPSR mode: %s%s\n' "$c_warn" "$mode" "$c_off" ;;
      esac
    fi
  fi
}
