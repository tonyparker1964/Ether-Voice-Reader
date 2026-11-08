# Ether Local Voice Reader for Mac

This version generates narration on an Apple Silicon Mac using MLX Audio and Qwen3-TTS Base. No ElevenLabs API key is used. It is separate from the GitHub Pages reader: Pages cannot execute the local voice model.

## Start

1. Download this repository with **Code → Download ZIP**, extract it, and open `local-mac`.
2. Open Terminal, type `bash ` (with a trailing space), drag `Start.command` into Terminal, and press Return. This works even if ZIP extraction removes the executable flag. With an executable copy, you can also double-click `Start.command`.
3. The first launch installs Python packages. The reader opens at **http://127.0.0.1:8765**. Keep Terminal open while using it. Stop it with Control-C.
4. Record your voice right in the page: read the script in **Record your voice here**, press Stop, play it back, then press **Use this recording as my voice** (the transcript fills in automatically; your browser asks for microphone permission the first time). Or choose an existing voice file and press **Save voice sample on this Mac**. WebM, WAV, M4A, and MP3 are converted locally. Choose 3–30 seconds of clean speech; 5–15 seconds is a good starting point.
5. Enter the exact words in that sample. Paste a new passage and press **Generate in my voice**.

Python 3.10+ with Apple Silicon support is required; Python 3.11 is recommended. The launcher uses `python3`. Initial package installation and the first model download require internet and several GB of free disk space. The first generation can take several minutes. Subsequent narration uses the downloaded model locally. A service may still be required by the browser for optional spoken commands; narration itself runs on the Mac.

## Storage and privacy

The server binds only to 127.0.0.1 and rejects foreign origins, unexpected hosts, and missing session tokens for writes. Sample audio, its transcript, and model downloads remain in `private-data/`, which is excluded from Git. Generated narration is returned to your browser; use Download narration to save it. No sample or API key is included in the public repository. Only load recordings you intend to keep in this local app folder.

The sample transcript must match the recording. This version does not automatically transcribe audio or highlight generated words. Generate passages of at most 3,000 characters; use multiple passages for longer works. Voice resemblance, speed, pronunciation, and model compatibility require a real generation test on your Mac.

## Verification

Run `python3 -m unittest discover -s local-mac -p 'test_*.py'` from the repository root. The tests cover request authorization, input validation, concurrency, and the audio response using a simulated model. They do not validate voice quality.

During preparation, dependency installation and sample download were blocked in the assistant environment, so actual model generation has not been tested. The launcher performs installation directly from your Terminal.

## References

- https://github.com/Blaizzy/mlx-audio/blob/main/docs/guides/voice-cloning.md
- https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16
