# Handing a finished meeting to your agent

When a meeting ends, the recorder runs `handoff/hereby-handoff.sh <session folder>`. It needs no Hermes and no network. It prints one line, the path of that meeting's transcript, and it prints it once per meeting. The recorder logs the line. Point your agent at the path.

Your agent reads the transcript, writes a review file, and runs the one command:

```sh
hereby publish review.json
```

`hereby publish` is the Hereby Review tool. It checks the file, saves the review, and prints the link to open on your phone. Its file format is in the `hereby-review` repo, `review-form/README.md`.

## How it runs

| Where | What runs the script |
|---|---|
| Meetings stay on the Mac (no `ssh_host` in `recorder.toml`) | The Mac app, as soon as a meeting has ended. A failure is logged and retried with a short delay. |
| Meetings sync to a mini (`ssh_host` set) | `live-meeting-done` on the mini, once the Mac has delivered the whole transcript. |

On the mini, the command's output goes to `handoff.log` in the session folder, so Forget and retention delete it with the session. The default `done_command` is this script. To run something else, set `done_command` in `~/.config/hereby/recorder.toml`. A `{session}` in the command becomes the session folder.

## Run it by hand

Run `handoff/hereby-handoff.sh <session folder>`. Session folders are under `~/Library/Application Support/LiveMeetingListener/sessions/`.

Exit 0 and a path on stdout means the meeting is handed off. Exit 0 with nothing on stdout means it already was, or its transcript is empty. Exit 3 means the meeting is still recording. Any other exit code is a failure and the message is on stderr.

The script records the hand-off in `handoff.json` inside the session folder, so a repeat run, or a restart of the recorder, prints nothing and does nothing.

Crashed and failed sessions are handed off too. `handoff.json` names the state.
