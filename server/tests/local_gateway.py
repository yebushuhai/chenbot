"""Loopback-only API gateway for the temporary Flutter development stack."""
import base64
from http.client import HTTPConnection, HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
from urllib.parse import parse_qs, urlsplit


def local_anon_key(secret):
    def encode(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=")

    header = encode(b'{"alg":"HS256","typ":"JWT"}')
    claims = encode(b'{"role":"anon","iss":"chenbot-local-dev"}')
    payload = header + b"." + claims
    signature = encode(hmac.digest(secret.encode(), payload, "sha256"))
    return (payload + b"." + signature).decode("ascii")


def gateway(auth_port, rest_port, anon_key, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body=b"", headers=()):
            self.send_response(status)
            for name, value in headers:
                self.send_header(name, value)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def forward(self):
            path = urlsplit(self.path)
            prefix, _, target = path.path[1:].partition("/v1/")
            allowed_auth = (
                self.command == "GET" and target in {"user", "settings"}
                or self.command == "POST" and target in {"otp", "verify", "logout"}
                or self.command == "POST" and target == "token"
                and parse_qs(path.query).get("grant_type") == ["refresh_token"]
            )
            if prefix == "auth" and allowed_auth:
                port = auth_port
            elif prefix == "rest" and self.command == "POST" and target.startswith("rpc/") and target[4:] in {
                "matching_me", "matching_enroll", "matching_connections", "matching_messages",
                "matching_send", "matching_safety", "matching_safety_history", "matching_delete",
                "blind_join", "blind_state", "blind_act", "secret_join", "secret_state", "secret_act",
            }:
                port = rest_port
            else:
                return self.reply(404)
            if not hmac.compare_digest(self.headers.get("apikey", "").encode(), anon_key.encode()):
                return self.reply(401)
            try:
                size = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self.reply(400)
            if self.headers.get("Transfer-Encoding") or not 0 <= size <= 65536:
                return self.reply(413)

            # Fixed loopback destinations. Forward only the headers the mobile API needs.
            headers = {name: self.headers[name] for name in
                       ("Authorization", "Content-Type", "Accept", "Prefer") if name in self.headers}
            upstream = HTTPConnection("127.0.0.1", port, timeout=15)
            try:
                upstream.request(self.command, "/" + target + ("?" + path.query if path.query else ""),
                                 body=self.rfile.read(size), headers=headers)
                result = upstream.getresponse()
                body = result.read()
                response_headers = [(k, v) for k, v in result.getheaders() if
                                    k.lower() in {"content-type", "content-range", "preference-applied"}]
            except (OSError, HTTPException):
                return self.reply(502)
            finally:
                upstream.close()
            self.reply(result.status, body, response_headers)

        do_POST = do_GET = forward

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)
