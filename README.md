# Hereby Recorder

Hereby Recorder is a Mac menu bar app that records your meetings on your own machine, transcribes them on the device, and hands the finished transcript to your own agent. It listens to the call in your meeting app and to your microphone, writes a transcript with who said what, and runs a command you choose when the meeting ends. The recorder itself sends nothing to a service run by its author.

## What it records

- Your microphone and the audio of the meeting app, only while a meeting app you listed is on a call. The default list is Zoom, Google Meet in common browsers, FaceTime, Teams, Slack huddles, Discord, and Webex. Change it with `meeting_apps` in the settings file.
- The recorder transcribes both sides on the Mac with Apple's speech model. The transcript is a plain `transcript.jsonl` per meeting, in `~/Library/Application Support/LiveMeetingListener/sessions/`.
- The other side's audio stays on the Mac only until its speakers are labeled, then it is deleted. Speaker labeling runs on the Mac with open models that download on first use (see `THIRD-PARTY-NOTICES.md`). No voiceprints are kept: the recorder stores who spoke when, never a voice profile.
- Finished meetings are deleted after `retention_days` (14 by default).

## Consent

You are responsible for telling people they are being recorded. Many places require every person on a call to agree before it is recorded or transcribed, and some require it for anyone who is not you. Tell people at the start of the call, and do not record where the law or your host forbids it. The panel has a Not a meeting button that stops a recording and deletes it.

## Requirements

- A Mac running macOS 26 or later.
- Xcode or the Xcode Command Line Tools with Swift 6, `git`, `openssl`, and `python3` (all ship with the Command Line Tools). Install the tools with `xcode-select --install`.
- Optional: a second machine you can reach with `ssh`, where meetings sync. Without one, meetings stay on the Mac, which is the default.

## Permissions

macOS asks for these the first time they are needed. Grant them in System Settings > Privacy & Security.

- Microphone, to hear you.
- System audio recording, to hear the other side of the call.
- Full Disk Access, only for the optional iPhone call importer in `import/`.

Run `lml doctor` from the built app to see which are missing.

## Build and sign it locally

The app is built and signed on your Mac. You or your own agent run these steps from a clean clone. Nothing here needs an Apple developer account: the signing certificate is a local self-signed one that `mac/scripts/sign.sh` makes once, so macOS keeps your permission grants across rebuilds.

```sh
git clone <this repository> hereby-recorder
cd hereby-recorder
git tag local-build
mac/scripts/build-app.sh
mac/scripts/install.sh
```

1. `git tag local-build` marks the commit, because the build stamps the app with a tag. Any tag name works.
2. `mac/scripts/build-app.sh` builds a release binary with Swift Package Manager, assembles `~/Applications/LiveMeetingListener.app`, signs it with the local certificate, and prints the app path. The first build downloads FluidAudio 0.17.7 and takes a few minutes.
3. `mac/scripts/install.sh` writes the two LaunchAgents (`sh.hereby.recorder` and `sh.hereby.recorder.mic`) to `~/Library/LaunchAgents` and prints the `launchctl bootstrap` command that starts the recorder. It starts nothing itself. Run the printed command when you are ready.
4. Open System Settings and grant the permissions above when macOS asks.

Check the build with `~/Applications/LiveMeetingListener.app/Contents/MacOS/lml doctor`. To stop the recorder, run `launchctl bootout gui/$(id -u)/sh.hereby.recorder`.

## Settings

Copy `recorder.example.toml` to `~/.config/hereby/recorder.toml` and edit it. Every key is optional. The code names no one: without a file, no user name is set, meetings stay on the Mac, and the done command is `handoff/hereby-handoff.sh`.

### With a tiling window manager

The call overlay floats above every window, so a tiler leaves it alone. Two settings make it fit in:

- `overlay_command` runs each time the overlay shows, hides, or changes style, so the tiler can keep windows beside the side strip instead of under it. HyprMac's `reserve` dispatcher does this; the example file has the line. The recorder frees the room again when the call ends and when it quits, and frees every screen when it starts, in case it stopped without saying so.
- `overlay_toggle_key` and `overlay_say_key` move the overlay's shortcuts off keys the tiler already uses, like Option-Return for a terminal.

### Reading the screen

During a call, every question in the overlay also sends a picture of the screen under the pointer, with the overlay left out, so answers can use a shared slide or the doc you have open. The Read screen button asks about the screen itself. It needs Screen Recording for LiveMeetingListener in System Settings. Set `screen_context = false` to send the screen only when you press Read screen.

## When a meeting ends

A call counts as over when its meeting app stops using audio for 2 minutes. The recorder then stops listening and waits 5 more minutes before it files the call. If the same call comes back in that time (the same meeting app, and no new calendar meeting), it records into the same transcript, so a dropped call that you rejoin stays one meeting. A different call, Stop, Pause, quitting, or the Mac going to sleep files the waiting call at once, with the time the first call ended.

The recorder runs `handoff/hereby-handoff.sh <session folder>`, which prints the path of that meeting's transcript once. Your agent reads the transcript and does the rest. To run something else, set `done_command` in the settings file. See `handoff/README.md`.

## Tests

The Swift tests need only the Command Line Tools. CI runs them, and the build script's tests, on a self-hosted Mac:

```sh
mac/scripts/test.sh
import/scripts/test.sh
```

The Python tests need [uv](https://docs.astral.sh/uv/), which is not part of the Command Line Tools. Install it with `brew install uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`. On first run it downloads Python 3.12 and pytest, so it needs a network connection. Then:

```sh
mini/run_tests.sh
```

The script uses `timeout` or `gtimeout` when one is installed and runs without a time limit when neither is.

## Upgrading from the earlier launchd labels

Early private builds used a different launchd label prefix. Move to `sh.hereby.recorder` in this order. Run it when no meeting is due in the next ten minutes, because the recorder starts capturing about ten seconds before any session file shows it:

1. Run `mac/scripts/build-app.sh --new-bundle-id` to install the new build, when you are at the Mac. The new build has a new app identity, so macOS asks again for microphone and system audio access; allow both. Without the flag the build refuses before it stops anything, so a routine rebuild never leaves the recorder running without those permissions. Before the migration it stops the recorder under its old label, swaps the app, and restarts that label, as it always has, and it refuses while a session is active. After the build the old label already runs the new binary, so the migration's local `lml capabilities` check passes, and `ping` still goes only to the new label's process. If both labels are loaded the build refuses and tells you to run the migration.
2. Run `mac/scripts/migrate-labels.sh --dry-run` to see what it would do.
3. Run `mac/scripts/migrate-labels.sh` to do it.

The migration is meant to be run once, by hand. It refuses, without touching any agent, if the installed app is too old to answer `lml ping`, if a session is active or paused, or if call audio is on disk (a call is arming, recording, or being labeled). It checks again right before it unloads the recorder. If it finds an old agent that is still loaded after its plist was removed, it changes nothing and prints the commands to finish by hand. It confirms each new agent started before it removes the old plists, and any failure or interruption puts the old agents back.

## License

MIT, see `LICENSE`. FluidAudio (Apache 2.0) and the speaker models (CC BY 4.0) are credited in `THIRD-PARTY-NOTICES.md`.
