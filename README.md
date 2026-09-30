# NotchPilot

Notch island for the MacBook Pro: hover the notch to open it.

- Now Playing from the system tracker (MediaRemote via a perl-hosted bridge, since macOS 15.4
  blocks non-Apple clients), with transport and scrubbing.
- Switcher of things you actually listened to (>30 s): one click pauses the current
  source and resumes that browser tab / app. Tabs are found in Arc/Chrome via AppleScript.
- Output device: Bluetooth and built-in only; tap to cycle, chevron for the list.
- XDR brightness via BrightIntosh CLI; fans Full blast/Automatic via Macs Fan Control's menu (Accessibility).
- Per-app volume via Core Audio process taps; apps at 100% are never tapped.

Build/install/run (signed, installs to ~/Applications):

    script/build_and_run.sh [run|install|logs]

Permissions (granted to the signed `com.velizard.NotchPilot`): Automation → Arc,
Accessibility (fan toggle), Screen & System Audio Recording (mixer).
Debug log: ~/Library/Logs/NotchPilot.log.
