# Fluke 190-504 Series II — MATLAB Live USB Viewer

**Main file:** `fluke_live_screen.m`  
**Instrument tested:** Fluke 190-504 Series II, firmware V11.46

A single-window MATLAB viewer that mirrors the Fluke ScopeMeter's colour display over a USB cable and provides controls for acquisition, screenshots, waveform export, and pausing communication so you can use the instrument's physical keys.

> **Status:** Native screen transfers and image decoding have been tested with a 190-504. A previous version successfully exported a 3,000-point channel-A waveform. The pause/reconnect behaviour and all possible waveform formats have **not** been verified on a physical instrument in this environment.

## Features

- Live **320 × 240 colour** display via the Fluke's mini-USB PC connection, using the proprietary `FBRLE2D` format.
- Four buttons in one window:

  | Button | What it does |
  | --- | --- |
  | **Stop / Start acquisition** | Sends `HO` (hold) or `AT` (arm trigger), based on the ScopeMeter's reported state. |
  | **Save image (PNG)** | Saves the last received screen image to your PC. |
  | **Export active channels (.mat)** | Retrieves available waveform samples and saves them as MATLAB `timetable` objects in a `.mat` file. |
  | **Pause / Resume communication** | Stops screen/status requests and closes the COM port; reconnects when resumed. |

- Continuously refreshes the PC display **even while the ScopeMeter is in HOLD**; you can still see menu and setting changes.
- Checks the instrument's actual **RUN/HOLD status** approximately every 2 seconds while connected. If you press HOLD/RUN on the ScopeMeter, the acquisition button label follows that state.
- Automatically detects a unique **Fluke USB Serial Port** in Windows; otherwise offers a COM-port picker with Device Manager descriptions where available.
- Sets the ScopeMeter's clock from the PC's **local date and time** on connection and reconnection.
- Displays basic power/battery connection/charging status (not battery percentage).
- Allows offline display of a previously captured `.fbrle2d` file.

## Requirements

- Fluke **190-504 Series II** ScopeMeter, connected to a Windows PC with a **mini-USB data cable**.
- Installed Fluke USB serial driver so the device appears under **Device Manager → Ports (COM & LPT)** (e.g. `Fluke USB Serial Port (COM11)`).
- MATLAB **R2019b or later** with `serialport` support; no additional MATLAB toolboxes are required by the script.
- Windows PowerShell for showing friendly COM-port descriptions. If descriptions cannot be retrieved, the picker falls back to port numbers.

Close **FlukeView** and any other program using the same COM port before starting the viewer.

## Installation and launch

1. Put `fluke_live_screen.m` in your current MATLAB folder or on your MATLAB path.
2. Connect the ScopeMeter to the PC and turn it on.
3. Run:

   ```matlab
   clear fluke_live_screen
   fluke_live_screen
   ```

   If one Fluke serial port is detected, it connects without a dialog. Otherwise, select the port in the popup.

   To choose a port explicitly, bypassing discovery:

   ```matlab
   fluke_live_screen("COM11")
   ```

   To list available ports:

   ```matlab
   serialportlist("available")
   ```

4. Close the MATLAB figure to stop the viewer and release the COM port.

**Offline image decoding:** If you have a raw screen capture saved from a previous transfer, open it without the instrument:

```matlab
fluke_live_screen("C:\path\to\capture.fbrle2d")
```

In offline mode, only **Save image (PNG)** is usable.

## Using Pause / Resume communication

Use **Pause communication** before operating the ScopeMeter from its physical front panel if continuous PC communication gets in the way.

- The application finishes its **current** screen transfer, then stops all USB requests and releases the COM port.
- The **last image remains visible** and can still be saved as a PNG.
- **Stop/Start acquisition** and **Export active channels** are disabled while paused.
- You can operate menus, change ranges or timebase, and use the physical controls without competing MATLAB requests.
- Click **Resume communication** to reopen the **same** COM port, synchronize the clock, re-read RUN/HOLD, and restart screen updates.

Pausing communication **does not** command HOLD: it leaves the ScopeMeter's acquisition state as it was. Likewise, pressing **Stop acquisition** holds waveform acquisition but **does not pause the live screen**.

If Windows assigns a **different COM number** while paused, close the viewer and relaunch it (or specify the new port).

## Saving screenshots

Click **Save image (PNG)**, choose a folder and filename, and save. The PNG is the most recently transferred **320 × 240 RGB screen**, not a screenshot of the whole MATLAB window. It can also be saved while communication is paused.

Default filename example: `20261115_104500_Scopemeter_screen.png`.

## Exporting numerical waveform data

Click **Export active channels (.mat)** and choose a destination. The script queries the four scope-mode traces using:

| Input | Remote command |
| --- | --- |
| A | `QW 10` |
| B | `QW 20` |
| C | `QW 50` |
| D | `QW 60` |

It temporarily places a running ScopeMeter into HOLD while retrieving traces, then sends `AT` afterward. **If the instrument was already in HOLD, it stays in HOLD.** Unavailable channels are skipped, with reasons recorded where possible.

By default, the exported filename follows `YYYYMMDD_HHMMSS_Scopemeter_channels.mat`. The `.mat` file contains one variable named **`Scopemeter`**, with the structure:

```matlab
Scopemeter.Instrument             % Instrument identity string
Scopemeter.ExportedAtPC           % PC date/time of export
Scopemeter.TimeReference          % Description of the time axis
Scopemeter.ActiveChannels         % Cell array of exported channel names
Scopemeter.A                      % Timetable for channel A, if available
Scopemeter.B                      % Timetable for channel B, if available
Scopemeter.C                      % Timetable for channel C, if available
Scopemeter.D                      % Timetable for channel D, if available
Scopemeter.ChannelMetadata.A      % Scaling / units / acquisition info, if available
Scopemeter.Unavailable.B          % Reason a channel was skipped, if applicable
```

Each available channel is a MATLAB **`timetable`**, with **acquisition-relative `duration` row times**, not absolute timestamps. Depending on the waveform mode, columns are `Signal`, `Minimum`/`Maximum`, or `Minimum`/`Maximum`/`Average`. Voltage/other units and metadata are preserved.

Example after exporting channel A:

```matlab
load('20261115_104500_Scopemeter_channels.mat','Scopemeter')
plot(Scopemeter.A.Time, Scopemeter.A.Signal)
grid on
xlabel('Time relative to trigger')
ylabel('Signal')
```

For a min/max waveform, plot `Scopemeter.A.Minimum` and `Scopemeter.A.Maximum` instead.

**Limitations:** `QW` can fail for inactive channels, before an acquisition finishes, or in **Roll mode**. If a binary waveform transfer is interrupted, the script stops rather than continuing with potentially misaligned protocol data. The Fluke may remain in HOLD; check the physical instrument before restarting.

## Refresh rate and battery information

- The application downloads **complete screen images**, rather than streaming raw samples at the ScopeMeter's sampling rate.
- A previous 190-504 test showed approximately **1.18 seconds/frame (0.85 frames/s)**. Actual speed varies with screen content and communications overhead.
- On-screen acquisition status comes from `IS` and is normally polled about **every 2 seconds** while connected.
- Power information may indicate whether the battery is present, external power is connected, or charging is occurring. The documented status query used here **does not provide a numerical battery percentage**.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| No COM port found | Check cable, power, USB driver and Windows Device Manager; try `serialportlist("available")`. |
| COM port is busy | Close FlukeView and other serial applications; close any older MATLAB viewer figures. |
| MATLAB runs an older script | Run `which fluke_live_screen -all`, keep the intended copy on the path, then `clear fluke_live_screen`. |
| Local buttons are hard to use | Click **Pause communication**; this releases the COM port until you resume. |
| No waveform exported | Enable a trace and complete an acquisition; ensure the instrument is not in Roll mode. |
| Fluke ACK/synchronization error | Stop the viewer; if the instrument does not recover, disconnect/reconnect USB or power-cycle the ScopeMeter before trying again. |
| Reconnect fails after pause | Verify the COM number has not changed and no other application has opened the port. |

## Protocol notes

This script uses the Fluke remote-control protocol over a **USB virtual serial port**. The principal commands are `ID` (identify), `WD` / `WT` (clock), `IS` (status), `HO` / `AT` (acquisition), `QP 0,12,B` (compressed screen), and `QW` (waveform export).

The Fluke screen decoder handles its colour palette's **BGR order** and two-dimensional RLE row references, resolving the earlier incorrect colours and black-band artifacts.

**Reference:** *Fluke 190 Remote Control and Programming Reference*, including the waveform-transfer description in Appendix F.

---

This is an independent MATLAB interface, not an official Fluke application. Check instrument settings and data integrity before relying on exported measurements for critical work.
