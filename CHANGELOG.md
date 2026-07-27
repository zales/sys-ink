# Changelog

All notable changes to this project are documented here. Generated from the
release history; keep it updated by hand when tagging a new version.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Breaking changes at a glance

| Version | What changed | What to do |
|---------|--------------|------------|
| 1.5.0 | Network rates became decimal: `kB` now means 1000 bytes, matching the label. Earlier releases divided by 1024. | Displayed and MQTT-published rates read 2.4% higher for the same throughput. Nothing to do unless you have alerts on absolute values. |
| 1.5.0 | The APT repository is signed. | Replace `[trusted=yes]` with `signed-by=`; see the README. The old line keeps working but authenticates nothing. |
| 1.4.0 | The MQTT `internet` entity became a `binary_sensor` with `device_class: connectivity`. | Home Assistant creates a new entity. Clear the retained config at `homeassistant/sensor/sysink/internet/config` to drop the stale `sensor.*` one. |
| 1.4.0 | The bottom status bar was re-proportioned between the signal and uptime slots. | Nothing; purely visual. |
| 1.3.0 | Requires Zig 0.16.0 to build. | Only affects building from source. |

---

## [Unreleased]

### Added
- Under-voltage warning: read from the `rpi_volt` hwmon alarm, shown as an
  inverted status bar and published as an MQTT problem entity.
- NVMe SMART monitoring: the drive's critical-warning bits, read via the admin
  ioctl with no external tools, surfaced the same three ways, plus an SSD wear
  sensor. Requires root; unprivileged runs disable it silently.

## [1.6.0] — 2026-07-27

### Added
- Under-voltage warning. The Pi's `rpi_volt` hwmon sensor is polled, and a
  brown-out inverts the panel's status bar and raises a Home Assistant
  `binary_sensor` with `device_class: problem`. On hardware without the sensor
  the feature disables itself with a log line.
- NVMe SMART critical warnings. The SMART/Health log page is read directly via
  the admin-command ioctl — no `smartctl` dependency — and any critical warning
  bit (spare capacity, temperature, reliability, read-only, volatile-memory
  backup) raises the same panel and MQTT fault indications. SSD wear percentage
  is published as its own sensor.
- The fault overlay is part of the rendered frame, so the BMP export shows it
  too.

### Fixed
- **Raw syscall failures were silently ignored.** Every raw syscall checked its
  result with `std.posix.errno`, which under a libc-linked build reads libc's
  `errno` variable — one that raw syscalls never set — and so reported success
  unconditionally. Eight sites were affected: the GPIO ioctls, SPI configuration
  and writes, the interrupted-sleep retry, the wake pipe, and the NVMe admin
  command. The visible symptom: on a machine without an NVMe drive the daemon
  decoded a SMART "critical warning" out of an uninitialised buffer and raised
  a fault for a disk that does not exist. Error checks now apply the kernel's
  return convention, with tests pinning the boundary.
- The SMART page buffer is zeroed before the ioctl, so a partially completed
  command cannot be read as drive health.

## [1.5.0] — 2026-07-25

### Added
- Golden-image test: the renderer draws a screen with fixed values and compares
  the packed frame against a checked-in reference, pinning the whole layout at
  once. Regenerate with `zig build golden` after an intentional change.
- Test coverage for the panel power state machine, the panel driver's command
  sequences, and a check that no declared text area extends past the panel.
- The APT repository is signed, and CI verifies the signature before publishing.
- `PanelSpec`: panel dimensions and waveforms are a driver parameter rather than
  module constants, so a second panel is a spec instead of a fork. Only the
  verified 2.9" V2 is provided.

### Changed
- **Network rates are decimal.** `kB` is 1000 bytes, matching the SI prefix and
  the convention for throughput; earlier releases divided by 1024 under the same
  label. Affects both the display and MQTT.
- GPIO moved from the v1 character device ABI, deprecated since Linux 5.10, to
  v2. Electrical behaviour is unchanged. ioctl request numbers are derived from
  struct sizes rather than written out as literals.
- The APT check runs as an `Io.concurrent` task instead of a detached thread, so
  shutdown waits for it properly rather than polling and hoping.
- The panel driver and renderer are generic over their transport, which is what
  makes them testable without hardware.
- Buffer sizes are enforced by the type system: the driver takes frames as a
  pointer to a fixed-size array instead of slicing a slice unchecked.

### Fixed
- Network rates between 1000 and 1023 were clipped at the right edge of the
  panel. The traffic slots also declared themselves wider than the panel is.
- The MQTT connect had no timeout. A broker host dropping SYNs rather than
  refusing them blocked the render loop for the kernel's SYN timeout, roughly two
  minutes.
- The periodic full refresh left the partial-update reference frame stale, so
  subsequent partial updates diffed against something not on the glass.
- Uniform ownership for the cached sysfs paths; one of three aliased a static
  string while the others were heap copies.

## [1.4.2] — 2026-07-25

### Changed
- Buffer size invariants are enforced rather than relied upon. Five places were
  correct only because every caller happened to pass the right length, which
  release builds do not check. Glyph reads are now bounded by the data instead of
  by metadata, verified pixel-identical across all 525 glyphs.

## [1.4.1] — 2026-07-25

### Added
- The panel is parked in deep sleep between refreshes, which Waveshare advises
  over leaving it driven continuously. Cycles where nothing changed cost nothing.
  Set `PANEL_SLEEP=false` to keep the controller powered.

### Fixed
- Uptime was clipped mid-glyph from ten days on; the slot ends at the panel edge.

## [1.4.0] — 2026-07-25

### Added
- Unit test suite (0 to 66 tests) and a `zig build check` step that type-checks
  the Linux-only modules.
- `SPI_DEVICE`, `INTERVAL_FULL_REFRESH`, `INTERNET_CHECK_IP` and
  `INTERNET_CHECK_PORT` configuration. `SPI_DEVICE` was documented but never read.
- GPIO chip auto-detection covers Pi 3 and Pi 4 labels, not just Pi 5.

### Changed
- The MQTT `internet` entity is a `binary_sensor` with
  `device_class: connectivity`.
- Home Assistant discovery is republished on every successful connect, so a Pi
  that boots faster than its broker still appears in Home Assistant.
- MQTT keep alive is 0, disabling the broker's inactivity timeout. This client
  only publishes and cannot answer PINGREQ deadlines, so a nonzero value made the
  broker drop it silently whenever the publish interval exceeded it.
- The panel is put into deep sleep on shutdown, as Waveshare requires before
  power is cut.
- Scheduling and traffic rates use the monotonic clock, so NTP steps cannot stall
  tasks or fabricate a rate.
- The APT check no longer blocks startup for up to 40 seconds.
- Default panic handler replaced with a minimal one, removing the ELF and DWARF
  parsing linked into a binary that ships stripped.
- Fonts moved from runtime hash maps to comptime tables.

### Fixed
- `LOG_LEVEL=DEBUG` did nothing in release builds: `std.log`'s comptime threshold
  defaults to `.info` outside Debug, compiling every debug call away.
- Disk usage was computed through a hand-rolled `statvfs` whose layout is wrong on
  32-bit ARM, so armhf builds read garbage. Now uses `statfs` from the target
  libc, and rounds like `df`.
- The SPI `open` return value was cast rather than checked, turning a negative
  errno into a bogus descriptor and hiding the real failure.
- GPIO and SPI descriptors were closed twice when initialisation failed partway.
- `prerm` aborted package removal when the service was already stopped.
- APT count no longer shows the "up to date" tick before any check has run.

## [1.3.1] — 2026-04-15

### Fixed
- MQTT hostname resolution uses libc `getaddrinfo`, so `.local` names resolve
  through nss-mdns.

## [1.3.0] — 2026-04-15

### Changed
- Requires Zig 0.16.0. The README kept claiming 0.15 until 1.4.0; the code and CI
  moved here.
- GPIO chip is auto-detected by label instead of assuming `/dev/gpiochip0`.

## [1.2.0] — 2026-02-07

### Changed
- EPD driver optimisations, memory leak fixes and cross-compilation improvements.

## [1.1.1] — 2026-01-05

### Fixed
- CPU load reported on the display and over MQTT no longer disagree.

## [1.1.0] — 2026-01-04

### Added
- MQTT publishing with Home Assistant auto-discovery.

### Fixed
- MQTT traffic reported consistently in KB/s.
- MQTT reconnect failures log at warning level rather than error.

## [1.0.10] — 2026-01-04

### Added
- GitHub Pages landing page, included in the APT repository deployment.

### Fixed
- APT update detection, and a memory leak.
- Temperature display includes the degree symbol.

## [1.0.8] — 2025-12-21

### Added
- Structured logging with optional file output.

### Fixed
- Shorter e-Paper busy polling interval and fewer SPI transfers per frame.

## [1.0.3] — 2025-12-20

### Added
- Automated Debian repository generation in CI, with a full `Release` file.
- Background APT update checking with atomic state management.
- `conffiles` so packaging no longer overwrites local configuration.

## [1.0.0] — 2025-12-19

### Added
- First release: Waveshare 2.9" e-Paper support, font generation tool, display
  layout, CPU and NVMe temperature path caching, and a release workflow.

[1.6.0]: https://github.com/zales/sys-ink/releases/tag/v1.6.0
[1.5.0]: https://github.com/zales/sys-ink/releases/tag/v1.5.0
[1.4.2]: https://github.com/zales/sys-ink/releases/tag/v1.4.2
[1.4.1]: https://github.com/zales/sys-ink/releases/tag/v1.4.1
[1.4.0]: https://github.com/zales/sys-ink/releases/tag/v1.4.0
[1.3.1]: https://github.com/zales/sys-ink/releases/tag/v1.3.1
[1.3.0]: https://github.com/zales/sys-ink/releases/tag/v1.3.0
[1.2.0]: https://github.com/zales/sys-ink/releases/tag/v1.2.0
[1.1.1]: https://github.com/zales/sys-ink/releases/tag/v1.1.1
[1.1.0]: https://github.com/zales/sys-ink/releases/tag/v1.1.0
[1.0.10]: https://github.com/zales/sys-ink/releases/tag/v1.0.10
[1.0.8]: https://github.com/zales/sys-ink/releases/tag/v1.0.8
[1.0.3]: https://github.com/zales/sys-ink/releases/tag/v1.0.3
[1.0.0]: https://github.com/zales/sys-ink/releases/tag/v1.0.0
