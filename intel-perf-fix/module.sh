# intel-perf-fix module manifest.
#
# Brings the same Intel Panther Lake / Lunar Lake userspace power & thermal
# tuning that Omarchy 3.5/3.6 enables out of the box, on KDE Plasma + Arch.
# Specifically:
#
#   thermald                Intel thermal management daemon. P/E core throttle
#                           awareness, much better than the kernel's coarse
#                           default on Panther Lake's hybrid topology.
#                           Arch: extra. Debian/Ubuntu: main.
#
#   intel-lpmd              Intel Low Power Mode Daemon. When the system is
#                           idle, parks all workload on a single LP-E core and
#                           lets the P-cores deep-sleep — biggest single
#                           idle-power win on PTL hardware. Stock config is
#                           Mode 0 (Cgroup v2 cpuset): it confines tasks to the
#                           LP-E cluster rather than offlining the P-cores.
#                           Arch: extra/cachyos. Ubuntu: universe (24.04+).
#                           Not in Debian yet, so its absence is tolerated.
#                           Caveat: Ubuntu 24.04 ships 0.0.3 (Feb 2024), which
#                           exits immediately on Panther Lake (family 6 model
#                           204) because it predates it. Verified on Pop!_OS
#                           24.04. The install hook reports this.
#
# We deliberately DO NOT touch:
#   - The Hyprland-only toggles (Omarchy is Hyprland-based; we run KDE Plasma
#     which already handles touchpad / window scaling / lid the way we want).
#   - Dell-DMI-gated kernel patches (we proved earlier that the upstream
#     intel_quirks.c PCI subsystem entries match Dell only — 0x1028:0x0db9 —
#     and never trigger on our ASUS B9406CAA at 0x1043:0x15e4).
#   - power-profiles-daemon (already installed; coexists fine with thermald).
#
# This module ships no payload files; everything happens in the install hook
# (package installs + systemd unit enables). Empty MODULE_FILES is intentional
# and supported by patch.sh (mod_files_state treats empty as "all").
#
# Package and service calls go through lib/distro.sh so the same hook works on
# pacman and apt systems. The unit name is resolved at runtime rather than
# hardcoded: intel-lpmd ships as intel_lpmd.service on Arch, and the unit name
# is a packaging decision each distribution makes independently.

MODULE_NAME="intel-perf-fix"
MODULE_DESC="Panther Lake thermal + power daemons (thermald, intel-lpmd) à la Omarchy"
MODULE_VERSION="1.2.0"

MODULE_FILES=()

module_post_install() {
  local unit

  echo "  installing thermald"
  pkg_install thermald 2>&1 | tail -3 || true

  unit="$(svc_unit thermald.service)"
  echo "  enabling $unit"
  svc_enable_now "$unit" 2>&1 | tail -1 || true

  echo
  if pkg_installed intel-lpmd || pkg_available intel-lpmd; then
    echo "  installing intel-lpmd"
    pkg_install intel-lpmd 2>&1 | tail -3 || true

    unit="$(svc_unit intel_lpmd.service intel-lpmd.service)"
    echo "  enabling $unit"
    svc_enable_now "$unit" 2>&1 | tail -1 || true

    # intel_lpmd exits immediately on a CPU model it predates, without logging
    # a reason. Ubuntu 24.04 ships 0.0.3 (Feb 2024), which does not know
    # Panther Lake, so the unit enables and the daemon is dead a few ms later.
    # Say so instead of leaving the user thinking they got the idle-power win.
    if ! svc_is_active "$unit"; then
      warn "$unit was enabled but is not running"
      echo "  intel-lpmd $(pkg_version intel-lpmd) exits on CPU models it does not"
      echo "  recognise. Panther Lake needs a newer release than this distribution"
      echo "  ships. The unit stays enabled, so a later package upgrade starts"
      echo "  working without re-running this module."
    fi
  else
    # Debian has no intel-lpmd package (Ubuntu carries it in universe).
    # thermald alone still covers the thermal half, so a missing intel-lpmd is
    # a warning rather than a failure. On Arch this branch is unreachable
    # unless `pacman -Si intel-lpmd` fails, in which case `pacman -S` would
    # have failed the same way.
    warn "intel-lpmd is not available on this distribution; skipping it"
    echo "  thermald alone still covers the thermal half of this module."
  fi
}

module_post_uninstall() {
  local unit

  unit="$(svc_unit thermald.service)"
  echo "  disabling $unit"
  svc_disable_now "$unit" 2>/dev/null || true

  unit="$(svc_unit intel_lpmd.service intel-lpmd.service)"
  if svc_exists "$unit"; then
    svc_disable_now "$unit" 2>/dev/null && echo "  disabled $unit"
  fi

  echo
  echo "  Packages left installed (so revert is reversible without re-fetching)."
  echo "  Remove fully with:"
  echo "    $(pkg_remove_hint thermald)"
  echo "    $(pkg_remove_hint intel-lpmd)"
}

module_status_extra() {
  local s svc version

  for svc in "$(svc_unit thermald.service)" \
             "$(svc_unit intel_lpmd.service intel-lpmd.service)"; do
    # `systemctl is-active` answers "inactive" for a unit that does not exist,
    # so ask svc_exists instead — the silent case the original code intended.
    svc_exists "$svc" || continue
    s="$(systemctl is-active "$svc" 2>/dev/null || true)"
    case "$s" in
      active)          printf '  %-22s %sactive%s\n' "$svc" "$c_ok" "$c_off" ;;
      inactive|failed) printf '  %-22s %s%s%s\n' "$svc" "$c_warn" "$s" "$c_off" ;;
    esac
  done

  for svc in thermald intel-lpmd; do
    version="$(pkg_version "$svc")"
    if [[ -n $version ]]; then
      printf '  %-22s %s%s%s\n' "$svc pkg:" "$c_ok" "$version" "$c_off"
    else
      printf '  %-22s %snot installed%s\n' "$svc pkg:" "$c_warn" "$c_off"
    fi
  done

  # Explain a dead intel_lpmd rather than leaving a bare "inactive" above.
  svc="$(svc_unit intel_lpmd.service intel-lpmd.service)"
  if svc_exists "$svc" && ! svc_is_active "$svc" && pkg_installed intel-lpmd; then
    printf '  %-22s %sinstalled but exits at startup — too old for this CPU%s\n' \
      "intel-lpmd:" "$c_warn" "$c_off"
  fi
}
