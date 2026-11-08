"""Local-only voice reader. Run with the bundled Start.command."""
import base64
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent
DATA = ROOT / 'private-data'
DATA.mkdir(mode=0o700, exist_ok=True)
PORT = int(os.environ.get('ETHER_PORT', '8765'))
ORIGIN = f'http://127.0.0.1:{PORT}'
TOKEN = secrets.token_urlsafe(32)
MODEL_ID = 'mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16'
LOCK = threading.Lock()
model = None

def convert_sample(encoded):
    import imageio_ffmpeg
    import soundfile as sf
    raw = base64.b64decode(encoded, validate=True)
    if not raw or len(raw) > 20 * 1024 * 1024:
        raise ValueError('Choose an audio sample smaller than 20 MB.')
    source, temporary = DATA / 'upload.audio', DATA / 'pending.wav'
    source.write_bytes(raw)
    try:
        subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-v', 'error', '-y', '-i', str(source),
                        '-vn', '-ac', '1', '-ar', '24000', '-t', '31', str(temporary)],
                       check=True, capture_output=True, timeout=60)
        info = sf.info(str(temporary))
        duration = info.frames / info.samplerate
        if duration < 3 or duration > 30:
            raise ValueError('Use 3–30 seconds of clean speech; 5–15 seconds is a good starting point.')
        temporary.replace(DATA / 'reference.wav')
        return round(duration, 1)
    finally:
        source.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)

def synthesize(text, transcript):
    global model
    import numpy as np
    import soundfile as sf
    from mlx_audio.tts.utils import load_model
    if model is None:
        model = load_model(MODEL_ID)
    pieces, sample_rate = [], None
    for result in model.generate(text=text, ref_audio=str(DATA / 'reference.wav'),
                                 ref_text=transcript, max_tokens=4096):
        if sample_rate is not None and sample_rate != result.sample_rate:
            raise RuntimeError('The model returned inconsistent sample rates.')
        sample_rate = result.sample_rate
        pieces.append(np.asarray(result.audio).reshape(-1))
    if not pieces:
        raise RuntimeError('The model produced no audio.')
    output = io.BytesIO()
    sf.write(output, np.concatenate(pieces), sample_rate, format='WAV')
    return output.getvalue()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Do not write sample text or narration text to logs.

    def send(self, status, payload, mime='application/json'):
        body = json.dumps(payload).encode() if mime == 'application/json' else payload
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def allowed_host(self):
        return self.headers.get('Host') == f'127.0.0.1:{PORT}'

    def do_GET(self):
        if not self.allowed_host():
            return self.send(403, {'error': 'Open the reader using its 127.0.0.1 address.'})
        if self.path == '/':
            page = (ROOT / 'index.html').read_text().replace('__TOKEN__', TOKEN)
            return self.send(200, page.encode(), 'text/html; charset=utf-8')
        if self.path == '/api/status':
            return self.send(200, {'sample': (DATA / 'reference.wav').exists(),
                'transcript': (DATA / 'transcript.txt').read_text() if (DATA / 'transcript.txt').exists() else '',
                'model': MODEL_ID, 'loaded': model is not None})
        return self.send(404, {'error': 'Not found'})

    def do_POST(self):
        if (not self.allowed_host() or self.headers.get('Origin') != ORIGIN
                or self.headers.get('X-Ether-Token') != TOKEN):
            return self.send(403, {'error': 'Open the local reader page to continue.'})
        if self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
            return self.send(415, {'error': 'JSON required.'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if size <= 0 or size > 28 * 1024 * 1024:
                return self.send(413, {'error': 'Request is too large or empty.'})
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise ValueError('Request must be an object.')
        except (ValueError, json.JSONDecodeError):
            return self.send(400, {'error': 'Invalid request.'})
        if not LOCK.acquire(blocking=False):
            return self.send(409, {'error': 'A voice operation is already running. Please wait.'})
        try:
            if self.path == '/api/sample':
                duration = convert_sample(body.get('audio', ''))
                (DATA / 'transcript.txt').unlink(missing_ok=True)
                return self.send(200, {'seconds': duration})
            if self.path == '/api/speak':
                text, transcript = body.get('text', ''), body.get('transcript', '')
                if not isinstance(text, str) or not isinstance(transcript, str):
                    raise ValueError('Text and transcript must be text.')
                text, transcript = text.strip(), transcript.strip()
                if not 1 <= len(text) <= 3000:
                    raise ValueError('Enter 1–3,000 characters for this passage.')
                if not 1 <= len(transcript) <= 3000:
                    raise ValueError('Enter the exact words spoken in your voice sample.')
                if not (DATA / 'reference.wav').exists():
                    raise ValueError('Load your voice sample first.')
                (DATA / 'transcript.txt').write_text(transcript)
                return self.send(200, synthesize(text, transcript), 'audio/wav')
            return self.send(404, {'error': 'Not found'})
        except ValueError as exc:
            return self.send(400, {'error': str(exc)})
        except Exception as exc:
            return self.send(500, {'error': f'Local voice operation failed ({type(exc).__name__}). Check model installation and internet access for the first model download.'})
        finally:
            LOCK.release()

if __name__ == '__main__':
    print(f'Ether Local Voice Reader: {ORIGIN}', flush=True)
    print('The first generation downloads the model. Keep this Terminal window open.', flush=True)
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
