# Changelog

All notable changes to `workbench-distro` are documented here.

## [Unreleased]

### Added

- **`wb tools install brew`.** Installs Homebrew on macOS and on Linux (x86_64
  and aarch64). Apple Silicon on macOS 15 or later uses Homebrew's signed
  `.pkg`, checked against GitHub's SHA-256 and a pinned Developer ID Team ID.
  Apple Silicon on macOS 11-14 uses Homebrew's `install.sh` with a warning,
  and Intel Macs are refused with Homebrew's reason (its installer stops
  there). On Linux it reports Homebrew's prerequisites, asks once, then runs `install.sh`
  on your terminal. With Homebrew already installed it runs `brew update`, so
  `wb tools upgrade brew` works on a Homebrew you installed yourself.
- **`brew-update [--greedy] [--cleanup]`.** `brew update` then `brew upgrade`,
  as your user, never as root.
- **`distro-update` covers Homebrew.** On Linux it runs `brew-update` after
  Flatpak when Homebrew is installed (`--no-brew` skips it, and a failure
  warns, as Flatpak's does). On macOS it updates Homebrew.

### Changed

- **Needs `workbench-core` 1.14 or later**, which puts Homebrew on `PATH`
  before any module loads.

## [0.2.0] - 2026-11-27

### Added

- **`wb tools install auto-updates` and `distro-auto-updates`.** Turns on the
  distribution's own unattended updates (dnf5 automatic, dnf-automatic,
  unattended-upgrades, os-update) for security updates only or all updates,
  with an optional reboot when needed. Settings go in files workbench creates
  and marks, a rerun keeps the recorded settings, and
  `distro-auto-updates off` undoes only what workbench did.

## [0.1.0] - 2026-11-24

### Added

- **`distro-update`, `distro-upgrade`, `distro-reboot-required` and
  `distro-info`.** One entry point per job, whatever the distribution: the
  family's updater then Flatpak, the release-upgrade command for this ID (or
  "rolling" / "not handled"), a reboot check that never elevates, and the
  facts a bug report needs.
- **`dnf-update` and `fedora-release-upgrade`.** The dotfiles update alias as a
  function, and the Fedora release upgrade: at most two releases ahead, a
  typed `reboot` before the point of no return, a WSL route (stage, then
  follow the journal from Windows), and `--post` for config files and retired
  packages. Reboot detection uses `dnf needs-restarting`.
- **`apt-update` and `debian-release-upgrade`.** Debian's release upgrade
  rewrites only the official archive entries, after a diff and a typed
  `upgrade`, with backups in `/var/backups/workbench-distro/`. Third-party and
  `cdrom:` entries are reported and left alone; `--disable-third-party`
  disables the third-party ones that name the old release.
- **`ubuntu-release-upgrade` and `pop-release-upgrade`.** Interactive wrappers
  around `do-release-upgrade` and `pop-upgrade`.
- **`pacman-update`, `yay-update`, `paru-update`, `zypper-update` and
  `opensuse-release-upgrade`.** On Omarchy the three Arch updaters run
  Omarchy's own updater.
- **`wb tools install dnf-tuning`.** Writes a DNF 5 drop-in with
  `max_parallel_downloads=10` (`DNF_PARALLEL_DOWNLOADS`, `DNF_FASTESTMIRROR`);
  never edits `dnf.conf`.
