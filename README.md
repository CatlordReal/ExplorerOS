<img src="img/logo.png" height=120 width=120>

# ExplorerOS
Completely free custom ROM for Google Glass **Explorer Edition**

## Apple companion fork

This fork adds an API 19 iPhone service to ExplorerOS, a Swift iPhone companion, a portable native Mac installer, and a Python/Qt simulated Glass endpoint. The derived firmware preinstalls a service implementing boot startup and automatic incoming cards after one-time pairing; physical Glass behavior remains untested. The build adds an APK to the system tar and updates its checksum. Original system members and other ZIP payloads remain byte-identical to the input archive; a full CWM restore can still overwrite device partitions and personal data.

Start with [Apple setup and build instructions](docs/APPLE.md), [firmware integration](docs/FIRMWARE-INTEGRATION.md), [portable Mac package](docs/PORTABLE-MAC.md), [Glass setup](docs/GLASS.md), and [simulator](docs/SIMULATOR.md). [Current validation](docs/VALIDATION.md) and [hardware verification](docs/HARDWARE.md) distinguish tested software from unverified Glass hardware behavior.

The service can also be installed or updated as an APK on an existing compatible system. The optional derived firmware remains a CWM recovery backup and requires a manual restore; see [UPSTREAM-INSTALLER.md](docs/UPSTREAM-INSTALLER.md). The Mac app bundles the service, USB tools, firmware, checksums, and instructions for personal transfer. Its raw-partition planner is read-only; all raw firmware execution is disabled. It cannot install CWM backups. No physical Glass writes or flashing validation have been performed. Do not substitute guessed images, partitions, or recovery commands.

Notifications and media use Glass-side ANCS/AMS GATT clients. The iPhone app cannot read other apps' notifications or global Siri transcripts. A guarded Camera-button adapter requests Siri through the existing stock Glass HFP/SCO service while a companion card is open. Actual Siri playback and microphone operation require real-device testing; the original launcher's Camera binding is unchanged. The guarded adapter also supports ordinary APK installs on the audited stock system. "Hey Siri" wake-word detection and photo/video sync are not implemented. See [headset research](docs/FEASIBILITY-HFP.md) and [capability research](docs/FEASIBILITY.md).

The companion supports MapKit route steps, App Intents, local Quick Notes, phone status, calendar/reminder cards, and Glass requests for Focus, silent-mode, and Notes shortcuts. Signed Weather, Recognize Music, and Browse Notes presets return selected text to a draft for sending to Glass. Shortcut imports and Glass requests require review on iPhone. Mail integration is excluded because inbox reading on Glass is unavailable. Arbitrary dictated replies to other apps' notifications are not exposed by the public APIs used here. See [integrations](docs/INTEGRATIONS.md).

# Introduction

I made this custom ROM to bring Google Glass back to life after more than 13 years. It's based on the latest XE24, with some optimization tweaks from me, plus a completely new launcher.

# Features

- XE apps support (like GlassTube)
- Updated certificates
- Brand new launcher
- Gemini integration
- Improved battery life
- Modern design

# Builds

| Title | Version | Channel | Download | Info
|-------| --------|--------|---------|---------|
| ExplorerOS 26.0 Public Beta 1 | 26.0 (26PB1) | Stable Beta | [Download](https://drive.google.com/drive/folders/1sthRXSZ63CTTSfoUvg8625V3FmW4pmbe?usp=sharing) | Very old, Install Public Beta 2 |
| ExplorerOS 26.0 Public Beta 2 | 26.0 (26PB7) | Stable Beta | [Download](https://drive.google.com/drive/folders/1sthRXSZ63CTTSfoUvg8625V3FmW4pmbe?usp=sharing) | New Design |
| ExplorerOS 26.0 Public Beta 3 | 26.0 (26PB8) | Stable Beta | [Download](https://drive.google.com/drive/folders/1sthRXSZ63CTTSfoUvg8625V3FmW4pmbe?usp=sharing) | New Live Activities |

# Installation (currently Windows only)


> [!WARNING]
> Make sure there are no spaces in the path to the firmware, sometimes ADB incorrectly sends folders that contain spaces

### **Before installing**: see "Post-install"

1. Download this repository
2. Download an ExplorerOS build from "Builds"
3. Install ADB & Fastboot drivers (you can use my other tool - Glassy)
4. Unpack the ExplorerOS build into the ``builds/ExplorerOS-<version>`` folder
5. Enable USB Debugging on your Glass
6. Connect your Glass to the PC and run **ExplorerFlasher.exe**



# Post-install

1. Go to [Weather API](https://www.weatherapi.com) and get your API Key (free)
2. Go to [News API](https://www.newsapi.org) and get your API Key (free)
3. Go to [Open Router](https://openrouter.ai), add $5 to your balance, and get your API Key (paid)
4. To use AI, you need a Python Flask server. If you don't want to set it up, you can use my server instead.

# Server Setup

> [!TIP]
> If you don't want to buy a server, you can use my server completely free

1. Install Python on your Linux Server
2. Run: ``pip3 install flask requests`` (if you have any errors, add ``--break-system-packages``)
3. Download ``server/server.py`` on your server and run it: ``python3 server.py``

# Support

We have a discord server! [Join ExplorerOS Discord Server](https://discord.gg/DSkWE3JjG)


# System itself

##### Home Page and Standby:

<img src="img/screenshot1.png" width=320 height=180>

- Tap once to exit Standby Mode
- Press CAMERA Button to activate Gemini

<img src="img/screenshot2.png" width=320 height=180>

- Switch between pages using Touchpad

#### Widgets Page:

<img src="img/screenshot3.png" width=320 height=180>

- Tap once to show more
- Use Touchpad to scroll

<img src="img/screenshot4.png" width=320 height=180>


##### Gemini Demo:

<img src="img/screenshot6.png" width=320 height=180>

- Press the Camera button to close Gemini
