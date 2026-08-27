# ASUS ExpertBook Ultra B9406CAA — Intel BE211 Wi-Fi

The Panther Lake Intel BE211 (`8086:e440`, subsystem `8086:0114`) uses the new
`iwlmld` op-mode. Its 802.11be/EHT path has produced MCS0/NSS1 collapse and MLO
teardown on this laptop, while the 802.11ax/HE path sustains roughly 2.1 Gbit/s
over 160 MHz. The module therefore keeps the narrow, reversible workaround:

```text
options iwlwifi disable_11be=Y
```

That disables Wi-Fi 7/EHT and leaves Wi-Fi 6/HE, normal power management,
Bluetooth coexistence, PCIe ASPM and network offloads alone.

## Linux 7.2 / C106 firmware warning

Linux 7.2 raises Panther Lake's supported Wi-Fi firmware from C102 to C106.
With C106 this machine can log thousands of:

```text
missed beacons exceeds threshold, but receiving data. Stay connected, Expect bugs.
```

The message means the missed-beacon counter crossed the driver's threshold but
frames were still received recently, so the driver deliberately keeps the
connection. On the reference machine the warning occurred with a strong signal,
about 2.1 Gbit/s negotiated rate, no TX failures and no spontaneous disconnect.
It is therefore tracked as a C106 driver/firmware accounting and log-rate issue,
not proof that the HE link failed.

`./patch.sh status wifi-fix` reports:

- whether EHT is disabled;
- the loaded firmware build;
- the current-boot warning count;
- current frequency and signal.

The module does not suppress kernel warnings or rename packaged firmware files.
If real disconnects or throughput loss accompany the messages, a controlled
C102 comparison is useful, but an automatic downgrade would be too invasive.

## Retired broad tunables

Versions before 2.1 also shipped:

- `iwlmld power_scheme=1`;
- global PCIe ASPM `performance`;
- a dispatcher disabling TSO/GSO/GRO.

They did not stop the C106 warning flood on this machine. Global ASPM
`performance` also costs battery life, while disabling all offloads is broader
than the demonstrated EHT problem. Version 2.1 removes those files, restores the
default ASPM policy and re-enables normal offloads.

## Install

```sh
./patch.sh install wifi-fix
sudo reboot
./patch.sh status wifi-fix
```

The reboot is needed because `disable_11be` is set when `iwlwifi` loads.

## Uninstall

```sh
./patch.sh uninstall wifi-fix
sudo reboot
```

Uninstall removes `disable_11be=Y`, allowing EHT again on the next boot.
