# Apoena — Manual Test Plan

Use this checklist after each fix is applied. Set `WorkBlockMinutes = 0.1`
in `src/config.psd1` to trigger work-block popups quickly (every 6 seconds).

---

## Issue #1 — Button label: "Log and Resume"

**Goal:** The "Welcome Back" form button reads "Log and Resume" with no double
space and no missing character.

### Steps

1. Launch Apoena (`start-apoena.cmd`).
2. Right-click the tray icon → **Pause / Log Break**.
3. Click **OK** on the "Paused" dialog.
4. Observe the "Welcome Back" form.

### Expected Result

- [x] The bottom button label reads exactly **Log and Resume**.
- [x] No double space, no ampersand, no underlined letter.

---

## Issue #2 — Single-instance guard

**Goal:** A second launch is blocked while the first instance is running.

### Steps

1. Launch Apoena (`start-apoena.cmd`).
2. Confirm the tray icon appears.
3. Double-click `start-apoena.cmd` again (or run the PowerShell command).

### Expected Result

- [x] A message box appears: **"Apoena is already running in the system tray."**
- [x] After clicking OK, no second tray icon is created.
- [x] The first instance continues running normally.

### Edge Case

4. Exit the first instance (tray → Exit).
5. Launch again.

- [x] Apoena starts normally — the mutex was released.

---

## Issue #3 — Locale-safe numeric formatting

**Goal:** CSV numeric fields always use a dot (`.`) as the decimal separator,
even on systems where the locale uses a comma.

### Steps

1. Open `src/apoena.ps1` and temporarily add the following line right after
   `$scriptDir = ...` (line 22):

   ```powershell
   [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new("pt-BR")
   ```

2. Launch Apoena.
3. Wait for a work block popup, fill it in, and click **Eye Rest (20s)**.
4. Complete the eye rest.
5. Exit Apoena (tray → Exit).
6. Open `src/apoena-log.csv` in a **plain text editor** (not Excel).

### Expected Result

- [ ] `DurationSeconds` values use a dot: e.g. `6.123`, not `6,123`.
- [ ] `LoggingDurationSecs` values use a dot.
- [ ] The CSV has exactly **12 columns per row** (matching the header).
- [ ] Opening the CSV in Excel shows all columns aligned correctly.

### Cleanup

7. Remove the `CurrentCulture` override line you added in step 1.

---

## Issue #4 — CSV-safe escaping of free-text fields

**Goal:** Free-text fields containing commas, double quotes, or newlines do not
break the CSV column structure.

### Steps

1. Launch Apoena with `WorkBlockMinutes = 0.1`.
2. When the work block popup appears, type the following into the
   **"What did you accomplish?"** field:

   ```
   Fixed bug, refactored "parser", done
   ```

3. In **"What do you plan to do next?"**, type:

   ```
   Review PR #42, merge
   ```

4. Click **Eye Rest (20s)** and complete the rest.
5. Exit Apoena.
6. Open `src/apoena-log.csv` in a **plain text editor**.

### Expected Result

- [x] The Accomplished column contains:
      `"Fixed bug, refactored ""parser"", done"`
- [x] The Planned column contains: `"Review PR #42, merge"`
- [x] The row still has exactly **12 comma-separated fields** (commas inside
      quotes do not count as delimiters).
- [x] Opening the CSV in Excel shows the text intact in the correct columns.

---

## Issue #5 — Same-day restart welcome message

**Goal:** Reopening Apoena on the same day shows a "Welcome Back" resume form
instead of the generic first-run welcome, and counters continue from the
previous session.

### Steps — Same-day restart

1. Launch Apoena and let at least one work block complete (note the
   `BlockIndex` and `DaySequence` in the CSV).
2. Exit Apoena (tray → Exit).
3. Re-launch Apoena immediately (same day).

### Expected Result

- [x] A "Welcome Back" form appears with the text
      *"Apoena was already running today. What happened since it closed?"*
- [x] The form has a free-text input and a **Resume** button.
- [x] After clicking Resume, the CSV contains a new row with
      `EventCategory = System` and `EventDetail = Resumed`.
- [x] The `BlockIndex` and `DaySequence` in the new rows continue from the
      values logged before the exit (not reset to 1).

### Steps — New-day start

4. Do NOT delete `src/apoena-log.csv` and wait until the next day (or modify the timestamp of the last logged row to yesterday's date).
5. Launch Apoena.

### Expected Result

- [x] The standard welcome message appears:
      *"Welcome to Apoena! Have a great day at work..."*
- [x] `BlockIndex` continues from the last logged block index in the CSV (e.g., if the last logged index was 4, it resumes at 5).
- [x] `DaySequence` starts from 1.

### Steps — Fresh Start (No prior logs)

6. Delete `src/apoena-log.csv`.
7. Launch Apoena.

### Expected Result

- [x] The standard welcome message appears:
      *"Welcome to Apoena! Have a great day at work..."*
- [x] Both `BlockIndex` and `DaySequence` start from 1.
