# Changelog

All notable changes to `workbench-distro` are documented here.

## [Unreleased]

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
