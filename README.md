# Twitch Streamlink GUI

A portable, high-fidelity Windows desktop application built in Flutter to manage Twitch channels, view live statistics using **DecAPI**, and launch feeds directly in **Streamlink** with custom player configurations.

---

## 🚀 Quick Start (For Non-Technical Users)

To start watching Twitch streams ad-free with low-latency and custom players, follow these 3 simple steps:

### 1. Download the Required Software
*   **Twitch Streamlink GUI (This App):** **[Download Latest Portable Zip](https://github.com/MohsenBlur/streamlink-gui/releases/download/v1.0.0/streamlink-gui-win-x64.zip)**
*   **Streamlink (Required Backend):** **[Download Streamlink Installer](https://github.com/streamlink/streamlink/releases)** (Get the `.exe` installer for Windows)
*   **VLC Media Player (Recommended Player):** **[Download VLC Player](https://www.videolan.org/vlc/)**

### 2. Install & Run
1.  Double-click the **Streamlink** installer and **VLC** installer you downloaded, and follow the setup wizard instructions.
2.  Extract the downloaded **Twitch Streamlink GUI** zip file into a folder of your choice.
3.  Open the extracted folder and double-click **`streamlink_gui.exe`** to launch the dashboard.

### 3. Start Watching
*   Add channels in the sidebar (e.g. type `limmy` or your favorite streamer, and click `+`).
*   Click the **Settings gear icon** in the top left, select **Force VLC Player** as your player selection, and click **Save Changes**.
*   Select your channel and click **Launch Streamlink** to open the feed in VLC!

---

## Key Features

*   **100% Portable & Self-Contained:** Uses a project-isolated local Flutter SDK environment (functioning like a python `venv`). No global Flutter/Dart installation is required.
*   **DecAPI Live Statistics:** Fetches and displays real-time statistics from DecAPI for each saved channel:
    *   Channel Live Status (LIVE / OFFLINE) and current avatar image.
    *   Stream Title and Category/Game.
    *   Live Uptime and current viewer count.
    *   Total followers and Twitch internal User ID.
*   **Streamlink Video Launcher:** 
    *   Launches streams with the default `'best'` quality setting for high-definition playback.
    *   Dynamically passes stream title and game information from DecAPI as the video player's window title (e.g. `"<username> - <title> (<category>)"`).
*   **Integrated Log Terminal:** Features an interactive scrollable console at the bottom of the dashboard that captures `stdout` and `stderr` streams from the running Streamlink process in real-time, providing immediate visibility into buffering and errors. Includes a **Kill Process** button to quickly stop streams.
*   **Twitch Integrations:** Access shortcuts to open the Twitch channel page or standard popout chat directly in your default browser.
*   **Zero Native C++ Plugins:** Rewritten using pure Dart code (e.g., local File I/O config storage next to the executable instead of registry-reliant databases). This eliminates Windows symlink creation permissions and allows standard non-administrator users to build and run the app out of the box without needing Developer Mode.

---

## Prerequisites

1.  **Streamlink:** Ensure Streamlink is installed on your Windows machine and its binary folder is added to your system `PATH` (typically installed at `C:\Program Files\Streamlink\bin`).
2.  **Visual Studio 2022:** To build the application from source, you must have Visual Studio 2022 with the **"Desktop development with C++"** workload installed.

---

## Getting Started

Follow these steps in a PowerShell terminal:

### 1. Bootstrap the Local Environment
Run the setup script to download and extract the isolated Flutter SDK and configure the project:
```powershell
.\setup.ps1
```
*(This downloads the stable Flutter Windows zip and sets it up in a hidden `.\.flutter-sdk` directory. This might take a few minutes depending on your internet connection.)*

### 2. Run in Development Mode
Launch the GUI in debug/development mode:
```powershell
.\run.ps1
```

### 3. Compile Standalone Release
Compile the application into a standalone folder:
```powershell
.\build.ps1
```
Once built successfully, the self-contained folder is created at:
`.\build\windows\x64\runner\Release\`

You can copy this folder anywhere (e.g., a USB drive), and launch **`streamlink_gui.exe`** directly. The application configuration (`channels_config.json`) will save locally inside that same directory.

---

## How to Use

1.  **Saved Channels Sidebar:**
    *   Displays your saved channels list. By default, it seeds `limmy`.
    *   Shows a green dot and `LIVE` badge if the channel is currently broadcasting, or a grey dot if offline.
    *   Remove a channel from your list by clicking the `x` icon.
2.  **Adding Channels:**
    *   Type a Twitch username in the input bar at the top of the sidebar and click `+` (or press Enter).
    *   The app calls DecAPI to verify that the username exists on Twitch. If found, it is added and saved automatically.
3.  **Twitch Dashboard:**
    *   Select any channel to view detailed statistical cards.
    *   Click **Launch Streamlink** to start streaming.
    *   Use the browser shortcut buttons to open the channel or its chat window.
    *   Use the refresh icon to pull the latest stats manually.
4.  **Terminal Console:**
    *   When Streamlink launches, a black log terminal opens at the bottom.
    *   Watch connection info, plugin loading status, and stream buffer output.
    *   Click **Kill Process** to terminate the stream player.
