#!/usr/bin/env python3
"""Localhost signing bridge: opens the default browser so the user's wallet
signs and sends a transaction built by admin-cli. Works with any Wallet
Standard wallet (Phantom, Solflare, Backpack, MetaMask-Solana, ...) — the
private key never leaves the wallet extension; upgrading later to a Ledger
*inside* one of those wallets needs no change here.

Usage: sign_in_browser.py <base64-unsigned-tx> <expected-signer-pubkey>
Prints the base58 transaction signature on success; exits non-zero otherwise.
"""
import http.server
import json
import secrets
import sys
import time
import webbrowser

MAX_REPORT_BYTES = 64 * 1024

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Sign transaction</title>
<style>
body{font-family:system-ui;margin:3rem auto;max-width:640px;line-height:1.5}
button{display:block;margin:.5rem 0;padding:.6rem 1.4rem;font-size:1rem;cursor:pointer}
code{background:rgba(127,127,127,.15);padding:0 .3em;border-radius:3px}
#status{margin-top:1rem;white-space:pre-wrap}
</style></head><body>
<h2>Mesh Subscription Controller — sign transaction</h2>
<p>Expected signer: <code>__EXPECTED__</code></p>
<div id="wallets"><em>Looking for wallets&hellip;</em></div>
<div id="status"></div>
<script>
const TX_B64 = "__TX_B64__";
const EXPECTED = "__EXPECTED__";
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
    await fetch('__TOKEN_PATH__/done', {
      method: 'POST',
      headers: { 'X-Bridge-Token': '__TOKEN__' },
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
    # Anything on this machine can reach a localhost port, and a page in the
    # browser can POST to one cross-origin. The unguessable path keeps the
    # unsigned transaction from being read, and the custom header forces a
    # CORS preflight that is never answered, so only our own page can report.
    token = secrets.token_urlsafe(24)
    token_path = f"/{token}"
    token_bytes = token.encode()
    done_path = f"{token_path}/done"
    allowed_origins = set()
    page = (
        PAGE.replace("__TX_B64__", sys.argv[1])
        .replace("__EXPECTED__", sys.argv[2])
        .replace("__TOKEN_PATH__", token_path)
        .replace("__TOKEN__", token)
    )
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        # Without this the base class leaves the socket blocking, so one idle
        # connection holds the single-threaded server past its own deadline.
        timeout = 10

        def do_GET(self):
            if self.path == token_path:
                body = page.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            origin = self.headers.get("Origin")
            authorized = (
                self.path == done_path
                and secrets.compare_digest(
                    self.headers.get("X-Bridge-Token", "").encode("utf-8", "replace"),
                    token_bytes,
                )
                and (origin is None or origin in allowed_origins)
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
            try:
                result.update(json.loads(self.rfile.read(n) or b"{}"))
            except Exception:
                result.update({"error": "malformed response from the page"})
            self.send_response(200)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    allowed_origins.update({f"http://127.0.0.1:{port}", f"http://localhost:{port}"})
    url = f"http://127.0.0.1:{port}{token_path}"
    print(f"sign in your browser: {url}  (waiting up to 180s)", file=sys.stderr)
    webbrowser.open(url)
    server.timeout = 1
    deadline = time.time() + 180
    while time.time() < deadline and not result:
        server.handle_request()
    server.server_close()

    if result.get("signature"):
        print(result["signature"])
    elif result.get("error"):
        sys.exit(f"error: wallet reported: {result['error']}")
    else:
        sys.exit("error: timed out waiting for the wallet signature")


if __name__ == "__main__":
    main()
