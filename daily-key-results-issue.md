# Issue: Integrate Daily Key Results Module for Focused Time Logging

## Goal

Implement a daily Key Results (KRs) planning and tracking module inside Apoena. This feature encourages focus by prompting users to plan key results for their day, associate each completed 20-minute work block with exactly one of these key results, add new key results on the fly, and categorize them.

---

## Technical Specifications & Architecture

### 1. Configuration & Customization
Add a new configuration parameter `KeyResultCategories` in [config.example.psd1](file:///c:/dev/1_projects/apoena/src/config.example.psd1) and load it into `$global:keyResultCategories` in [apoena.ps1](file:///c:/dev/1_projects/apoena/src/apoena.ps1).
* **Default configuration entry:**
  ```powershell
  KeyResultCategories = @("Project", "Analysis", "KPI", "Dev", "Board Request", "Management Request", "Coordination Request", "Other")
  ```

### 2. CSV Data Persistence
* **Key Results definitions log (`src/apoena-krs-log.csv`):**
  * Store planned and dynamically added Key Results in a separate CSV file to keep the application self-contained.
  * **Header schema:**
    `Timestamp,Date,KeyResultID,Category,Description`
  * Example entry:
    `2026-07-08 07:15:00,2026-07-08,KR-1,Dev,Implement Key Results Module`
  * Key Result IDs are scoped per day: `KR-1`, `KR-2`, `KR-3`, etc., based on the count of KRs already logged for that specific date.
* **Work Block log changes (`src/apoena-log.csv`):**
  * Append a new column at the end of the CSV: `KeyResultID`.
  * Update `Write-Log` logic to record the ID of the selected Key Result (e.g., `KR-1`) for that work block.

### 3. User Interface Changes (WinForms)

> [!IMPORTANT]
> To comply with the Apoena rules:
> * All new popup forms must set `.TopMost = $true` to ensure they appear above full-screen applications.
> * Never use a bare `&` in button or label text to represent the word "and" to avoid WinForms interpreting it as a mnemonic (keyboard shortcut underline). Spell it out or use `&&`.

* **Daily Setup / Management Form (`Show-KeyResultsForm`):**
  * A dialog to list, add, and review the day's Key Results.
  * **Controls:**
    * A `ListBox` displaying today's active Key Results in the format: `[ID] (Category) Description`.
    * A `ComboBox` dropdown loaded with categories from config.
    * A `TextBox` for entering the Description.
    * An `"Add"` button to write the new KR to `apoena-krs-log.csv` and refresh the ListBox.
    * A `"Close"` / `"Start Day"` button.
  * **Startup Trigger:** If Apoena starts up (or restarts on the same day) and no Key Results exist for the current date in `apoena-krs-log.csv`, automatically open this planning window to prompt the user to define their goals.
* **System Tray Menu integration:**
  * Add a new menu item to the tray context menu: `Manage Key Results...` that opens `Show-KeyResultsForm` at any time.
* **Work Block Form changes (`Show-WorkBlockForm`):**
  * Add a `ComboBox` dropdown displaying today's active Key Results (`[ID] Description`).
  * Add a `[+]` button next to the dropdown that opens a mini prompt (`Show-QuickAddKRForm`) to input a Description and Category. This dynamically adds the new KR to the CSV, refreshes the dropdown, and auto-selects it.
  * **Single-Tasking Enforcement:** The user *must* select exactly one Key Result to associate with the work block before completing it. If the dropdown has no selection or is empty, block dialog validation (disable submit or show warning) to prevent context switching.

### 4. README Update (Scientific Reference)
* Update [README.md](file:///c:/dev/1_projects/apoena/README.md) to document the new Key Results module.
* Add a section justifying the single-focus restriction, linking to:
  [Why Multitasking is Bad for Focus and Memory](https://www.healthline.com/health/alzheimers-dementia/multitasking-memory-loss-link).

---

## Verification & Testing Plan

This verification checklist should be appended to [TESTING.md](file:///c:/dev/1_projects/apoena/TESTING.md) under a new issue section:

### Issue #4 — Daily Key Results Module

#### 1. Daily Planning Prompt on Startup
* **Steps:**
  1. Ensure no KRs are logged in `apoena-krs-log.csv` for today.
  2. Launch Apoena (`start-apoena.cmd`).
* **Expected Result:**
  * The `Daily Key Results Planning` window opens automatically.
  * You can successfully define your first key results, assign them categories, and start your day.

#### 2. Dynamic Key Results Addition
* **Steps:**
  1. Open tray icon menu → click **Manage Key Results...**.
  2. Add a new KR (e.g. category "Management Request", description "Emergency Meeting").
* **Expected Result:**
  * The new KR is immediately appended to `apoena-krs-log.csv` with a new incremental ID (`KR-X`).
  * It shows up in the ListBox.

#### 3. Work Block Key Result Selection
* **Steps:**
  1. Set `WorkBlockMinutes = 0.1` in config to make blocks run every 6 seconds.
  2. Launch Apoena.
  3. Wait for a block to finish.
  4. Select the newly created KR from the dropdown.
* **Expected Result:**
  * The block cannot be logged without selecting a Key Result.
  * Once logged, check `src/apoena-log.csv` to verify that the final column contains the exact `KeyResultID` (e.g. `KR-1`).

#### 4. On-the-fly Add button in Work Block Form
* **Steps:**
  1. Complete a work block.
  2. Click the `[+]` button next to the Key Result dropdown.
  3. Enter a new KR name and category.
* **Expected Result:**
  * The mini-form registers the new KR.
  * The dropdown is updated, and the new KR is automatically selected.
