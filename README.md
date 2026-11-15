# Ether Voice Reader

**New: native Mac app.** See [`macOS/`](macOS/README.md). It's a SwiftUI app with a mic test, lossless voice recording and on-device narration in your voice. The browser versions below are kept for reference.

A personal reader for whole books (PDF, EPUB, Word .docx, HTML, Markdown, plain text) and pasted passages, with chapter navigation, with browser narration, sentence navigation, bookmarks, spoken controls, and voice-sample recording.

## Voice Studio (public page)

`voice.html` is a browser mic test and voice recorder. It has a mic picker, a live meter, Auto-set level, Boost, a 5-second test, clean-up (rumble/hiss/level) and a WAV + transcript download. Audio never leaves the device.

## Use

Open index.html in a supported browser, or publish the main branch root with GitHub Pages. Click **Open book…** to load a whole book (it's split into chapters you can step through, and reading can continue into the next chapter automatically), or paste a passage and click Prepare reading. Then press Read. PDFs are read with Mozilla's pdf.js, loaded only when you open a PDF.

Voice controls: enable the microphone and say “reader play”, “reader pause”, “reader next”, “reader back”, “reader stop”, “reader faster”, “reader slower”, “reader next chapter” or “reader previous chapter”. Browser support varies; Chrome is suggested. Headphones reduce accidental commands from narration.

## Your voice

Recording, playback, and sample download are implemented. Voice cloning and narration generated in your own voice are not connected yet and require a voice service. No personal recordings or credentials are included in this repository.

Reading text and bookmarks are stored in this browser. Voice samples remain temporary until downloaded. Speech recognition may use the browser provider's online service.

## Validation

JavaScript syntax checked. Microphone permissions, speech recognition, and audio playback still require testing in the user's browser.
