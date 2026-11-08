import io
import json
import unittest
from email.message import Message
from unittest.mock import patch
import server

class RequestTests(unittest.TestCase):
    def request(self, body, origin=server.ORIGIN, token=server.TOKEN, host=None, path='/api/speak'):
        h = server.Handler.__new__(server.Handler)
        h.path = path
        h.headers = Message()
        for k, v in {'Host': host or f'127.0.0.1:{server.PORT}', 'Origin': origin,
                     'X-Ether-Token': token, 'Content-Type': 'application/json',
                     'Content-Length': str(len(body))}.items():
            h.headers[k] = v
        h.rfile = io.BytesIO(body)
        result = []
        h.send = lambda *args: result.append(args)
        h.do_POST()
        return result[0]

    def test_foreign_origin_denied(self):
        self.assertEqual(self.request(b'{}', origin='https://example.com')[0], 403)

    def test_missing_token_denied(self):
        self.assertEqual(self.request(b'{}', token='')[0], 403)

    def test_dns_rebinding_host_denied(self):
        self.assertEqual(self.request(b'{}', host=f'evil.test:{server.PORT}')[0], 403)

    def test_malformed_json(self):
        self.assertEqual(self.request(b'{')[0], 400)

    def test_input_validation_before_model_load(self):
        for body in [{'text': '', 'transcript': 'hello'}, {'text': 'x'*3001, 'transcript': 'hello'},
                     {'text': 'hello', 'transcript': ''}, {'text': 42, 'transcript': 'hello'}]:
            with self.subTest(body_type=type(body['text'])):
                self.assertEqual(self.request(json.dumps(body).encode())[0], 400)

    def test_busy_request_rejected(self):
        with server.LOCK:
            self.assertEqual(self.request(b'{}')[0], 409)

    def test_audio_returned(self):
        with patch.object(server.Path, 'exists', return_value=True), \
             patch.object(server.Path, 'write_text'), \
             patch.object(server, 'synthesize', return_value=b'RIFF-example') as generate:
            result = self.request(json.dumps({'text': 'A new passage.', 'transcript': 'My sample.'}).encode())
            self.assertEqual(result, (200, b'RIFF-example', 'audio/wav'))
            generate.assert_called_once_with('A new passage.', 'My sample.')

if __name__ == '__main__':
    unittest.main()
