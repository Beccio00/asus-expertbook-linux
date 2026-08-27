# wifi-fix module manifest. Sourced by ../patch.sh.
#
# ASUS ExpertBook Ultra (B9406CAA) ships an Intel Wi-Fi 7 BE211 (PCI
# 8086:e440 / subsystem 8086:0114) on Panther Lake CNVi, driven by the
# new iwlmld op_mode. On Linux 6.18 through 7.2 the Wi-Fi 7 / EHT
# (802.11be) path on this card is broken: EHT RX collapses to MCS0/NSS1
# and MLO sessions tear down, so the "Wi-Fi 7" link is in practice slower
# and flakier than plain Wi-Fi 6. Not fixed upstream as of 7.1-rc7.
#
# CORE FIX — disable EHT, fall back to Wi-Fi 6 (HE):
#
#   * iwlwifi disable_11be=Y.
#     Turns off 802.11be entirely. The card renegotiates as 802.11ax
#     (Wi-Fi 6 / HE), which sustains full speed (~2.1 Gbit/s at
#     160 MHz, verified). This is the same workaround Omarchy ships as
#     /etc/modprobe.d/iwlwifi-disable-eht.conf. Remove once Intel fixes
#     the iwlwifi EHT path upstream.
#
# Linux 7.2 raises Panther Lake's supported firmware from C102 to C106. C106 can
# emit a large number of "missed beacons ... but receiving data" warnings even
# on a strong, fast link with no retries or disconnects. That is a separate
# firmware/driver accounting and log-rate problem; the driver explicitly stays
# connected. This module reports the firmware and warning count but does not
# hide the log or destructively pin an older firmware.
#
# Earlier versions also forced iwlmld power_scheme=1, disabled PCIe ASPM
# globally and disabled TSO/GSO/GRO. Those broad, power-hungry tunables did not
# stop the C106 warning flood on this machine and are retired in 2.1.0.
#
# This module *does not* touch:
#   - Wi-Fi band / channel width below EHT — 6 GHz and 160 MHz HE stay
#     available; only the broken 802.11be/320 MHz EHT layer is dropped.
#   - Bluetooth coexistence — bt_coex_active stays at default Y so BT
#     audio / HID / file transfer all keep working.

MODULE_NAME="wifi-fix"
MODULE_DESC="B9406CAA Intel BE211: disable broken EHT and diagnose C106 beacon warnings"
MODULE_VERSION="2.1.0"

MODULE_FILES=(
  "iwlwifi-disable-eht.conf:/etc/modprobe.d/iwlwifi-disable-eht.conf"
)

wifi_remove_retired_tunables() {
  rm -f -- \
    /etc/modprobe.d/iwlmld-active.conf \
    /etc/tmpfiles.d/pcie-aspm-performance.conf \
    /etc/NetworkManager/dispatcher.d/90-iwlwifi-no-offload

  if [[ -w /sys/module/pcie_aspm/parameters/policy ]]; then
    echo default > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
  fi

  if command -v ethtool >/dev/null 2>&1; then
    local ifc drv
    for ifc in /sys/class/net/*; do
      [[ -L "$ifc/device/driver" ]] || continue
      drv="$(readlink "$ifc/device/driver" 2>/dev/null || true)"
      [[ $drv == */iwlwifi ]] || continue
      ethtool -K "$(basename "$ifc")" tso on gso on gro on >/dev/null 2>&1 || true
    done
  fi
}

module_post_install() {
  wifi_remove_retired_tunables
  echo "Reboot (or reload iwlwifi) to apply disable_11be=Y."
}

module_post_uninstall() {
  wifi_remove_retired_tunables
  echo "Reboot to re-enable EHT (remove disable_11be=Y)."
}

module_status_extra() {
  local iface="" link_summary="" eht="" fw="" missed="0" kmsg=""

  # Core fix: is 802.11be (EHT) disabled? This is the indicator that the
  # actual BE211 bug is worked around. Y = EHT off -> stable Wi-Fi 6 fallback.
  if [[ -r /sys/module/iwlwifi/parameters/disable_11be ]]; then
    eht="$(cat /sys/module/iwlwifi/parameters/disable_11be 2>/dev/null || true)"
    case "$eht" in
      Y|y|1) printf '  EHT:      %sdisable_11be=Y (802.11be off — Wi-Fi 6/HE fallback)%s\n' "$c_ok" "$c_off" ;;
      N|n|0) printf '  EHT:      %sdisable_11be=N (802.11be ON — BE211 EHT is broken, expect MCS0/MLO teardown)%s\n' "$c_warn" "$c_off" ;;
      *)     printf '  EHT:      disable_11be=%s\n' "$eht" ;;
    esac
  else
    printf '  EHT:      %siwlwifi not loaded (cannot read disable_11be)%s\n' "$c_dim" "$c_off"
  fi

  kmsg="$(journalctl -k -b 0 --no-pager 2>/dev/null || true)"
  fw="$(sed -n 's/.*loaded firmware version \([^ ]*\).*/\1/p' <<<"$kmsg" | head -n1)"
  [[ -n $fw ]] && printf '  firmware: %s\n' "$fw"
  missed="$(grep -c 'missed beacons exceeds threshold, but receiving data' <<<"$kmsg" || true)"
  if [[ $missed =~ ^[0-9]+$ ]] && (( missed > 0 )); then
    printf '  beacons:  %s%s warnings this boot; driver reports data is still arriving and stays connected%s\n' \
      "$c_warn" "$missed" "$c_off"
  else
    printf '  beacons:  %sno missed-beacon warning this boot%s\n' "$c_ok" "$c_off"
  fi

  if command -v iw >/dev/null 2>&1; then
    iface="$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')"
    if [[ -n $iface ]]; then
      link_summary="$(iw dev "$iface" link 2>/dev/null \
        | awk '/freq:/ {f=$2} /signal:/ {s=$2} /SSID:/ {ssid=$2} END { if (ssid) printf "SSID=%s freq=%sMHz signal=%sdBm", ssid, f, s }')"
      [[ -n $link_summary ]] && printf '  link:     %s\n' "$link_summary"

    fi
  fi
}
