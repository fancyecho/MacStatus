<p align="center"><img src="docs/icon.png" width="128" alt="Status icon"></p>

# Status

A lightweight native macOS menu bar system monitor built with SwiftUI. It needs no Xcode; Command Line Tools is enough to build it.

![面板](docs/panel-dark.png)

## Download

Download `Status-x.x.dmg` from [Releases](https://github.com/fancyecho/MacStatus/releases/latest), open it, and drag Status into Applications. It's a universal app (Apple Silicon + Intel) and needs macOS 14 or later.

The app isn't notarized by Apple, so the first launch will say it "can't verify the developer". Either:

- open **System Settings → Privacy & Security**, find the note about Status at the bottom, and click **Open Anyway**; or
- run this once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Status.app
```

## Build from source

```bash
./build.sh            # builds into build/Status.app
./build.sh --install  # copies to /Applications and launches it
./build.sh --dmg      # packages build/Status-<version>.dmg
scripts/make-icon.sh  # regenerates the app icon (after editing scripts/make-icon.swift)
```

## Features

- **Menu bar**: CPU, CPU temperature, memory, GPU, network speed and battery, each toggled independently. It is rendered as a template image, so it adapts to light and dark menu bars automatically.
- **Panel**: a frosted-glass panel attached under the menu bar icon. Click the icon to open or close it; clicking elsewhere or pressing Esc also closes it, and ⌘, opens settings. CPU (history curve, per-core bars, temperature), memory (app / wired / compressed / swap breakdown; a badge appears only when memory pressure is high), GPU, disk (free space, read/write speed), network (mirrored up/down chart), battery (health, cycle count, temperature, power draw), and top 5 processes by CPU or memory.
- **Battery details** (click the battery card): time to full (or to the charge limit) / estimated time remaining, power flow (adapter input = computer consumption + power into the battery), computer power history, **apps using the most power** (estimated from the system's per-process CPU energy counters, with helper processes counted toward their app), max capacity / health, cycle count, temperature, voltage, current, and capacity in mAh. The battery turns yellow in Low Power Mode.
- **Menu bar battery icon**: the percentage sits inside the battery, with a bolt beside it while charging and a yellow fill in Low Power Mode.

<p align="center"><img src="docs/battery-icons.png" width="380" alt="Menu bar battery icons"></p>
- **Settings**: refresh interval of 1/2/3/5 seconds, charge limit (Auto follows the system's estimate; manual values only affect the charge-time estimate and don't change actual charging), launch at login.
- **Updates**: checks this repo's GitHub Releases for new versions (at most once a day, only when the panel opens); a new version downloads with one click.

<p align="center"><img src="docs/battery.png" width="380" alt="Battery details (sample data)"><br><sub>Battery details page (sample data)</sub></p>

GPU, battery and temperature hide automatically when the data isn't available (for example in a virtual machine or on a desktop Mac). Temperature reads Apple Silicon's HID temperature sensors (M1/M2 use the pACC/eACC sensors, newer chips use the PMU die temperature); there is no public API for this, so it is loaded dynamically, and if a future system changes it, it simply won't be shown.

## Resource usage

The panel only refreshes the UI while it's open. While closed, only what the menu bar shows is sampled (GPU, disk, and the process list stop sampling). The menu bar icon is drawn directly with Core Graphics and redrawn only when the displayed content changes, and the timer allows the system to coalesce wakeups.

## Debug

```bash
STATUS_SNAPSHOT=/some/dir build/Status.app/Contents/MacOS/Status  # renders the panel to PNGs and exits
STATUS_CHECK_PANEL=1 build/Status.app/Contents/MacOS/Status        # opens the panel, checks position, height stability and click-to-close
STATUS_DEMO=1 build/Status.app/Contents/MacOS/Status              # fills GPU / temperature / battery with simulated data to check layout
/Applications/Status.app/Contents/MacOS/Status --battery-info   # prints the raw battery fields and how they were parsed (no serial numbers)
/Applications/Status.app/Contents/MacOS/Status --check-update   # checks for updates once and prints the result
```
