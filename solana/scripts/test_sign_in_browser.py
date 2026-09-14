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
REAL_DEVNET_SIGNATURE = ('2VCoSZduGXRukPiUug9LAAnaPywjW5AeFu1rR4BXj5cGt'
                         'UodWvneXtcyXDVCWrbsrADknB8neZGUwLDfNeicXJwo')


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

    def test_build_bridge_rejects_inputs_that_fail_validation(self):
        for transaction, signer in ((TRANSACTION_B64, 'not base58!'),
                                    (TRANSACTION_B64, '__TOKEN__'),
                                    (TRANSACTION_B64, 'So111'),
                                    ('not base64!', EXPECTED_SIGNER),
                                    ('__TOKEN__', EXPECTED_SIGNER),
                                    ('', EXPECTED_SIGNER)):
            with self.subTest(transaction=transaction, signer=signer):
                with self.assertRaises(ValueError):
                    sign_in_browser.build_bridge(transaction, signer)

    def test_page_never_embeds_the_token_of_another_bridge(self):
        other = sign_in_browser.build_bridge(TRANSACTION_B64, EXPECTED_SIGNER)
        self.addCleanup(other.server.server_close)
        page = self.send('GET', self.page_path).read().decode()
        self.assertIn(self.bridge.token, page)
        self.assertNotIn(other.token, page)


class ReportReadingTests(unittest.TestCase):
    VALID_SIGNATURE = '5' * 88

    def test_a_base58_signature_is_returned(self):
        self.assertEqual(
            sign_in_browser.signature_from_report({'signature': self.VALID_SIGNATURE}),
            self.VALID_SIGNATURE)

    def test_a_signature_that_is_not_base58_is_rejected(self):
        for signature in ('', 'short', '0' * 88, 'l' * 88, '5' * 89,
                          'z' * 88, 'z' * 64, '1' * 63, '1' * 65,
                          self.VALID_SIGNATURE + '!', 'sig with spaces' * 6,
                          'x\ny' * 40, 42, True, ['5' * 88], {'a': 1}):
            with self.subTest(signature=signature):
                with self.assertRaises(ValueError) as caught:
                    sign_in_browser.signature_from_report({'signature': signature})
                self.assertIn('not base58', str(caught.exception))

    def test_a_pubkey_length_string_is_not_accepted_as_a_signature(self):
        with self.assertRaises(ValueError):
            sign_in_browser.signature_from_report({'signature': EXPECTED_SIGNER})

    def test_only_values_that_decode_to_64_bytes_are_signatures(self):
        for text in (REAL_DEVNET_SIGNATURE, '5' * 88, '1' * 64):
            with self.subTest(text=text):
                self.assertEqual(sign_in_browser.base58_decoded_length(text), 64)
                self.assertTrue(sign_in_browser.looks_like_base58_signature(text))
        for text, decoded in (('z' * 88, 65), ('z' * 64, 47), ('1' * 65, 65)):
            with self.subTest(text=text[0] * 3 + str(len(text))):
                self.assertEqual(sign_in_browser.base58_decoded_length(text), decoded)
                self.assertFalse(sign_in_browser.looks_like_base58_signature(text))

    def test_only_values_that_decode_to_32_bytes_are_pubkeys(self):
        self.assertEqual(sign_in_browser.base58_decoded_length(EXPECTED_SIGNER), 32)
        self.assertTrue(sign_in_browser.looks_like_base58_pubkey(EXPECTED_SIGNER))
        for text in ('z' * 44, REAL_DEVNET_SIGNATURE, '1' * 31):
            with self.subTest(text=text[:8]):
                self.assertFalse(sign_in_browser.looks_like_base58_pubkey(text))

    def test_a_reported_error_is_surfaced_and_truncated(self):
        with self.assertRaises(ValueError) as caught:
            sign_in_browser.signature_from_report({'error': 'user rejected'})
        self.assertIn('user rejected', str(caught.exception))

        with self.assertRaises(ValueError) as caught:
            sign_in_browser.signature_from_report({'error': 'z' * 5000})
        self.assertLess(len(str(caught.exception)), 300)

    def test_an_empty_report_is_a_timeout(self):
        with self.assertRaises(ValueError) as caught:
            sign_in_browser.signature_from_report({})
        self.assertIn('timed out', str(caught.exception))

    def test_a_valid_signature_never_wins_over_a_reported_error(self):
        for signature in (self.VALID_SIGNATURE, REAL_DEVNET_SIGNATURE, 'forged', ''):
            with self.subTest(signature=signature):
                with self.assertRaises(ValueError) as caught:
                    sign_in_browser.signature_from_report(
                        {'signature': signature, 'error': 'user rejected'})
                self.assertIn('error', str(caught.exception))

    def test_an_empty_error_does_not_block_a_good_signature(self):
        for empty in ('', None, 0):
            with self.subTest(error=empty):
                self.assertEqual(
                    sign_in_browser.signature_from_report(
                        {'signature': self.VALID_SIGNATURE, 'error': empty}),
                    self.VALID_SIGNATURE)


if __name__ == '__main__':
    unittest.main()
