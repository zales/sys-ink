# Changelog

All notable changes to this project are documented here. Generated from the
release history; keep it updated by hand when tagging a new version.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Breaking changes at a glance

| Version | What changed | What to do |
|---------|--------------|------------|
| Unreleased | Home Assistant discovery derives its identity from `MQTT_CLIENT_ID`, and `MQTT_TOPIC_PREFIX` defaults to it. With the default client id nothing changes. | If you set a custom `MQTT_CLIENT_ID`, the device reappears under new entity IDs. Set `MQTT_TOPIC_PREFIX=sysink` to keep the old state topics, and clear the retained configs under `homeassistant/+/sysink/+/config` to drop the old entities. |
| Unreleased | The service unit sets `ProtectHome=yes`. | `BMP_EXPORT_PATH` and `LOG_FILE_PATH` can no longer point into `/home` or `/root`. |
| 1.5.0 | Network rates became decimal: `kB` now means 1000 bytes, matching the label. Earlier releases divided by 1024. | Displayed and MQTT-published rates read 2.4% higher for the same throughput. Nothing to do unless you have alerts on absolute values. |
| 1.5.0 | The APT repository is signed. | Replace `[trusted=yes]` with `signed-by=`; see the README. The old line keeps working but authenticates nothing. |
| 1.4.0 | The MQTT `internet` entity became a `binary_sensor` with `device_class: connectivity`. | Home Assistant creates a new entity. Clear the retained config at `homeassistant/sensor/sysink/internet/config` to drop the stale `sensor.*` one. |
| 1.4.0 | The bottom status bar was re-proportioned between the signal and uptime slots. | Nothing; purely visual. |
| 1.3.0 | Requires Zig 0.16.0 to build. | Only affects building from source. |

---

## [Unreleased]

### Fixed
- **The internet indicator said "connected" with no network at all.** A
  non-blocking connect that fails on the spot — `ENETUNREACH` when the Wi-Fi or
  the DHCP lease is gone — leaves the socket closed with no pending error, and
  the kernel reports a closed socket as writable. The probe ignored the connect
  return and took that for success, on the panel and in Home Assistant.
- **MQTT could recurse without bound.** Publishing reconnected on its own, and
  connecting publishes discovery, so a broker that dropped the client after
  CONNACK drove connect → discovery → publish → connect until the stack ran
  out. A failed send also never counted towards the reconnect backoff.
- **An MQTT send could freeze the panel.** With a broker that vanished without a
  reset, the send buffer filled after about ten minutes and the next blocking
  send stalled the main loop until TCP gave up. Sends wait at most five seconds
  for room now.
- **Three-digit APT counts overflowed their slot** and left pixels on the panel
  that stayed after the count shrank. The count steps down to smaller fonts,
  and shows `999+` past what fits.
- **The APT count was one too high under a non-English locale**, because apt
  translates the header the parser skipped by name. The parser counts
  `name/suite` lines only, and apt runs in the C locale.
- **armhf releases crashed on the Pi Zero, Zero W and Pi 1.** They were built
  for ARMv7, and those boards are ARMv6. They are built for the ARM1176 now,
  which runs on every 32-bit Pi. Cross-compiled, not yet run on an ARMv6 board.
- **Network traffic was counted two or three times over on hosts running
  Docker**, once per veth, bridge and physical interface it crossed. Only
  hardware-backed interfaces are counted now.
- A missing sensor was reported as a reading of zero: "0°C" for the disk on
  every Pi without NVMe, "0" RPM with no fan, and the same values published to
  Home Assistant. The panel shows a dash and MQTT publishes nothing.
- A failed temperature reading hid the CPU load beside it, and the disk
  temperature the usage. Each slot is read and drawn on its own.
- The panel's reachability icon was redrawn only every `INTERVAL_SLOW`, while
  MQTT probed up to once a minute, so the two could disagree for hours. The IP
  address was on the slow tick too, and after the address was lost MQTT kept
  publishing the old one.
- Two panels on one broker overwrote each other's Home Assistant entities: the
  discovery identity was hard-coded. See the breaking-changes table.
- Descriptors were inherited by `apt` and its hooks: the SPI device, the wake
  pipe and the MQTT socket among them. `MQTT_PASSWORD` was passed to them in the
  environment as well.
- A log file that could not be opened stopped the daemon from starting. Logging
  falls back to stderr.

### Added
- Home Assistant entities expire after three `INTERVAL_FAST` periods without an
  update, so a panel that is switched off does not keep showing its last
  readings as current.
- Numeric sensors carry `state_class: measurement`, which gives them long-term
  statistics in Home Assistant.
- The `.deb` ships a logrotate entry for the default log path. The log file is
  written in append mode so rotation works under a running daemon, and its lines
  carry a UTC date.

### Changed
- The service unit is sandboxed where that costs nothing: no access to home
  directories, no writes to kernel tunables or cgroups, no module loading, no new
  privileges. Devices, `/var` and `/tmp` stay reachable.
- The IP address is read every `INTERVAL_FAST` instead of every `INTERVAL_SLOW`.

## [1.7.0] — 2026-09-20

### Added
- Desktop panel simulator. The real renderer runs against a recorder instead of
  hardware, so what it shows is what the panel would show — same fonts, same
  layout constants, same fault overlay. `zig build sim` opens a native window on
  macOS; everywhere else it serves the frame over HTTP, as does `zig build
  sim-web`.
- Optional web preview of the live panel, behind `WEB_PREVIEW=true`. It serves
  the frame the daemon actually drew rather than a re-render, so it cannot
  disagree with the glass. Binds loopback by default: the frame carries the
  host's addresses and load figures, and there is no authentication. See the
  README before setting `WEB_PREVIEW_ADDR`.

### Fixed
- **A stalled peer panicked the daemon instead of timing out.** The read
  deadline added in 1.6.0 was implemented with `SO_RCVTIMEO`, which makes a
  timed-out read report `EAGAIN` — and `Io.Threaded` treats `EAGAIN` on a
  blocking socket as a programmer bug, panicking in a Debug build and returning
  `error.Unexpected` in a release one. The preview hang was therefore replaced
  by a crash, invisible only because the shipped binary is ReleaseSmall. MQTT
  carried the same trap on the broker socket, where a broker that accepts the
  connection and then goes quiet would take a Debug daemon down. Both paths now
  take their deadline from the runtime via `Socket.receiveTimeout`.
- The traffic sample and the instant it was measured at could move
  independently, because the byte counters were advanced from a `defer` that
  also ran on the early return taken for two samples inside one second. The next
  interval then reported a rate quietly below the truth. Not reachable through
  the scheduler, which clamps intervals to a second, but the two are written
  together now.
- The test transport's command recorder wrote into a caller-supplied buffer
  without bounds. A wake plus a partial update logs 31 commands against the 64
  it was given.
- The live panel preview was captioned "Simulator", inviting a real reading to
  be dismissed as a mock-up.
- The macOS simulator window sat on its first frame, and both simulators grew
  without bound by keeping a heap copy of every frame ever sent.

### Changed
- Release builds are link-time optimised: 401152 to 362000 bytes on
  `aarch64-linux-musl` with `ReleaseSmall`, for no change in behaviour.
- `zig build` on a non-Linux host now says the daemon is Linux-only and gives
  the cross-compile command, instead of failing with a signal-handler enum
  mismatch four pages long.
- MQTT publishes the readings the display tasks already took, rather than
  re-reading `/proc/uptime`, `/proc/net/wireless` and the whole interface list
  for values that were guaranteed to match. The interface list is also walked
  once rather than up to three times, and hardware with no NVMe temperature
  sensor is no longer rescanned every cycle.

### Security
- `/etc/default/sys-ink` ships as mode 0640. It contains `MQTT_PASSWORD` and the
  service runs as root, so no other account needs to read it. Upgrading tightens
  the mode; anything reading that file as a non-root user will need adjusting.

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

[1.7.0]: https://github.com/zales/sys-ink/releases/tag/v1.7.0
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
