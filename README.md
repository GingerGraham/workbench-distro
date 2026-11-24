# workbench-distro

Distro updates, release upgrades and package-manager tuning for the
[`workbench`](https://github.com/GingerGraham/workbench-core) ecosystem.

An **ecosystem module**: meaningless standalone. It needs `workbench-core`
installed first.

```sh
wb add distro
# or, as part of a bundle:
wb install --bundle workstation
```

## What this module does

One set of commands for each distribution family. A command that can't work
on this host is listed under "available once tooling is installed", with the
reason, by `get-distro-functions` and `wb functions`.

| Command | Loads on | Does |
|---|---|---|
| `distro-update [--no-flatpak]` | every Linux host | Runs this family's updater, then `flatpak update` if Flatpak is installed, then says whether a reboot is recommended. |
| `distro-upgrade [<target>]` | every Linux host | Calls this distribution's release-upgrade command. Says so on rolling releases. |
| `distro-reboot-required` | every Linux host | Exit 0 when a reboot is recommended, 1 when not, 2 when it can't tell. |
| `distro-info` | every Linux host | Family, ID, version, WSL, container, rpm-ostree and DNF generation, for bug reports. |
| `dnf-update [--ask] [--clean]` | Fedora, RHEL family | `dnf upgrade --refresh`, then `dnf autoremove`. |
| `fedora-release-upgrade <N>` / `--post [--from <N>]` | Fedora | The release upgrade, with a WSL route and post-upgrade clean-up. |
| `apt-update [--ask] [--full]` | Debian family | `apt-get update`, `upgrade` (or `full-upgrade`), `autoremove`, `autoclean`. |
| `debian-release-upgrade <codename\|number> [--disable-third-party]` | Debian | Backs up and rewrites the official apt sources, then runs the documented upgrade. |
| `ubuntu-release-upgrade [<version>]` | Ubuntu | Wraps `do-release-upgrade`, interactively. |
| `pop-release-upgrade` | Pop!_OS | Wraps `pop-upgrade`. |
| `pacman-update`, `yay-update`, `paru-update` | Arch family | Updates. On Omarchy all three run Omarchy's own updater. |
| `zypper-update [--ask] [--clean]` | SUSE family | `zypper dup` on Tumbleweed and Slowroll, `zypper update` on Leap. |
| `opensuse-release-upgrade [--dry-run]` | openSUSE Leap | Wraps `opensuse-migration-tool`. |
| `wb tools install dnf-tuning` | Fedora, RHEL family, DNF 5 | Writes `/etc/dnf/libdnf5.conf.d/50-workbench.conf`. |

The routine `*-update` commands run without asking, as the dotfiles aliases
they replace did. `--ask` turns that off. Release upgrades always need a
terminal and a typed word before the step that can't be undone.

## What this module does NOT do

- Major-version upgrades of RHEL, Rocky, AlmaLinux and CentOS Stream
  (Leapp/ELevate), SLES, and Fedora Atomic rebases. `distro-upgrade` says so
  on those hosts.
- `yum`-only hosts.
- Release upgrades inside a container, or on an rpm-ostree host. Updates run
  in containers; both are refused on rpm-ostree, with the `rpm-ostree` command
  to use.
- Edit your `/etc/dnf/dnf.conf`.

## Shell functions

```sh
distro-update                 # everything this host updates with, then Flatpak
distro-update --no-flatpak
distro-upgrade 45             # on Fedora: fedora-release-upgrade 45
distro-reboot-required && echo "reboot"
distro-info                   # paste this into a bug report

dnf-update --ask              # confirm each step
apt-update --full             # full-upgrade instead of upgrade
pacman-update
zypper-update --clean
```

`distro-reboot-required` never elevates. On Fedora and the rest of the rhel
family it runs `dnf needs-restarting` as you: running it under `sudo` is
unreliable on DNF 5. Fedora doesn't create `/var/run/reboot-required`; that
file is a Debian and Ubuntu convention. If `dnf needs-restarting` is missing
the command exits 2 and names the package (`dnf5-plugins` on DNF 5,
`dnf-plugins-core` on DNF 4).

### Fedora

```sh
fedora-release-upgrade 45
fedora-release-upgrade --post
```

At most two releases ahead, never backwards. It brings the current release up
to date, stops if that needs a reboot, downloads the new release, and asks you
to type `reboot`. If you don't, the download is kept and the commands to
reboot later or clean up are printed.

`--post` reads the release you came from, installs `rpmconf` and
`remove-retired-packages`, runs both, and lists duplicate packages and
packages no repository provides. It never removes those two lists for you.
On DNF 5, `dnf remove --duplicates` isn't supported, and `--post` says so
instead of printing a command that fails.

**WSL.** The offline upgrade is staged as usual, but WSL doesn't restart. It
runs as `dnf5-offline-transaction` the next time the distro starts, and WSL
stops an idle distro about 15 seconds after the last session closes, which
interrupts the upgrade part-way. So:

1. Back up before staging. The download is kept, so you can stop, back up and
   re-run. From PowerShell: `wsl --terminate <name>`, then
   `wsl --export <name> C:\wsl\<name>-fedora-<release>.tar`.
2. Type `stage` to stage it.
3. From PowerShell: `wsl --terminate <name>`, then
   `wsl -d <name> -u root -- journalctl -f -o cat -u dnf5-offline-transaction`.
   Keep that window open and don't let Windows sleep. It returns when the
   upgrade finishes.
4. Inside the distro: `fedora-release-upgrade --post`.

It needs DNF 5 and systemd (`[boot]` and `systemd=true` in `/etc/wsl.conf`).
`dnf distro-sync --releasever=N` is not offered: it isn't a supported method
and failed in testing.

### Debian

```sh
debian-release-upgrade trixie
debian-release-upgrade 13 --disable-third-party
```

The target must be the next release and already `stable`: it fetches
`dists/<name>/Release` from your official archive and refuses unless
`Suite: stable`. Before release day the suite reads `testing`.

What it rewrites, in `/etc/apt/sources.list`, `sources.list.d/*.list` and
`sources.list.d/*.sources`:

- **Official entries only.** Every URI is `http` or `https`, and its path is
  `/debian` or `/debian-security`, or the same behind a caching proxy
  (`http://cache:3142/deb.debian.org/debian`). `<old>`, `<old>-updates`,
  `<old>-security`, `<old>-backports` and `<old>-proposed-updates` move to the
  same name on `<new>`. A path that merely ends in `/debian`, such as
  `download.docker.com/linux/debian`, is a vendor, not the archive.
- **Third-party entries naming the old release are left unchanged and
  reported.** `--disable-third-party` disables them instead: `Enabled: no` in a
  deb822 stanza, or a `# disabled by workbench-distro (...)` comment prefix on
  a one-line entry. They are never rewritten, because a vendor may not publish
  the new release on release day.
- `cdrom:` entries are never changed. `stable` and `oldstable` entries follow
  the archive on their own and are reported.
- Comments, blank lines, spacing, options and inline key blocks are kept byte
  for byte.

It shows a `diff -u` of every changed file and asks you to type `upgrade`.
Backups and a `RESTORE.txt` with the exact `cp` commands go to
`/var/backups/workbench-distro/apt-sources-<old>-to-<new>-<UTC time>/`. Then
it runs `apt-get update`, `apt-get upgrade` and `apt-get full-upgrade`
interactively, so dpkg can ask about config files. If a step fails it does
**not** restore the old sources (that makes a half-upgraded system worse). It
prints the restore commands and how to resume instead.

An SSH session outside `tmux` or `screen` gets a warning: a dropped
connection mid-upgrade is the commonest way to break one.

### Arch and Omarchy

`yay-update` and `paru-update` update the AUR packages you installed yourself,
so they don't check `WORKBENCH_ALLOW_AUR`, which governs installers adding AUR
packages.

On Omarchy, a plain `pacman -Syu` can skip the configuration migrations
Omarchy runs. `pacman-update`, `yay-update` and `paru-update` each say they are
handing over and run Omarchy's updater instead.

### SUSE

The openSUSE update path is tested in a container only. `opensuse-release-upgrade`
is untested on a real host.

## `wb tools install dnf-tuning`

Writes `/etc/dnf/libdnf5.conf.d/50-workbench.conf` on DNF 5:

```ini
[main]
max_parallel_downloads=10
```

| Variable | Default | Meaning |
|---|---|---|
| `DNF_PARALLEL_DOWNLOADS` | `10` | Whole number from 1 to 20. DNF 5 defaults to 3. |
| `DNF_FASTESTMIRROR` | `false` | `true` adds `fastestmirror=True`. |

```sh
DNF_PARALLEL_DOWNLOADS=6 wb tools install dnf-tuning
DNF_PARALLEL_DOWNLOADS=6 wb tools upgrade dnf-tuning
```

`fastestmirror` stays off unless you ask: it picks the lowest-latency mirror,
not the fastest, and Fedora's metalink already orders mirrors by location.
`deltarpm` is left out because Fedora stopped producing delta RPMs.

It never edits `/etc/dnf/dnf.conf`, which dnf reads after the drop-ins. A value
you set there wins, and the installer warns when it sees one. Re-running it
rewrites the file only when the values changed. On DNF 4 it prints the
`dnf config-manager --save --setopt=max_parallel_downloads=<n>` line to run
yourself. It refuses on rpm-ostree hosts.

To remove it:

```sh
sudo rm /etc/dnf/libdnf5.conf.d/50-workbench.conf
```

## Requires

- `workbench-core` with `CORE_API_VERSION` 1.11 or later (exact-ID distro
  files).
- `curl`, for `debian-release-upgrade`.
- `dnf5-plugins` (DNF 5) or `dnf-plugins-core` (DNF 4), for
  `distro-reboot-required` on Fedora and the rhel family.
