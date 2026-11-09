# lml-import

`lml-import` turns iPhone call recordings and audio files into recorder sessions on the MacBook. A session is the same `meta.json` and `transcript.jsonl` pair the recorder writes (contract C1), so the mini files it through the same pipeline as a Mac call.

## Commands

| Command | What it imports |
| --- | --- |
| `lml-import phone` | Call recordings in Apple Notes. |
| `lml-import file PATH...` | The audio files given (m4a, mp3, wav, caf, aif, mov, mp4, or any file AVFoundation reads). |
| `lml-import inbox DIR` | Audio files at the top level of `DIR`, then moves each one into `DIR/Imported/`. |

| Option | Applies to | Effect |
| --- | --- | --- |
| `--root DIR` | all | Import root. Default `~/Library/Application Support/LiveMeetingListener/imports`. |
| `--push` | all | Sends each new session to the mini (C2) and signals done (C3). Without it nothing leaves the Mac. |
| `--quiet` | all | Omits recordings that were already handled. |
| `--since YYYY-MM-DD` | `phone` | Ignores calls that started before this local date. |
| `--transcript-wait MIN` | `phone` | Minutes after a call ends to wait for Apple's transcript before transcribing on device. Default 30. |
| `--only RECORDING_ID` | `phone` | Imports one recording, such as `notes:1598CB78-52F7-4F2D-8C32-060C5000D37D`. |
| `--notes DIR` | `phone` | Notes group container. Default `~/Library/Group Containers/group.com.apple.notes`. |
| `--started ISO8601` | `file` | Start time of a single file. |

Each run prints one JSON line per recording: `id`, `outcome` (`imported`, `pushed`, `done`, `pending`, `skipped`, `failed`), and, when known, `reason`, `sid`, `rows`, `duration`, and `first_ts0`. Output never contains transcript text. The exit status is 1 when any recording failed.

## Sessions

Sessions live in `<root>/sessions/<sid>/`. The `sid` is the local start time plus four hex digits of a SHA-256 of the recording id, so a re-import of the same recording always lands in the same session.

- `meta.json` is the recorder's `SessionMeta` with `state` `closed`, `kind` `call`, and `source` `phone` or `file`. Phone sessions list `com.apple.mobilephone` in `apps`.
- `asr` is `apple-notes/call-transcript` when the rows come from Apple's transcript and `speechanalyzer/en_US` when they come from on-device transcription.
- `transcript.jsonl` rows have the recorder's row shape. `at` equals `ts1`, because an imported row is known only after the call.
- `ch` is `me` or `them` when the two sides of the call are separate audio, and `call` when the audio is one mixed channel. Files are always `call`.
- `xo` is the share of the row's time during which the other side has recognized words. It is 0 on `call` rows.
- A file session without `--started` carries `warnings: ["start_estimated"]`. Its start comes from the file's embedded creation date, or from its modification time minus its duration.

## Ledger

`<root>/ledger.json` maps each recording id to its `sid` and state. A recording is imported once.

| State | Meaning | Next run |
| --- | --- | --- |
| `written` | The session exists locally. | With `--push`, sends it. |
| `pushed` | The mini acknowledged both files. | Signals done. |
| `done` | `live-meeting-done` exited 0. | Nothing. |
| `forgotten` | The mini answered exit 4 for this session. | Nothing. |
| `empty` | Transcription found no speech. | Nothing. |

A recording that is pending or failed has no ledger entry and is tried again on the next run. Phone ids are `notes:<attachment ZIDENTIFIER>`. File ids are `file:sha256:<content hash>`, so a renamed or copied file is not imported twice. Runs that share a root wait for each other on `<root>/lock`.

## Push

With `--push`, each new session goes to the mini over ssh to the `ssh_host` in `recorder.toml` in this order:

1. `live-meeting-receive <sid> transcript.jsonl 0` with the file on stdin.
2. `live-meeting-receive <sid> meta.json 0` with the file on stdin.
3. `live-meeting-done <sid> <transcript bytes>`.

Every send starts at offset 0, so a resend replaces the remote copy. An acknowledged size that differs from the bytes sent is a failure. Exit 4 from either command records `forgotten`. Exit 3 from `live-meeting-done` sets the state back to `written`, so the next run sends the files again. Each ssh call is killed after 120 s.

## How Apple Notes stores a call recording

The iPhone saves each recorded call as a note that holds one attachment of type `com.apple.m4a-audio`. The note syncs to the MacBook through iCloud. `lml-import` copies `NoteStore.sqlite` with its `-wal` and `-shm` files to a scratch directory, reads the copy read-only, and deletes the copy.

- The `com.apple.m4a-audio` row in `ZICCLOUDSYNCINGOBJECT` is the recording. Its `ZMEDIA` points to a media row for the mixed `Call with <name>.m4a`.
- Each `public.mpeg-4-audio` row whose `ZPARENTATTACHMENT` is the recording is a fragment. It has `ZDURATION`, and its media row points to `moments_<date>-audio.MOV`.
- A media file is at `Accounts/<account>/Media/<media ZIDENTIFIER>/<ZGENERATION1>/<ZFILENAME>` under the Notes group container. It can arrive later than the database row.
- The fragment MOV has two audio tracks. Track 0 is the local side and track 1 is the remote side. This was measured on three calls against Apple's speaker labels.
- The recording row's `ZMERGEABLEDATA1` is an uncompressed protobuf CRDT document with root type `com.apple.notes.ICTTAudioRecording`. It holds `callRecordingStartTime` (seconds since 1970), `callLocalSpeakerHandle`, `callRemoteSpeakerHandle`, and `fragments`.
- Each fragment holds `transcript`, an array of `ICTTTranscriptSegment` words with `speaker` (a phone handle), `timestamp` and `duration` in seconds from the start, and `text` with its leading space. The array order groups each speaker's words into runs. Some calls have an empty transcript.
- Notes in Recently Deleted (folder type 1) and rows marked for deletion are skipped.

`lml-import` uses Apple's transcript when the recording has one fragment with words. Words from the local handle are `me`, and all other words are `them`. Without a transcript, it transcribes the two MOV tracks as `me` and `them`, or the mixed m4a as `call`. Audio is decoded with AVAssetReader and never played.
