# KindleTRMNL

A single-file shell daemon that turns a jailbroken Kindle into a [TRMNL](https://usetrmnl.com)
BYOS (Bring-Your-Own-Server) e-ink dashboard. It periodically fetches a rendered
PNG from your self-hosted BYOS server and displays it full-screen using the
Kindle's native `eips` framebuffer tool — no KOReader or extra runtime required.

## Features

- **Native rendering** — draws directly to the e-ink display via `eips`.
- **Power-aware scheduling** — `always_on`, `deep_sleep`, or `hybrid` modes with
  an active-hours window and RTC wake.
- **Flexible refresh schedule** — fixed clock times (`REFRESH_TIMES`), a fixed
  interval (`REFRESH_INTERVAL`), or the server-suggested `refresh_rate`.
- **Offline resilience** — caches the last image and falls back to it when the
  server or WiFi is unavailable.
- **Battery safety** — shuts down below a configurable threshold when not charging.
- **Auto-detection** — screen resolution, touch input device, wireless interface,
  and firmware version are detected at runtime, so it works across Kindle models.
- **Exit on interaction** — pressing the power button or tapping the screen exits
  cleanly and restores the normal Kindle UI.
- **Optional auto-start** — Upstart job to launch the dashboard on boot.

## Requirements

- A **jailbroken Kindle** with [KUAL](https://www.mobileread.com/forums/showthread.php?t=225030)
  installed.
- A running **TRMNL BYOS server** (e.g. LaraPaper) reachable on your network.
- Standard Kindle tools, all present on stock firmware: `eips`, `curl`, `lipc-*`,
  `grep`, `awk`, `sed`, `wc`, `date`.

## Installation

1. [**Download the latest release**](https://github.com/AshleyThew/KindleTRMNL/archive/refs/heads/master.zip)
   and extract it.

2. Copy the `KindleTRMNL` folder to your Kindle's extensions directory:

   ```
   /mnt/us/extensions/KindleTRMNL/
   ```

3. Edit `config.conf` and set at least `BYOS_URL` and `API_KEY` (see below).

4. Open **KUAL → TRMNL → Start TRMNL**.

### Optional: start automatically on boot

Copy the Upstart job into place (requires a read-write root filesystem):

```sh
cp /mnt/us/extensions/KindleTRMNL/upstart/kindle-trmnl.conf /etc/upstart/
start kindle-trmnl     # start now, or just reboot
```

## Usage

Launch from KUAL:

| Menu item                              | Description                                                                                                    |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| **TRMNL → Start TRMNL**                | Start the dashboard (keeps the Kindle framework running).                                                      |
| **TRMNL → Start TRMNL (no framework)** | Stop the Kindle GUI framework first for maximum framebuffer control. Best for a dedicated always-on dashboard. |

To **exit**, press the power button or tap the screen — the daemon restores the
status bar / framework and returns to the home screen.

## Configuration

All settings live in `config.conf`. Edit the file, then restart from KUAL for
changes to take effect.

| Key                     | Default                   | Description                                                                      |
| ----------------------- | ------------------------- | -------------------------------------------------------------------------------- |
| `BYOS_URL`              | —                         | Your BYOS server URL, no trailing slash. **Required.**                           |
| `API_KEY`               | —                         | Device access token (sent as the `access-token` header). **Required.**           |
| `POWER_MODE`            | `hybrid`                  | `always_on`, `deep_sleep`, or `hybrid`.                                          |
| `ACTIVE_HOURS`          | `07:00-22:00`             | Active window (`HH:MM-HH:MM`) for `hybrid` mode.                                 |
| `REFRESH_TIMES`         | `08:00,12:00,17:00,20:00` | Comma-separated clock times to refresh. Leave empty to use the interval instead. |
| `REFRESH_INTERVAL`      | `900`                     | Seconds between refreshes when `REFRESH_TIMES` is empty.                         |
| `REFRESH_DAYS`          | (all)                     | ISO weekday numbers (`1`=Mon … `7`=Sun). Blank = every day.                      |
| `LOW_BATTERY_THRESHOLD` | `15`                      | Daemon stops below this % when not charging.                                     |
| `DISPLAY_BATTERY`       | `true`                    | Show a battery / last / next status line after each update.                      |
| `BLANK_OUTSIDE_HOURS`   | `false`                   | Blank the screen outside active hours instead of showing the last image.         |
| `PARTIAL_REFRESH`       | `false`                   | Use partial e-ink refresh (faster, may ghost).                                   |
| `QUIT_PROMPT_TIMEOUT`   | `10`                      | Seconds to wait for second tap before dismissing quit prompt.                    |
| `WIFI_TIMEOUT`          | `60`                      | Seconds to wait for WiFi to associate and obtain an IP before falling back to cache. |
| `LOG_MAX_BYTES`         | `524288`                  | Log file rotates above this size (512 KB).                                       |
| `STOP_FRAMEWORK`        | `false`                   | Stop the Kindle GUI framework on start (same as the "no framework" menu item).   |

### Power modes

- **`always_on`** — screen always shows the dashboard; the device never sleeps.
  WiFi is disabled between fetches unless charging.
- **`hybrid`** — active during `ACTIVE_HOURS`; deep-sleeps (RTC wake) outside the
  window to save battery.
- **`deep_sleep`** — suspends to RAM between every refresh for maximum battery life.

On first start the dashboard always displays once immediately, then follows the
configured schedule.

## How it works

1. Enables WiFi and requests `GET {BYOS_URL}/api/display` with the device MAC,
   battery level, and screen dimensions as headers.
2. Parses the JSON response for `image_url` and downloads the PNG into `cache/`.
3. Renders the image full-screen with `eips`, optionally overlaying a status line.
4. Disables WiFi and waits for the next scheduled refresh (or RTC-sleeps).
5. If a fetch fails, falls back to the most recent cached image; after repeated
   failures it shows an on-screen alert.

## Troubleshooting

- **Nothing appears after starting** — check the log via the files below, or the
  on-screen hint pointing to **KUAL → TRMNL**.
- **Logs** — `logs/trmnl.log` (auto-rotated). Includes the detected firmware
  version, screen size, and fetch results.
- **"Config error"** — `BYOS_URL` and/or `API_KEY` are not set in `config.conf`.
- **"Server unreachable"** — verify the BYOS URL is reachable from the Kindle's
  network and the API key matches the device entry on the server.

## Project structure

```
config.conf                 # User settings
config.xml                  # KUAL extension manifest
menu.json                   # KUAL menu (TRMNL submenu)
trmnl.sh                    # Main daemon (single file)
cache/                      # Cached dashboard images
logs/                       # Runtime log (rotated)
upstart/kindle-trmnl.conf   # Optional auto-start job
```

## Disclaimer

This software interacts with low-level Kindle system tools and requires a
jailbroken device. Use at your own risk; the authors are not responsible for any
damage to your device.
