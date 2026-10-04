# Band Member

A native macOS app for playing synchronized audio and video files in live performance settings. Built as a lightweight alternative to QLab.

## Features

- **Sample-accurate sync** - Multiple audio tracks play in perfect sync via AVAudioEngine on a shared render timeline
- **Multi-monitor video** - Assign video files to Main Display or 2nd Display; new videos layer on top of existing ones
- **Groups** - Put the tracks of a song in a group and they all start together from one spacebar press, whether the group's header or any track inside it is selected. Groups have their own name and color, collapse to a single row (option-click the arrow to fold or unfold all of them), and move, copy and delete as a unit. Drag tracks in and out, or use Group (Cmd+G), Ungroup and Remove from Group. Playlists made with the old per-track "play next" checkboxes are converted to groups when opened
- **Enable / disable** - Every track and group has a checkbox at the right-hand end of its row. An unchecked track is left out when its group plays; an unchecked group is skipped altogether, and the spacebar passes over it
- **Per-channel volume** - Independent master, left, and right channel volume (0-200%) with real-time waveform preview
- **Per-track limiter** - Every audio track has its own look-ahead limiter, so a track pushed past 100% only squashes itself instead of pumping everything playing alongside it. Switch on a track's Limiter and raise Boost to bring its quiet passages up toward its loud ones (the waveform previews the result). A final safety limiter works on each physical output separately, so an overload in the IEMs never ducks FOH.
- **Multi-output routing** - Drive any CoreAudio output device (built-in speakers, Focusrite 4i4, etc.) independent of the system default. Cues route to named buses ("FOH", "IEM", "Click"); per-device mappings translate each bus to physical output channels (stereo pair or mono-sum). Switching rigs only requires re-mapping buses on the new device, not editing every cue. Unassigned buses on a device play silent, so the same playlist can sound right at home, in rehearsal, and at the gig.
- **Waveform viewer** - Visual waveform with draggable playhead, L/R channels shown separately, live playback indicator while a track is playing
- **Loop points** - Shift-click anywhere on the waveform to set a loop end; playback loops back to the start point when the end is reached
- **Tempo detection** - Background beat analysis per track, with snap-to-beat or snap-to-measure when setting start and loop points
- **Lyrics** - Local Whisper transcription with a built-in model picker (Tiny / Base / Small / Medium / Large v3 Turbo); lyrics stored as a sidecar JSON next to the audio file, never touching the audio itself
- **Karaoke presenter** - Fullscreen two-line scrolling lyric display on a chosen monitor, with a 1-second lead-in when a line is preceded by silence
- **Lyric editor** - Double-click a line to rewrite its text, double-click a timestamp to edit it directly, ← / → to nudge ±100 ms with adjacent-line carry, trash to delete a line
- **Fix Lyrics** - Paste corrected lyrics and keep the existing timestamps; word-set alignment handles line-break differences
- **Undo / redo** - Cmd+Z / Cmd+Shift+Z across all playlist edits, with a 50-level history
- **Playlist management** - Add, delete, reorder, cut/copy/paste, multi-select (shift/cmd click), color-coded entries, text dividers
- **QLab import** - Import .qlab5 workspaces with cue names and file paths; auto-follow chains become groups
- **Save/Load** - JSON-based playlists with auto-restore of last session
- **Portable playlists** - A saved playlist records where each file sits relative to the playlist as well as its full path, so a playlist copied to another Mac along with its media still finds everything. Export Bundle (Cmd+Shift+E) packs the playlist, its audio and video (in `audio/` and `video/` subfolders) and any lyrics into one zip; unzip it anywhere and open the playlist inside
- **Live performance ready** - 1-second fade out on escape, spacebar auto-advances to next idle item, dark mode

## Supported Formats

- Audio: `.mp3`, `.aif`, `.aiff`
- Video: `.mp4`, `.mov`

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Space | Play selected item and advance to next |
| Escape | Fade out all playback (1 second) |
| Return | Insert text divider |
| Delete | Delete selected items |
| Cmd+N | New playlist |
| Cmd+S | Save |
| Cmd+Shift+S | Save As |
| Cmd+O | Load playlist |
| Cmd+Shift+E | Export playlist and media as a zip bundle |
| Cmd+Shift+I | Import from QLab |
| Cmd+K | Toggle dark/light mode |
| Cmd+Opt+M | Edit output bus mappings |
| Cmd+Z / Cmd+Shift+Z | Undo / Redo |
| Cmd+X/C/V | Cut/Copy/Paste items |
| Cmd+D | Add media files |
| Cmd+G | Group selected tracks |
| Cmd+Shift+G | Ungroup |

## Building

Requires macOS 14+ and Xcode 16+.

```bash
# Build and run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash build.sh
open build/BandMember.app
```

## Architecture

- **AVAudioEngine** - Shared audio render graph for sample-accurate multi-track sync, driving the user's chosen CoreAudio device at its native sample rate and channel count
- **AVPlayer** - Per-cue video playback with full-screen borderless windows. Each player is prerolled and then started on the exact clock time the group's audio reaches the output (after limiter look-ahead and device latency), so picture and sound start together
- **ChannelGainAU** - Custom Audio Unit that takes a stereo cue input, applies master and L/R gain (with optional -3 dB mono sum), limits the cue, and places the result on a specific channel pair (or single channel) of an N-channel output bus, zeroing the rest
- **LookaheadLimiter** - The limiter itself: 5 ms look-ahead, brick-wall at full scale, with a fast release for stray peaks and a slower hold-and-release for sustained loud passages. Every cue runs through the same look-ahead whether or not it is limiting, so cues stay sample-aligned
- **SafetyLimiterAU** - Custom Audio Unit on the final output bus with one independent limiter per physical channel, catching whatever several cues add up to on the same output
- **AudioOutputManager** - Enumerates CoreAudio output devices, tracks the user's selection, and responds to hot-plug
- **OutputBusStore** - Named buses are persisted at `config/output-buses.json` in this repo (the checkout the app was built from), so the bus IDs that playlists reference follow `git pull` to other machines. Per-device channel assignments stay machine-local at `~/Library/Application Support/BandMember/output-mappings.json` because device UIDs contain hardware serial numbers; map each bus to channels once per machine in the output mappings editor
- **WhisperKit** - Local on-device speech-to-text for lyric transcription, with CoreML model caching under `~/Library/Application Support/BandMember/`
- **SwiftUI** - Native macOS UI with AppKit integration for drag-and-drop and keyboard handling

Diagnostic logs are written to `~/Library/Logs/BandMember/BandMember.log` with simple ~1 MB rotation.
