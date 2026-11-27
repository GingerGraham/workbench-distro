# workbench-distro

Distro updates, release upgrades, unattended updates and package-manager tuning for the
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
| `wb tools install auto-updates` | Fedora, RHEL family, Debian, Ubuntu, Pop!_OS, SUSE family, with systemd | Turns on the distribution's own unattended updates: security only or all, with an optional reboot. |
| `distro-auto-updates [status\|off]` | Fedora, RHEL family, Debian, Ubuntu, Pop!_OS, SUSE family | Shows what runs unattended updates, with what settings, and when. `off` undoes what workbench did. Exit 0 on, 1 off, 2 unsupported or unknown. |

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

## Unattended updates (`wb tools install auto-updates`)

Turns on the update service your distribution already ships, and writes its
settings to a file workbench creates and marks with a
`Written by workbench-distro (wb tools install auto-updates).` line.

| Host | Service | File workbench writes | Timer |
|---|---|---|---|
| Fedora 41+ (DNF 5) | `dnf5 automatic` (`dnf5-plugin-automatic`) | `/etc/dnf/automatic.conf` | `dnf5-automatic.timer` |
| RHEL, Rocky, AlmaLinux, CentOS Stream (DNF 4) | `dnf-automatic` | `/etc/dnf/automatic-workbench.conf`, and a drop-in `/etc/systemd/system/dnf-automatic.service.d/50-workbench.conf` | `dnf-automatic.timer` |
| Debian, Ubuntu, Pop!_OS | `unattended-upgrades` | `/etc/apt/apt.conf.d/52workbench-auto-updates` | `apt-daily.timer`, `apt-daily-upgrade.timer` |
| openSUSE Leap, Tumbleweed, Slowroll | `os-update` | `/etc/os-update.conf` | `os-update.timer` |

It installs the package if it's missing, writes the file, and enables the
timers that were off. It never edits a file it didn't write: if a file of the
same name exists without the marker, it stops, changes nothing, and prints the
settings to set by hand.

| Variable | Values | Default |
|---|---|---|
| `AUTO_UPDATES_SCOPE` | `security`, `all` | `security` on first install, afterwards what was recorded |
| `AUTO_UPDATES_REBOOT` | `never`, `when-needed` | `never` on first install, afterwards what was recorded |

Each file carries a state line, so a rerun keeps the recorded values unless you
set a variable. A bare `wb tools upgrade auto-updates` never changes the policy.

```sh
wb tools install auto-updates                                   # security only, never reboot
AUTO_UPDATES_SCOPE=all wb tools upgrade auto-updates            # switch to all updates
AUTO_UPDATES_REBOOT=when-needed wb tools upgrade auto-updates   # scope unchanged
```

### What `security` and `all` mean

| Host | `security` | `all` |
|---|---|---|
| Fedora, RHEL family | `upgrade_type = security`: updates whose advisory is marked as a security fix | `upgrade_type = default`: every update |
| Debian | `Debian-Security` origins | Plus the release (point updates) and `-updates` |
| Ubuntu | `-security` pocket and ESM security | Plus the `-updates` pocket and ESM updates |
| Pop!_OS | Ubuntu `-security` and ESM security | Plus Ubuntu `-updates` and Pop's own release repository |
| openSUSE | `security` (`zypper patch --category security`), Leap only | `dup` on Tumbleweed and Slowroll, `up` on Leap |

- `all` means the distribution's own archives. Third-party apt repositories
  (Docker, vendor repositories, PPAs) are never added to the origin list. dnf
  has no such filter: it updates every enabled repository, the same as
  `dnf upgrade`.
- On Fedora, `security` installs updates whose advisory is marked as a
  security fix. Fixes shipped in ordinary bug-fix updates wait until you run
  `distro-update`.
- On Pop!_OS, `security` doesn't cover Pop's own repository (kernel, COSMIC,
  firmware), which has no security pocket. The installer warns about it.

### Reboots

`never` (the default) never reboots; `distro-reboot-required` still reports
when one is due. `when-needed` reboots after an update run that needs it: five
minutes later on dnf and apt (`shutdown -r +5`). `os-update` has no delay
setting: it asks `rebootmgr` when that is running and reboots at once
otherwise. `when-needed` isn't available on WSL, where a reboot stops the
distro and Windows owns the kernel.

### When it runs

On the distribution's own timer schedule: `dnf5-automatic.timer` runs daily
around 06:00 with up to an hour's random delay. That timer is `Persistent`, so
a run missed while the machine was off (or the WSL distro was stopped) happens
at the next start. apt's two timers and `os-update.timer` have their own
schedules. To change the time, override the timer:

```sh
sudo systemctl edit dnf5-automatic.timer   # or dnf-automatic.timer, apt-daily-upgrade.timer, os-update.timer
```

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00
```

GNOME Software and KDE Discover have their own automatic updates. They are
separate; running both is harmless but redundant.

### `distro-auto-updates`

```sh
distro-auto-updates          # same as: distro-auto-updates status
distro-auto-updates off
```

`status` shows the backend and whether its package is installed, who owns the
config file, the scope and reboot setting (from workbench's file), the timer,
its next and last run, and `on` or `off`. It never elevates. Exit 0 when on,
1 when off, 2 when this host has no supported service or `systemctl` can't be
read. On apt, `on` means `APT::Periodic::Unattended-Upgrade` is set and
`apt-daily-upgrade.timer` is enabled, whoever set them: on Ubuntu, the
distribution's own default shows up as `distribution default (20auto-upgrades)`.

`off` disables only the timers workbench enabled and removes only the files
workbench wrote. It leaves behind:

- the package (it prints the command to remove it);
- timers that were already on before workbench, which keep running with the
  package's own settings;
- on Ubuntu, the distribution's own default, which still installs security
  updates. `off` says so and prints
  `sudo dpkg-reconfigure -plow unattended-upgrades`.

### Refused

| Host | Why, and what to use |
|---|---|
| Arch family, including Omarchy | Arch doesn't support unattended upgrades: some updates need manual steps announced on archlinux.org/news. Use `distro-update`. |
| Linux Mint | Update Manager has its own automatic updates. |
| Other Debian derivatives | Their archive origins aren't known to workbench. |
| rpm-ostree (Fedora Atomic) | Set `AutomaticUpdatePolicy=stage` in `/etc/rpm-ostreed.conf` and enable `rpm-ostreed-automatic.timer`, or use the software centre. |
| Containers | Recreate the container from a newer image. |
| No systemd running, including WSL without systemd | Every backend is a systemd timer. On WSL, set `[boot]` `systemd=true` in `/etc/wsl.conf`. |
| WSL with `AUTO_UPDATES_REBOOT=when-needed` | Use `never`. |
| Tumbleweed, Slowroll with `security` | Rolling releases ship fixes as new snapshots, not security patches. Use `all`. |
| CentOS Stream with `security` | Stream publishes no security advisories, so `security` would install nothing. Use `all`. |
| DNF 4 older than 4.15 with `when-needed` | Its `dnf-automatic` can't reboot by itself. Use `never`. |

### Trying it without waiting for the timer

```sh
sudo systemctl start dnf5-automatic.service     # then: journalctl -u dnf5-automatic.service
sudo unattended-upgrade --dry-run --debug       # apt
```

SUSE and DNF 4 have been tested with stand-in commands only, not on a real
host.

## Requires

- `workbench-core` with `CORE_API_VERSION` 1.11 or later (exact-ID distro
  files).
- `curl`, for `debian-release-upgrade`.
- `systemd`, for `wb tools install auto-updates` (every backend is a timer).
- `dnf5-plugins` (DNF 5) or `dnf-plugins-core` (DNF 4), for
  `distro-reboot-required` on Fedora and the rhel family.
