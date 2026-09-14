"""Rejection-path tests for the localhost signing bridge.

The bridge signs mainnet transactions, so every way a request can be turned
away is covered here: wrong path, wrong or missing token, wrong or missing
Origin, an oversized body, and a body that is not a JSON object.
"""
import base64
import http.client
from pathlib import Path
import queue
import sys
import threading
import unittest
import urllib.parse

sys.path.insert(0, str(Path(__file__).parent))
import sign_in_browser

TRANSACTION_B64 = base64.b64encode(b'unsigned-transaction-bytes').decode()
EXPECTED_SIGNER = 'So11111111111111111111111111111111111111112'


class SigningBridgeTests(unittest.TestCase):
    def setUp(self):
        self.bridge = sign_in_browser.build_bridge(TRANSACTION_B64, EXPECTED_SIGNER)
        self.port = self.bridge.server.server_address[1]
        self.page_path = urllib.parse.urlsplit(self.bridge.url).path
        self.origin = f'http://127.0.0.1:{self.port}'
        self.addCleanup(self.bridge.server.server_close)
        self.addCleanup(self.bridge.server.shutdown)
        threading.Thread(target=self.bridge.server.serve_forever, daemon=True).start()

    def authorized_headers(self):
        return {'X-Bridge-Token': self.bridge.token, 'Origin': self.origin}

    def send(self, method, path, headers=None, body=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        self.addCleanup(connection.close)
        connection.request(method, path, body=body, headers=headers or {})
        return connection.getresponse()

    def post_report(self, headers, body=b'{"signature": "abc"}'):
        return self.send('POST', self.bridge.done_path, headers, body)

    def assert_nothing_reported(self):
        with self.assertRaises(queue.Empty):
            self.bridge.reports.get(timeout=0.2)

    def test_page_is_served_only_on_the_secret_path(self):
        response = self.send('GET', self.page_path)
        self.assertEqual(response.status, 200)
        self.assertIn(b'Mesh Subscription Controller', response.read())

        for path in ('/', '/done', self.bridge.done_path,
                     self.page_path + 'x', self.page_path[:-1]):
            with self.subTest(path=path):
                self.assertEqual(self.send('GET', path).status, 404)

    def test_authorized_report_is_accepted(self):
        response = self.post_report(self.authorized_headers())
        self.assertEqual(response.status, 200)
        self.assertEqual(self.bridge.reports.get(timeout=5), {'signature': 'abc'})

    def test_report_on_the_wrong_path_is_rejected(self):
        for path in ('/', '/done', self.page_path, self.bridge.done_path + 'x'):
            with self.subTest(path=path):
                response = self.send('POST', path, self.authorized_headers(),
                                     b'{"signature": "abc"}')
                self.assertEqual(response.status, 404)
        self.assert_nothing_reported()

    def test_report_without_the_token_header_is_rejected(self):
        headers = self.authorized_headers()
        del headers['X-Bridge-Token']
        self.assertEqual(self.post_report(headers).status, 404)
        self.assert_nothing_reported()

    def test_report_with_a_wrong_token_is_rejected(self):
        for token in ('', 'x' * len(self.bridge.token), self.bridge.token[:-1],
                      self.bridge.token + 'x'):
            with self.subTest(token=token):
                headers = self.authorized_headers()
                headers['X-Bridge-Token'] = token
                self.assertEqual(self.post_report(headers).status, 404)
        self.assert_nothing_reported()

    def test_report_without_an_origin_is_rejected(self):
        headers = self.authorized_headers()
        del headers['Origin']
        self.assertEqual(self.post_report(headers).status, 404)
        self.assert_nothing_reported()

    def test_report_from_a_foreign_origin_is_rejected(self):
        for origin in ('', 'null', 'http://evil.example',
                       f'http://evil.example:{self.port}',
                       f'https://127.0.0.1:{self.port}'):
            with self.subTest(origin=origin):
                headers = self.authorized_headers()
                headers['Origin'] = origin
                self.assertEqual(self.post_report(headers).status, 404)
        self.assert_nothing_reported()

    def test_localhost_origin_is_accepted(self):
        headers = self.authorized_headers()
        headers['Origin'] = f'http://localhost:{self.port}'
        self.assertEqual(self.post_report(headers).status, 200)
        self.assertEqual(self.bridge.reports.get(timeout=5), {'signature': 'abc'})

    def test_oversized_report_is_rejected_without_being_read(self):
        headers = self.authorized_headers()
        headers['Content-Length'] = str(sign_in_browser.MAX_REPORT_BYTES + 1)
        response = self.send('POST', self.bridge.done_path, headers, b'{}')
        self.assertEqual(response.status, 413)
        self.assert_nothing_reported()

    def test_unusable_content_length_is_rejected(self):
        for length in ('abc', '-1', ''):
            with self.subTest(length=length):
                headers = self.authorized_headers()
                headers['Content-Length'] = length
                response = self.send('POST', self.bridge.done_path, headers, b'{}')
                self.assertEqual(response.status, 413)
        self.assert_nothing_reported()

    def test_body_that_is_not_a_json_object_is_reported_as_an_error(self):
        for body in (b'{not json', b'[1, 2]', b'"text"', b'null', b'\xff\xfe',
                     b'[["signature", "forged"]]', b'[["error", "forged"]]'):
            with self.subTest(body=body):
                response = self.post_report(self.authorized_headers(), body)
                self.assertEqual(response.status, 200)
                self.assertEqual(self.bridge.reports.get(timeout=5),
                                 {'error': 'malformed response from the page'})

    def test_empty_body_is_reported_as_an_empty_result(self):
        response = self.post_report(self.authorized_headers(), b'')
        self.assertEqual(response.status, 200)
        self.assertEqual(self.bridge.reports.get(timeout=5), {})

    def test_page_never_embeds_the_token_of_another_bridge(self):
        other = sign_in_browser.build_bridge(TRANSACTION_B64, EXPECTED_SIGNER)
        self.addCleanup(other.server.server_close)
        page = self.send('GET', self.page_path).read().decode()
        self.assertIn(self.bridge.token, page)
        self.assertNotIn(other.token, page)


if __name__ == '__main__':
    unittest.main()
