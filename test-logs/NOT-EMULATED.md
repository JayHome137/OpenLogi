# What the offline suite could NOT emulate (2026-10-20, Asia/Shanghai)

- Real Windows PowerShell 5.1 / .NET Framework (closest: pwsh 7.4.6 + PSScriptAnalyzer 1.25.0 compat rules for
  win-48 5.1.17763 Desktop + Pester 6.2.0 under StrictMode Latest). Parse-only 5.1 command prepared, NOT run
  (needs Jay's separate authorization): see tools/PARSE-ONLY-windows.txt.
- Windows cmdlets (ScheduledTasks, NetSecurity, NetTCPIP, CIM, Services, registry HKU): parameterised stubs + Pester Mocks only.
- macOS: launchctl, tccutil, RunningBoard, SMAppService/BTM, Gatekeeper, socketfilterfw, hdiutil, open, PlistBuddy,
  BSD ps/date/stat/sed/awk. Recorded/synthetic dumps in macos/testdata + DRY hooks only. Apple's /bin/bash 3.2 build
  is approximated by GNU bash 3.2.57 compiled from source; shellcheck has no bash-3.2 dialect.
- BSD-tool notes: scripts use only `date +%s` (ms via python3), `ps -axww -o pid= -o ppid= -o command=`, `ps -p -o lstart=`,
  `stat -f%Su /dev/console`, `shasum -a 256`, `awk -F '\t'`, `find -name`; no `sed -i`, `date -d`, `readlink -f`,
  `grep -P`, `timeout`, `stat -c`, `xargs -r`, `mapfile`, associative arrays or `${v,,}` in macos/*.sh.
- inject.swift was not compiled (no swiftc for macOS frameworks on Linux); injection is off by default on the Mac.
- Real hardware: Bluetooth Logitech mouse, LAN between .8/.9, QUIC on UDP 42424, SAS pairing, OpenLogi agent itself.
- Console encoding of Chinese text in PS 5.1 conhost (UTF-8 BOM files are verified; rendering is not).
