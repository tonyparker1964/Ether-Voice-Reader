# Ether Voice Reader

**New: native Mac app.** See [`macOS/`](macOS/README.md). It's a SwiftUI app with a mic test, lossless voice recording and on-device narration in your voice. The browser versions below are kept for reference.

A personal reader for pasted passages and plain-text files, with browser narration, sentence navigation, bookmarks, spoken controls, and voice-sample recording.

## Voice Studio (public page)

`voice.html` is a browser mic test and voice recorder. It has a mic picker, a live meter, Auto-set level, Boost, a 5-second test, clean-up (rumble/hiss/level) and a WAV + transcript download. Audio never leaves the device.

## Use

Open index.html in a supported browser, or publish the main branch root with GitHub Pages. Paste a passage and click Prepare reading, then Read. The source link opens The Secret Book of John.

Voice controls: enable the microphone and say “reader play”, “reader pause”, “reader next”, “reader back”, “reader stop”, “reader faster”, or “reader slower”. Browser support varies; Chrome is suggested. Headphones reduce accidental commands from narration.

## Your voice

Recording, playback, and sample download are implemented. Voice cloning and narration generated in your own voice are not connected yet and require a voice service. No personal recordings or credentials are included in this repository.

Reading text and bookmarks are stored in this browser. Voice samples remain temporary until downloaded. Speech recognition may use the browser provider's online service.

## Validation

JavaScript syntax checked. Microphone permissions, speech recognition, and audio playback still require testing in the user's browser.
