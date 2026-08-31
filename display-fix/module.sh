# shellcheck shell=bash
# display-fix module manifest.
#
# Linux 7.2 includes the Panther Lake Panel Replay/PSR, selective-fetch, DSB,
# DC-state and Xe recovery fixes needed to retest the panel with self-refresh
# enabled. Do not globally force PSR, PSR2 selective fetch or Panel Replay off.
# Keep only the panel's independently verified VESA DPCD backlight override
# (`xe.enable_dpcd_backlight=2`), which fixes the B9406CAA case where sysfs
# brightness changes but panel luminance does not. modprobe.d alone is NOT
# enough on this distro — xe loads from initramfs before
# /etc/modprobe.d is honoured, so the params have to land on the kernel
# cmdline. We install a managed `limine-entry-tool` drop-in and regenerate the
# Limine entries. This is the CachyOS source of truth; `/etc/default/limine`
# is not used by current limine-mkinitcpio-hook releases.
#
# We still drop the modprobe.d file as belt-and-suspenders for any future
# scenario where xe is rmmod'd and re-loaded post-boot. Install also retires
# the two older local files that added the global `=0` safety switches.

MODULE_NAME="display-fix"
MODULE_DESC="B9406CAA xe: working DPCD brightness; PSR/Panel Replay use Linux 7.2 defaults"
MODULE_VERSION="1.3.0"

MODULE_FILES=(
  "xe-dpcd-backlight.conf:/etc/modprobe.d/xe-dpcd-backlight.conf"
  "limine-display.conf:/etc/limine-entry-tool.d/90-asus-expertbook-linux-display.conf"
)

_df_remove_obsolete_files() {
  local old_modprobe="/etc/modprobe.d/xe-disable-psr.conf"
  local old_limine="/etc/limine-entry-tool.d/asus-expertbook-b9406-display.conf"
  local archived="${old_limine}.disabled-by-asus-expertbook-linux"

  if [[ -f $old_modprobe ]]; then
    rm -- "$old_modprobe"
    log "[display-fix] removed obsolete PSR-disable file $old_modprobe"
  fi

  if [[ -f $old_limine ]]; then
    if [[ ! -e $archived ]]; then
      mv -- "$old_limine" "$archived"
      log "[display-fix] archived obsolete Limine drop-in as $archived"
    else
      rm -- "$old_limine"
      log "[display-fix] removed duplicate obsolete Limine drop-in $old_limine"
    fi
  fi
}

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
  _df_remove_obsolete_files
  _df_regen_limine
  echo
  echo "Reboot to apply: xe will use Linux 7.2 PSR/Panel Replay defaults with VESA DPCD backlight forced."
}

module_post_uninstall() {
  _df_remove_legacy_block
  _df_remove_obsolete_files
  _df_regen_limine
  echo
  echo "Reboot to stop forcing the VESA DPCD backlight interface."
}

module_status_extra() {
  local backlight_value=""

  if cmdline_active xe.enable_psr=0 || \
     cmdline_active xe.enable_psr2_sel_fetch=0 || \
     cmdline_active xe.enable_panel_replay=0; then
    printf '  self-refresh:%s legacy =0 override active in this boot — reboot to use kernel defaults%s\n' \
      "$c_warn" "$c_off"
  else
    printf '  self-refresh:%s no global PSR/Panel Replay disable; Linux defaults active%s\n' \
      "$c_ok" "$c_off"
  fi

  backlight_value="$(cmdline_active_value xe.enable_dpcd_backlight)"

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
        disabled*) printf '  panel:   %sPSR mode: %s%s\n' "$c_warn" "$mode" "$c_off" ;;
        *)         printf '  panel:   %sPSR mode: %s%s\n' "$c_ok" "$mode" "$c_off" ;;
      esac
    fi
  fi
}
