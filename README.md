# Darwin25Probe

Automated build and research harness for Darwin 25.6.0 (iOS 18/26, A18 Pro / T8140).

## Features
- **Sandbox File Egress Probe**: Tests `container.sb` enforcement against `/var/containers/Bundle/Application/`.
- **Mach IPC Service Audit**: Tests accessibility of allowed Mach services (`com.apple.FontServicesDaemon`, etc.).
- **IOSurface Method 46 Race (0-Day)**: Multi-threaded race engine targeting Method 46 deserializer and Method 1 release.

## Build
Automated via GitHub Actions on `macos-14` runner with Xcode.
Download the `.ipa` from GitHub Actions artifacts or Releases.
