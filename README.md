# Band Member

A native macOS app for playing synchronized audio and video files in live performance settings. Built as a lightweight alternative to QLab.

## Features

- **Sample-accurate sync** - Multiple audio tracks play in perfect sync via AVAudioEngine on a shared render timeline
- **Multi-monitor video** - Assign video files to Main Display or 2nd Display; new videos layer on top of existing ones
- **Auto-follow chains** - Check "play next" to trigger multiple items simultaneously with one spacebar press
- **Per-channel volume** - Independent master, left, and right channel volume (0-200%) with real-time waveform preview
- **Waveform viewer** - Visual waveform with draggable playhead to set start position; L/R channels shown separately
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
- **SwiftUI** - Native macOS UI with AppKit integration for drag-and-drop and keyboard handling
