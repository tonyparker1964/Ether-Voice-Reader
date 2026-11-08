"""Ether Reader voice worker. Launched by the Ether Reader Mac app.

Protocol: one JSON request per line on stdin; replies are lines on stdout
prefixed with '@@ETHER '. Everything else (library output) goes to stderr.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import traceback

PROTO = sys.stdout
sys.stdout = sys.stderr  # keep library prints out of the protocol stream
MODEL_ID = os.environ.get('ETHER_MODEL', 'mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16')
model = None


def send(**fields):
    PROTO.write('@@ETHER ' + json.dumps(fields) + '\n')
    PROTO.flush()


def convert(src, dst):
    import imageio_ffmpeg
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-v', 'error', '-y', '-i', src, '-vn',
                    '-ac', '1', '-ar', '24000', '-t', '31', dst],
                   check=True, capture_output=True, timeout=120)


def split_text(text, limit=450):
    """Split into chunks of whole sentences, each at most `limit` characters."""
    pieces = []
    for paragraph in re.split(r'\n\s*\n', text):
        paragraph = ' '.join(paragraph.split())
        if not paragraph:
            continue
        for sentence in re.split(r'(?<=[.!?;:])\s+', paragraph):
            while len(sentence) > limit:
                cut = sentence.rfind(', ', 0, limit)
                cut = cut + 1 if cut > limit // 3 else sentence.rfind(' ', 0, limit)
                if cut <= 0:
                    cut = limit
                pieces.append(sentence[:cut].strip())
                sentence = sentence[cut:].strip()
            if sentence:
                pieces.append(sentence)
    chunks, current = [], ''
    for piece in pieces:
        if current and len(current) + 1 + len(piece) > limit:
            chunks.append(current)
            current = piece
        else:
            current = f'{current} {piece}'.strip()
    if current:
        chunks.append(current)
    return chunks


def loudness(data, rate, target_db=-16.0, ceiling=0.89):
    """Bring speech to a consistent, comfortable loudness with a soft limiter."""
    import numpy as np
    data = np.asarray(data, dtype=np.float32)
    if data.size == 0:
        return data
    frame = max(1, int(rate * 0.05))
    usable = data[: data.size - data.size % frame] if data.size >= frame else data
    frames = usable.reshape(-1, frame) if usable.size >= frame else usable.reshape(1, -1)
    rms = np.sqrt(np.mean(frames ** 2, axis=1))
    active = rms[rms > max(rms.max() * 0.05, 1e-5)]  # ignore silences
    if active.size == 0:
        return data
    speech_rms = float(np.sqrt(np.mean(active ** 2)))
    gain = min(10 ** (target_db / 20) / speech_rms, 31.6)  # at most +30 dB
    out = data * gain
    knee = ceiling * 0.8
    mag = np.abs(out)
    over = mag > knee
    out[over] = np.sign(out[over]) * (knee + (ceiling - knee) * np.tanh((mag[over] - knee) / (ceiling - knee)))
    return out


def speak(req):
    global model
    import numpy as np
    import soundfile as sf
    text, ref_text = str(req.get('text', '')).strip(), str(req.get('ref_text', '')).strip()
    if not text:
        raise ValueError('There is no text to read.')
    if not ref_text:
        raise ValueError('The voice sample needs its transcript.')
    chunks = split_text(text)
    with tempfile.TemporaryDirectory() as tmp:
        ref = os.path.join(tmp, 'reference.wav')
        send(event='status', message='Preparing your voice sample…')
        convert(req['ref_audio'], ref)
        if model is None:
            send(event='status', message='Loading the voice model. The first time, this downloads several GB…')
            from mlx_audio.tts.utils import load_model
            model = load_model(MODEL_ID)
        audio, rate = [], None
        for index, chunk in enumerate(chunks, 1):
            send(event='progress', done=index - 1, total=len(chunks),
                 message=f'Speaking part {index} of {len(chunks)}…')
            for result in model.generate(text=chunk, ref_audio=ref, ref_text=ref_text, max_tokens=4096):
                if rate is not None and rate != result.sample_rate:
                    raise RuntimeError('The model returned inconsistent sample rates.')
                rate = result.sample_rate
                audio.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
            if rate and index < len(chunks):
                audio.append(np.zeros(int(rate * 0.3), dtype=np.float32))
        if not audio or rate is None:
            raise RuntimeError('The model produced no audio.')
        data = np.clip(loudness(np.concatenate(audio), rate), -1.0, 1.0)
        sf.write(req['out'], data, rate, subtype='PCM_16')
    send(event='done', out=req['out'], seconds=round(len(data) / rate, 1), total=len(chunks))


def check():
    import imageio_ffmpeg, numpy, soundfile  # noqa: F401
    import mlx_audio  # noqa: F401
    print('Voice engine packages are installed.')


def serve():
    send(event='ready')
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            if request.get('cmd') == 'speak':
                speak(request)
            else:
                raise ValueError('Unknown request.')
        except Exception as exc:  # report every failure back to the app
            traceback.print_exc()
            send(event='error', message=f'{type(exc).__name__}: {exc}')


if __name__ == '__main__':
    if '--check' in sys.argv:
        check()
    else:
        serve()
