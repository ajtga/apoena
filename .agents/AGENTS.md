# Apoena — Project Rules & Conventions

## Project Overview

Apoena is a single-script Windows Forms productivity tool written in PowerShell.
It enforces the 20-20-20 eye rest rule, logs work blocks to a local CSV, and
runs silently in the system tray.

## Runtime & Dependencies

| Item | Version / Detail |
|---|---|
| PowerShell | 5.1+ (`#Requires -Version 5.1` enforced) |
| .NET Assemblies | `System.Windows.Forms`, `System.Drawing` (no NuGet packages) |
| P/Invoke | `user32.dll → GetLastInputInfo` (idle detection) |
| OS | Windows 10 or later |
| External dependencies | None — the project is fully self-contained |

## Project Structure

| Path | Purpose |
|---|---|
| `src/apoena.ps1` | Main (and only) script — all application logic |
| `src/config.psd1` | User config (gitignored); overrides defaults |
| `src/config.example.psd1` | Checked-in config template |
| `src/apoena-log.csv` | Runtime log output (gitignored) |
| `start-apoena.cmd` | Silent launcher (no visible console) |

## CSV Logging Rules

- **Format:** RFC 4180-compliant CSV.
- **Escaping:** All free-text fields (Accomplished, Planned, Notes, and any
  future text column) MUST be wrapped in double quotes. Internal double quotes
  are escaped by doubling them (`""`) as per RFC 4180. The `ConvertTo-CsvSafe`
  function is the single owner of this logic — callers must NOT add manual
  quoting.
- **Numeric formatting:** All numeric values written to CSV MUST use
  `[System.Globalization.CultureInfo]::InvariantCulture` for string conversion
  to guarantee a dot (`.`) decimal separator regardless of the system locale.
- **Encoding:** UTF-8.
- **Schema changes:** New columns must be appended at the end. Existing column
  order must never change, to preserve backward compatibility with user data.

## GUI / WinForms Rules

- **Ampersand (`&`) in labels:** WinForms interprets `&` as a mnemonic prefix
  (keyboard shortcut underline). Never use a bare `&` in button or label text
  to represent the word "and" — spell it out or use `&&` to display a literal
  ampersand.
- **TopMost:** All popup forms must set `TopMost = $true` to ensure they
  appear above full-screen applications.

## Concurrency

- **Single instance:** Only one Apoena process may run at a time. This is
  enforced via a named Mutex (`Global\ApoenaEyeRestMutex`). The mutex must
  remain held for the entire lifetime of the process.
- **Log writer:** Only the single running instance writes to `apoena-log.csv`.
  No file-locking mechanism is used beyond the single-instance guarantee.

## Code Style

- PowerShell 5.1 compatible syntax only (no `??=`, no ternary `? :`).
- Prefer `[DateTime]::Now` over `Get-Date` inside hot loops for performance.
- Helper functions are defined before the main loop.
- Global state uses `$global:` prefix explicitly.
