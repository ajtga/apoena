# Apoena Configuration File
# Copy this file to "config.psd1" in the same directory and customize.
# Any setting omitted from config.psd1 will use its default value.

@{
    # Focus session interval in minutes (default: 20)
    FocusSessionMinutes  = 20

    # Eye rest duration in seconds (default: 20)
    BreakDurationSeconds = 20

    # Idle time before auto-pause in minutes (default: 15)
    IdleThresholdMinutes = 15

    # Categories for "Away" (when paused or returning from idle)
    AwayReasons          = @("Meeting", "Lunch", "Call", "Offline Work", "Coffee", "Rest", "Distraction", "End of Day", "Other")

    # Categories for "Quick Break" (when choosing not to take a 20-20-20 rest)
    QuickBreakReasons    = @("Pee", "Poo", "Water", "Coffee", "Snack", "Stretch", "Other")

    # Categories for Key Results
    KeyResultCategories  = @("Project", "Analysis", "KPI", "Dev", "Board Request", "Management Request", "Coordination Request", "Other")
}
