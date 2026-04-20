# Band Member

A native macOS app for playing synchronized audio and video files in live performance settings. Built as a lightweight alternative to QLab.

## Features

- **Sample-accurate sync** - Multiple audio tracks play in perfect sync via AVAudioEngine on a shared render timeline
- **Multi-monitor video** - Assign video files to Main Display or 2nd Display; new videos layer on top of existing ones
- **Auto-follow chains** - Check "play next" to trigger multiple items simultaneously with one spacebar press
- **Per-channel volume** - Independent master, left, and right channel volume (0-200%) with real-time waveform preview
- **Waveform viewer** - Visual waveform with draggable playhead, L/R channels shown separately, live playback indicator while a track is playing
- **Loop points** - Shift-click anywhere on the waveform to set a loop end; playback loops back to the start point when the end is reached
- **Tempo detection** - Background beat analysis per track, with snap-to-beat or snap-to-measure when setting start and loop points
- **Lyrics** - Local Whisper transcription with a built-in model picker (Tiny / Base / Small / Medium / Large v3 Turbo); lyrics stored as a sidecar JSON next to the audio file, never touching the audio itself
- **Karaoke presenter** - Fullscreen two-line scrolling lyric display on a chosen monitor, with a 1-second lead-in when a line is preceded by silence
- **Lyric editor** - Double-click a line to rewrite its text, double-click a timestamp to edit it directly, ← / → to nudge ±100 ms with adjacent-line carry, trash to delete a line
- **Fix Lyrics** - Paste corrected lyrics and keep the existing timestamps; word-set alignment handles line-break differences
- **Undo / redo** - Cmd+Z / Cmd+Shift+Z across all playlist edits, with a 50-level history
- **Playlist management** - Add, delete, reorder, cut/copy/paste, multi-select (shift/cmd click), color-coded entries, text dividers
- **QLab import** - Import .qlab5 workspaces with cue names, file paths, and auto-follow settings
- **Save/Load** - JSON-based playlists with auto-restore of last session
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
| Cmd+Shift+I | Import from QLab |
| Cmd+K | Toggle dark/light mode |
| Cmd+Z / Cmd+Shift+Z | Undo / Redo |
| Cmd+X/C/V | Cut/Copy/Paste items |
| Cmd+D | Add media files |

## Building

Requires macOS 14+ and Xcode 16+.

```bash
# Build and run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash build.sh
open build/BandMember.app
```

## Architecture

- **AVAudioEngine** - Shared audio render graph for sample-accurate multi-track sync
- **AVPlayer** - Per-cue video playback with full-screen borderless windows
- **ChannelGainAU** - Custom Audio Unit for real-time L/R channel volume
- **WhisperKit** - Local on-device speech-to-text for lyric transcription, with CoreML model caching under `~/Library/Application Support/BandMember/`
- **SwiftUI** - Native macOS UI with AppKit integration for drag-and-drop and keyboard handling
