#!/usr/bin/env python3
"""Localhost signing bridge: opens the default browser so the user's wallet
signs and sends a transaction built by admin-cli. Works with any Wallet
Standard wallet (Phantom, Solflare, Backpack, MetaMask-Solana, ...) — the
private key never leaves the wallet extension; upgrading later to a Ledger
*inside* one of those wallets needs no change here.

Usage: sign_in_browser.py <base64-unsigned-tx> <expected-signer-pubkey>
Prints the base58 transaction signature on success; exits non-zero otherwise.
"""
import base64
import html
import http.server
import json
import queue
import secrets
import sys
import threading
import webbrowser

MAX_REPORT_BYTES = 64 * 1024
DEADLINE_SECONDS = 180
BASE58_ALPHABET = set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")


def js_literal(value):
    return (
        json.dumps(value)
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
    )


def looks_like_base58_pubkey(text):
    return 32 <= len(text) <= 44 and set(text) <= BASE58_ALPHABET


def looks_like_base64_transaction(text):
    try:
        return bool(base64.b64decode(text, validate=True))
    except ValueError:
        return False


def matches_secret(candidate, expected):
    return secrets.compare_digest(
        candidate.encode("utf-8", "replace"), expected.encode("utf-8")
    )

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Sign transaction</title>
<style>
body{font-family:system-ui;margin:3rem auto;max-width:640px;line-height:1.5}
button{display:block;margin:.5rem 0;padding:.6rem 1.4rem;font-size:1rem;cursor:pointer}
code{background:rgba(127,127,127,.15);padding:0 .3em;border-radius:3px}
#status{margin-top:1rem;white-space:pre-wrap}
</style></head><body>
<h2>Mesh Subscription Controller — sign transaction</h2>
<p>Expected signer: <code>__EXPECTED_HTML__</code></p>
<div id="wallets"><em>Looking for wallets&hellip;</em></div>
<div id="status"></div>
<script>
const TX_B64 = __TX_B64__;
const EXPECTED = __EXPECTED_JS__;
const txBytes = Uint8Array.from(atob(TX_B64), c => c.charCodeAt(0));

const A = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function b58(bytes) {
  let n = 0n;
  for (const b of bytes) n = n * 256n + BigInt(b);
  let s = '';
  while (n > 0n) { s = A[Number(n % 58n)] + s; n /= 58n; }
  for (const b of bytes) { if (b === 0) s = '1' + s; else break; }
  return s;
}

function status(msg) { document.getElementById('status').textContent = msg; }
async function report(obj) {
  try {
    await fetch(__DONE_PATH__, {
      method: 'POST',
      headers: { 'X-Bridge-Token': __TOKEN__ },
      body: JSON.stringify(obj),
    });
  } catch (e) {}
}

const seen = new Set();
function addWallet(w) {
  try {
    if (!w || !w.features) return;
    if (!w.features['solana:signAndSendTransaction'] || !w.features['standard:connect']) return;
    if (seen.has(w.name)) return;
    seen.add(w.name);
    const div = document.getElementById('wallets');
    if (seen.size === 1) div.innerHTML = '<p>Choose the wallet holding the expected signer:</p>';
    const btn = document.createElement('button');
    btn.textContent = w.name;
    btn.onclick = () => sign(w);
    div.appendChild(btn);
  } catch (e) {}
}

async function sign(wallet) {
  try {
    const { accounts } = await wallet.features['standard:connect'].connect();
    const account = accounts.find(a => a.address === EXPECTED);
    if (!account) {
      status('The connected ' + wallet.name + ' account is not ' + EXPECTED +
             ' — switch account in the wallet, then click the button again.');
      return;
    }
    status('Approve the transaction in ' + wallet.name + '\\u2026');
    const [res] = await wallet.features['solana:signAndSendTransaction'].signAndSendTransaction({
      transaction: txBytes,
      account,
      chain: 'solana:mainnet',
    });
    const sig = b58(res.signature);
    status('Signed & sent: ' + sig + '\\nYou can close this tab.');
    await report({ signature: sig });
  } catch (e) {
    status('Failed / rejected: ' + e + '\\nRe-run the script to retry.');
    await report({ error: String(e) });
  }
}

// Wallet Standard discovery dance: collect wallets that already announced
// themselves, and let late ones register too.
const api = { register: (...ws) => { ws.forEach(addWallet); return () => {}; } };
window.addEventListener('wallet-standard:register-wallet', (event) => {
  try { event.detail(api); } catch (e) {}
});
try { window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: api })); } catch (e) {}
setTimeout(() => {
  if (seen.size === 0) {
    document.getElementById('wallets').innerHTML =
      'No Wallet Standard wallet found — is Phantom / Solflare / Backpack installed and enabled in this browser?';
  }
}, 1500);
</script></body></html>
"""


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: sign_in_browser.py <base64-unsigned-tx> <expected-signer-pubkey>")
    unsigned_tx_b64, expected_signer = sys.argv[1], sys.argv[2]
    if not looks_like_base64_transaction(unsigned_tx_b64):
        sys.exit("error: unsigned transaction is not valid base64")
    if not looks_like_base58_pubkey(expected_signer):
        sys.exit(f"error: expected-signer-pubkey is not base58: {expected_signer!r}")
    # Anything on this machine can reach a localhost port, and a page in the
    # browser can POST to one cross-origin. The unguessable path keeps the
    # unsigned transaction from being read, and the custom header forces a
    # CORS preflight that is never answered, so only our own page can report.
    token = secrets.token_urlsafe(24)
    token_path = f"/{token}"
    done_path = f"{token_path}/done"
    allowed_origins = set()
    page = (
        PAGE.replace("__TX_B64__", js_literal(unsigned_tx_b64))
        .replace("__EXPECTED_HTML__", html.escape(expected_signer))
        .replace("__EXPECTED_JS__", js_literal(expected_signer))
        .replace("__DONE_PATH__", js_literal(done_path))
        .replace("__TOKEN__", js_literal(token))
    )
    reports = queue.Queue()

    class Handler(http.server.BaseHTTPRequestHandler):
        # Idle-recv timeout: it restarts on every byte, so it only drops a
        # socket that goes fully silent.
        timeout = 10

        def do_GET(self):
            if matches_secret(self.path, token_path):
                body = page.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            authorized = (
                matches_secret(self.path, done_path)
                and matches_secret(self.headers.get("X-Bridge-Token", ""), token)
                and self.headers.get("Origin") in allowed_origins
            )
            if not authorized:
                self.send_response(404)
                self.end_headers()
                return
            try:
                n = int(self.headers.get("Content-Length", 0))
            except ValueError:
                n = -1
            if not 0 <= n <= MAX_REPORT_BYTES:
                self.send_response(413)
                self.end_headers()
                return
            report = {}
            try:
                report.update(json.loads(self.rfile.read(n) or b"{}"))
            except Exception:
                report = {"error": "malformed response from the page"}
            reports.put(report)
            self.send_response(200)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    allowed_origins.update({f"http://127.0.0.1:{port}", f"http://localhost:{port}"})
    url = f"http://127.0.0.1:{port}{token_path}"
    print(
        f"sign in your browser: {url}  (waiting up to {DEADLINE_SECONDS}s)",
        file=sys.stderr,
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    webbrowser.open(url)
    try:
        result = reports.get(timeout=DEADLINE_SECONDS)
    except queue.Empty:
        result = {}
    server.shutdown()
    server.server_close()

    if result.get("signature"):
        print(result["signature"])
    elif result.get("error"):
        sys.exit(f"error: wallet reported: {result['error']}")
    else:
        sys.exit("error: timed out waiting for the wallet signature")


if __name__ == "__main__":
    main()
