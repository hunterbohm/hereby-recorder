# Install lml-import on the MacBook

These steps start automatic imports of iPhone call recordings and of files dropped into a folder. Install only after the mini serves `live-meeting-receive` and `live-meeting-done`, because both agents run with `--push`.

The phone agent runs when the Notes database changes, every 15 minutes, and at login. The inbox agent runs when the inbox folder changes, every 15 minutes, and at login. Both write one line per handled recording to `~/Library/Logs/LiveMeetingListener/import-*.log`.

1. From the repository folder, build and place the binary and the agents:

   ```bash
   import/scripts/install.sh
   ```

   The script builds a release binary into `~/Library/Application Support/LiveMeetingListener/bin/lml-import`, creates the inbox, and writes both agents to `~/Library/LaunchAgents`. It prints the `launchctl` commands and starts nothing.

   - To import calls recorded before today, set `LML_IMPORT_SINCE=YYYY-MM-DD`.
   - To use another inbox, set `LML_IMPORT_INBOX`. The default is `iCloud Drive/Meeting Inbox`, which the iPhone Files app can save to.

2. Give the binary Full Disk Access in **System Settings > Privacy & Security > Full Disk Access**. It needs this to read the Notes group container and iCloud Drive. The binary is signed with the recorder's certificate, so a rebuild keeps the grant.

3. Start the agents with the two `launchctl bootstrap` commands that the script printed.

To stop the agents, run `launchctl bootout gui/$(id -u)/sh.hereby.recorder.import.phone` and `launchctl bootout gui/$(id -u)/sh.hereby.recorder.import.inbox`.
