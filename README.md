# Apoena

**A Windows PowerShell productivity assistant that enforces the 20-20-20 eye rest rule and logs your work blocks.**

Apoena runs silently in your system tray, monitoring your work routine. Every 20 minutes it prompts you to log what you accomplished and plan your next task, and then enforces a 20-second eye rest — looking 20 feet away. It also detects idle periods automatically, manages quick breaks, and exports a detailed CSV log for personal productivity analysis.

## Features

- **20-Minute Work Blocks** — Monitors continuous work intervals and prompts you to log accomplishments and plan the next task.
- **Strict Eye Rest Enforcement** — Requires 20 seconds of no mouse/keyboard input. If movement is detected, the timer restarts or you can opt for a physical break instead. ([Why 20-20-20?](https://www.healthline.com/health/eye-health/20-20-20-rule))
- **Categorized Quick Breaks** — Classify short breaks (Water, Coffee, Bathroom, Stretch, etc.) for granular tracking.
- **Smart Idle Detection** — If the computer is inactive for 15+ minutes, monitoring pauses automatically. On return, you categorize the time away (Meeting, Lunch, Call, etc.).
- **System Tray Integration** — Runs in the background with a tray icon showing a live countdown. Right-click to pause manually or exit cleanly.
- **CSV Productivity Log** — All events, durations, notes, and response times are saved locally for analysis in Excel, Python, R, or any data tool.

## Requirements

- Windows 10 or later
- PowerShell 5.1 or higher (pre-installed on Windows 10+)
- No additional dependencies (uses native .NET / Windows Forms assemblies)

## Quick Start

### Option 1 — Silent launcher (recommended)

Double-click `start-apoena.cmd` in the project root. Apoena starts hidden in the system tray with no visible console window.

### Option 2 — Manual launch from terminal

```powershell
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File .\src\apoena.ps1
```

### Corporate / managed machines

If your machine enforces a Group Policy on script execution and the launcher fails, run this once (no admin required):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then use Option 1 or Option 2 as normal.

## Usage

Once running, Apoena appears as an ℹ️ icon in your system tray with a live countdown (e.g., *"Apoena - 14:32 remaining"*).

| Action | How |
|---|---|
| **Log a work block** | Wait for the 20-minute popup, fill in what you did and what's next |
| **Take an eye rest** | Click "Eye Rest (20s)" — look 20 feet away, don't touch the mouse |
| **Take a quick break** | Click "Quick Break" — pick a category, click OK when you return |
| **Pause manually** | Right-click the tray icon → "Pause / Log Break" |
| **End your day** | Right-click the tray icon → "Exit", or select "End of Day" on any return popup |

## Configuration

Copy `src/config.example.psd1` to `src/config.psd1` and customize:

```powershell
@{
    # Work block interval in minutes (default: 20)
    WorkBlockMinutes     = 20

    # Eye rest duration in seconds (default: 20)
    BreakDurationSeconds = 20

    # Idle time before auto-pause in minutes (default: 15)
    IdleThresholdMinutes = 15

    # Categories for "Away" (when paused or returning from idle)
    AwayReasons          = @("Meeting", "Lunch", "Call", "Offline Work", "Coffee", "Rest", "Distraction", "End of Day", "Other")

    # Categories for "Quick Break" (when choosing not to take a 20-20-20 rest)
    QuickBreakReasons    = @("Pee", "Poo", "Water", "Coffee", "Snack", "Stretch", "Other")
}
```

Any setting omitted from `config.psd1` will use its default value. The config file is gitignored, so your personal settings won't be committed.

## CSV Log Schema

The log file (`apoena-log.csv`) is generated in the same directory as the script with the following columns:

| Column | Type | Description |
|---|---|---|
| `Timestamp` | `yyyy-MM-dd HH:mm:ss` | Exact date and time of the event |
| `TimezoneOffset` | `±HH:mm` | UTC offset at the time of logging (e.g., `-03:00`) |
| `EventCategory` | string | Event type: `Work Block`, `Quick Break`, `Eye Rest`, `Away`, `System` |
| `EventDetail` | string | Subtype or qualifier (e.g., `Complete`, `Water`, `Meeting`, `Started`) |
| `BlockIndex` | integer | Auto-incrementing block counter (global, across sessions) |
| `DaySequence` | integer | Block number within the current day (resets at midnight) |
| `DurationSeconds` | integer | Duration of the event in seconds |
| `Accomplished` | free text | What was completed during the last work block |
| `Planned` | free text | What the user plans to do next |
| `Notes` | free text | Additional observations (e.g., on return from idle) |
| `LoggingDurationSecs` | integer | Time the user spent with the popup open before submitting |
| `ScheduleContext` | string | Time-of-day context: `Core Hours`, `Lunch Time`, `Overtime`, `Early Arrival`, `Weekend` |

## Contributing

Contributions are welcome! Please open an issue to discuss your idea before submitting a pull request.

## Name Origin

**Apoena** — derived from the indigenous Tupi-Guarani language of Brazil, "Apoena" translates to *"he who sees far"* (*aquele que enxerga longe*). This name captures the essence of the 20-20-20 rule's mandate to look 20 feet away to preserve visual health, ensuring your physical endurance safely sustains the relentless *"Labor Omnia Vincit"* momentum of daily improvement.

## License

This project is licensed under the [GNU General Public License v3.0 (GPLv3)](LICENSE).

You are free to use, share, and modify this work, but any derivative works or distributed modifications must also be released under the GPLv3 license.

---

## References

FUNDAÇÃO NACIONAL DOS POVOS INDÍGENAS. *Dicionário de Tupi-Guarani*. Brasília: FUNAI, [s.d.]. Available at: <https://biblioteca.funai.gov.br/media/pdf/Folheto43/FO-CX-43-2739-2000.pdf>. Accessed: 6 Jul. 2026.