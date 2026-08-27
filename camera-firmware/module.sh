# shellcheck shell=bash
# Camera firmware module for the ASUS ExpertBook Ultra B9406CAA.
# Sourced by ../patch.sh.

MODULE_NAME="camera-firmware"
MODULE_DESC="Offer the verified ASUS camera firmware 3009 update when the ESRT version is older"
MODULE_VERSION="3009"
MODULE_FILES=()

CAMERA_MODEL="B9406CAA"
CAMERA_TARGET_GUID="d9d10946-36c2-3bcb-bffc-fcda56025390"
CAMERA_TARGET_VERSION_RAW=479569
CAMERA_TARGET_VERSION_HUMAN="10.1.2.3009"
CAMERA_PACKAGE_NAME="ASUS_B9406CAA_3009_Camera_FW_Update.exe"
CAMERA_PACKAGE_URL="https://dlcdnets.asus.com/pub/ASUS/Commercial_NB/Image/Firmware/126901/ASUS_B9406CAA_3009_Camera_FW_Update.exe"
CAMERA_PACKAGE_SHA256="7a14843f4e86b5d9d775639f73ffc652948776efc67d3174596df2884a4e2065"
CAMERA_CAPSULE_NAME="B9406CAA-CameraFW_01-3009.cap"
CAMERA_CAPSULE_SHA256="2ce9d32f9db8a9f0d9a553d4a6723e66901070a1a741920c1e63c8c5480fa2f8"

# The verified ASUS self-extractor contains a 7z resource at this exact byte
# range. Fixed offsets are safe because the complete outer file is hash-pinned
# before extraction.
CAMERA_PAYLOAD_OFFSET=4289240
CAMERA_PAYLOAD_SIZE=493114

camera_is_supported_model() {
  local board product
  board="$(tr -d '\n' </sys/class/dmi/id/board_name 2>/dev/null || true)"
  product="$(tr -d '\n' </sys/class/dmi/id/product_name 2>/dev/null || true)"
  [[ $board == "$CAMERA_MODEL" || $product == *"$CAMERA_MODEL"* ]]
}

camera_device_json() {
  command -v fwupdmgr >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  fwupdmgr get-devices --json 2>/dev/null | jq -cer \
    --arg guid "$CAMERA_TARGET_GUID" \
    'first(.Devices[] | select((.Guid // []) | index($guid)))'
}

camera_raw_from_json() {
  jq -r '(.VersionRaw // .Version // 0) | tonumber? // 0' <<<"$1"
}

camera_find_local_package() {
  local owner_uid owner_home candidate
  local candidates=(
    "$MODULE_DIR/$CAMERA_PACKAGE_NAME"
    "$ROOT_DIR/$CAMERA_PACKAGE_NAME"
  )

  owner_uid="$(stat -c '%u' "$ROOT_DIR" 2>/dev/null || true)"
  owner_home="$(getent passwd "$owner_uid" 2>/dev/null | cut -d: -f6)"
  if [[ -n $owner_home ]]; then
    candidates+=(
      "$owner_home/Desktop/$CAMERA_PACKAGE_NAME"
      "$owner_home/Downloads/$CAMERA_PACKAGE_NAME"
      "$owner_home/Masaüstü/$CAMERA_PACKAGE_NAME"
      "$owner_home/İndirilenler/$CAMERA_PACKAGE_NAME"
    )
  fi

  if [[ -n ${ASUS_CAMERA_FW_EXE:-} ]]; then
    candidates=("$ASUS_CAMERA_FW_EXE" "${candidates[@]}")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

camera_ac_online() {
  local online seen=0
  for online in /sys/class/power_supply/*/online; do
    [[ -r $online ]] || continue
    seen=1
    [[ $(<"$online") == 1 ]] && return 0
  done

  # Some systems expose no AC online property. In that case fwupd performs its
  # own requirement check; only reject when the kernel explicitly says offline.
  (( seen == 0 )) && return 0
  return 1
}

camera_require_tools() {
  local packages=()
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  command -v 7z >/dev/null 2>&1 || packages+=(7zip)
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  if ! command -v fwupdmgr >/dev/null 2>&1 || \
     ! command -v fwupdtool >/dev/null 2>&1; then
    packages+=(fwupd)
  fi

  if (( ${#packages[@]} > 0 )); then
    if command -v pacman >/dev/null 2>&1; then
      log "[camera-firmware] installing required tools: ${packages[*]}"
      pacman -S --needed --noconfirm "${packages[@]}"
    else
      die "[camera-firmware] missing tools: ${packages[*]}"
    fi
  fi
}

module_install_state() {
  local json raw
  if ! camera_is_supported_model; then
    echo not-installed
    return
  fi
  if ! json="$(camera_device_json)"; then
    echo partial
    return
  fi

  raw="$(camera_raw_from_json "$json")"
  if [[ $raw =~ ^[0-9]+$ ]] && (( raw >= CAMERA_TARGET_VERSION_RAW )); then
    echo up-to-date
  else
    # Missing/zero firmware version is treated as old, per the package's known
    # 3009 baseline. No ASUS metadata or "latest version" query is performed.
    echo update-available
  fi
}

module_install() {
  local answer json raw device_id package package_hash archive capsule cap_hash

  if ! camera_is_supported_model; then
    warn "[camera-firmware] this module only supports ASUS $CAMERA_MODEL"
    return 10
  fi

  camera_require_tools
  if ! json="$(camera_device_json)"; then
    warn "[camera-firmware] UEFI firmware target $CAMERA_TARGET_GUID was not found"
    return 10
  fi

  raw="$(camera_raw_from_json "$json")"
  device_id="$(jq -r '.DeviceId' <<<"$json")"
  if [[ $raw =~ ^[0-9]+$ ]] && (( raw >= CAMERA_TARGET_VERSION_RAW )); then
    ok "[camera-firmware] already current: $CAMERA_TARGET_VERSION_HUMAN (raw $raw)"
    return 0
  fi

  printf '%sCamera firmware update available%s\n' "$c_bold" "$c_off"
  printf '  installed ESRT version: %s\n' "${raw:-unknown}"
  printf '  verified target:        %s (raw %s)\n' \
    "$CAMERA_TARGET_VERSION_HUMAN" "$CAMERA_TARGET_VERSION_RAW"
  printf '  package:                ASUS %s, SHA-256 pinned\n' "$CAMERA_PACKAGE_NAME"
  printf 'This stages a signed UEFI capsule and requires a reboot. Continue? [y/N] '
  if [[ ${ASUS_CAMERA_FW_ASSUME_YES:-0} == 1 ]]; then
    answer=y
    echo y
  elif ! IFS= read -r answer; then
    answer=n
  fi
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || return 10

  if ! camera_ac_online; then
    warn "[camera-firmware] connect the AC adapter before staging firmware"
    return 10
  fi

  CAMERA_TMP_DIR="$(mktemp -d -t asus-camera-fw.XXXXXXXX)"
  trap '[[ -n ${CAMERA_TMP_DIR:-} ]] && rm -rf -- "$CAMERA_TMP_DIR"' EXIT

  package="$(camera_find_local_package || true)"
  if [[ -n $package ]]; then
    package_hash="$(sha256sum "$package" | awk '{print $1}')"
    if [[ $package_hash != "$CAMERA_PACKAGE_SHA256" ]]; then
      warn "[camera-firmware] ignoring local package with unexpected SHA-256: $package"
      package=""
    else
      log "[camera-firmware] using verified local package: $package"
    fi
  fi

  if [[ -z $package ]]; then
    package="$CAMERA_TMP_DIR/$CAMERA_PACKAGE_NAME"
    log "[camera-firmware] downloading the fixed, known ASUS 3009 package (no version lookup)"
    curl --fail --location --proto '=https' --tlsv1.2 \
      --output "$package" "$CAMERA_PACKAGE_URL"
    package_hash="$(sha256sum "$package" | awk '{print $1}')"
    [[ $package_hash == "$CAMERA_PACKAGE_SHA256" ]] || \
      die "[camera-firmware] downloaded package SHA-256 mismatch; refusing to flash"
  fi

  archive="$CAMERA_TMP_DIR/camera-payload.7z"
  dd if="$package" of="$archive" iflag=skip_bytes,count_bytes \
    skip="$CAMERA_PAYLOAD_OFFSET" count="$CAMERA_PAYLOAD_SIZE" status=none
  install -d -m 0700 "$CAMERA_TMP_DIR/extracted"
  7z x -y "-o$CAMERA_TMP_DIR/extracted" "$archive" >/dev/null

  capsule="$(find "$CAMERA_TMP_DIR/extracted" -type f \
    -name "$CAMERA_CAPSULE_NAME" -print -quit)"
  [[ -n $capsule ]] || die "[camera-firmware] verified package did not contain $CAMERA_CAPSULE_NAME"
  cap_hash="$(sha256sum "$capsule" | awk '{print $1}')"
  [[ $cap_hash == "$CAMERA_CAPSULE_SHA256" ]] || \
    die "[camera-firmware] capsule SHA-256 mismatch; refusing to flash"

  log "[camera-firmware] staging verified capsule for the next reboot"
  fwupdtool --no-reboot-check --no-device-prompt install-blob \
    "$capsule" "$device_id" "$CAMERA_TARGET_VERSION_RAW"

  ok "[camera-firmware] update staged; reboot to let UEFI install camera firmware $CAMERA_TARGET_VERSION_HUMAN"
}

module_status_extra() {
  local json raw package
  printf '  baseline: %s%s (raw %s); no online latest-version query%s\n' \
    "$c_bold" "$CAMERA_TARGET_VERSION_HUMAN" "$CAMERA_TARGET_VERSION_RAW" "$c_off"

  if ! camera_is_supported_model; then
    printf '  model:    %snot applicable to this computer%s\n' "$c_dim" "$c_off"
    return
  fi

  if json="$(camera_device_json)"; then
    raw="$(camera_raw_from_json "$json")"
    if [[ $raw =~ ^[0-9]+$ ]] && (( raw >= CAMERA_TARGET_VERSION_RAW )); then
      printf '  firmware: %scurrent (ESRT raw %s)%s\n' "$c_ok" "$raw" "$c_off"
    else
      printf '  firmware: %supdate available (ESRT raw %s)%s\n' \
        "$c_warn" "${raw:-unknown}" "$c_off"
    fi
  else
    printf '  firmware: %sUEFI target not visible; install fwupd+jq or inspect ESRT%s\n' \
      "$c_warn" "$c_off"
  fi

  package="$(camera_find_local_package || true)"
  if [[ -n $package ]]; then
    printf '  package:  %slocal ASUS 3009 package found at %s%s\n' \
      "$c_ok" "$package" "$c_off"
  else
    printf '  package:  %sfixed ASUS 3009 artifact downloads only after confirmation%s\n' \
      "$c_dim" "$c_off"
  fi
}
