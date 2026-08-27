# Camera firmware 3009

This module compares the B9406CAA camera's UEFI ESRT entry against the known,
verified ASUS **3009 / 10.1.2.3009** baseline. It does not query ASUS metadata
or guess what the latest release is.

```sh
./patch.sh status camera-firmware
./patch.sh install camera-firmware
```

If the ESRT raw version is below `479569` (or has no usable version), install
prints the installed and target versions and asks for confirmation. Only after
confirmation it uses a matching local package, or downloads the fixed ASUS
3009 artifact. Both layers are pinned before staging:

- ASUS EXE SHA-256: `7a14843f4e86b5d9d775639f73ffc652948776efc67d3174596df2884a4e2065`
- UEFI capsule SHA-256: `2ce9d32f9db8a9f0d9a553d4a6723e66901070a1a741920c1e63c8c5480fa2f8`
- ESRT GUID: `d9d10946-36c2-3bcb-bffc-fcda56025390`

The Windows updater is never executed. The script extracts its signed capsule
and stages it through `fwupd`; UEFI applies it on the next reboot. Keep the AC
adapter connected and do not interrupt that reboot.

The ASUS package is not redistributed by this repository. To use an already
downloaded copy, leave `ASUS_B9406CAA_3009_Camera_FW_Update.exe` on Desktop or
Downloads, place it in this folder, or set `ASUS_CAMERA_FW_EXE=/path/to/file`.
