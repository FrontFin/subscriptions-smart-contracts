"""Offline key-staging regression tests using public RFC 8032 test vectors."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('stage_key.py')
ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
# RFC 8032 section 7.1: public test data, never use these seeds for real funds.
VECTORS = (
    ('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
     'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'),
    ('4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
     '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c'),
)


def base58(raw):
    value = int.from_bytes(raw, 'big')
    encoded = ''
    while value:
        value, digit = divmod(value, 58)
        encoded = ALPHABET[digit] + encoded
    return '1' * (len(raw) - len(raw.lstrip(b'\x00'))) + encoded


class StageKeyTests(unittest.TestCase):
    def stage(self, secret, expected='', existing=False, no_site=False,
              existing_mode=None):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        out = Path(directory.name) / 'key.json'
        if existing:
            out.write_text('unchanged')
            if existing_mode is not None:
                os.chmod(out, existing_mode)
        env = dict(os.environ, SK=secret, EXPECTED=expected, OUT=str(out))
        command = [sys.executable]
        if no_site:
            command.append('-S')
        result = subprocess.run(command + [str(SCRIPT)], env=env, text=True,
                                capture_output=True)
        self.assertNotIn(secret, result.stdout + result.stderr)
        return result, out

    def test_rfc8032_vectors_write_expected_keypair(self):
        for seed, public in VECTORS:
            with self.subTest(public=public):
                raw = bytes.fromhex(seed + public)
                result, out = self.stage(base58(raw), base58(bytes.fromhex(public)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(out.read_text()), list(raw))
                if os.name == 'posix':
                    self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)

    @unittest.skipUnless(os.name == 'posix', 'file modes are POSIX-only')
    def test_existing_world_readable_output_is_tightened_to_owner_only(self):
        seed, public = VECTORS[0]
        raw = bytes.fromhex(seed + public)
        result, out = self.stage(base58(raw), base58(bytes.fromhex(public)),
                                 existing=True, existing_mode=0o644)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(out.read_text()), list(raw))
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)

    def test_forged_public_half_is_rejected_even_when_expected_matches(self):
        raw = bytes.fromhex(VECTORS[0][0] + VECTORS[1][1])
        for existing in (False, True):
            result, out = self.stage(base58(raw), base58(raw[32:]), existing=existing)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('malformed', result.stderr)
            if existing:
                self.assertEqual(out.read_text(), 'unchanged')
            else:
                self.assertFalse(out.exists())

    def test_wrong_wallet_does_not_overwrite_output(self):
        raw = bytes.fromhex(''.join(VECTORS[0]))
        expected = base58(bytes.fromhex(VECTORS[1][1]))
        result, out = self.stage(base58(raw), expected, existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('wrong key', result.stderr)
        self.assertEqual(out.read_text(), 'unchanged')

    def test_invalid_base58_does_not_write_output(self):
        result, out = self.stage('not-valid-base58!')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not valid base58', result.stderr)
        self.assertFalse(out.exists())

    def test_wrong_lengths_do_not_write_output(self):
        for length in (32, 63, 65):
            result, out = self.stage(base58(bytes(range(length))))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('expected a 64-byte', result.stderr)
            self.assertFalse(out.exists())

    def test_missing_dependency_fails_with_install_instructions(self):
        result, out = self.stage(base58(bytes.fromhex(''.join(VECTORS[0]))), no_site=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pip install -r solana/scripts/requirements.txt', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(out.exists())


if __name__ == '__main__':
    unittest.main()
