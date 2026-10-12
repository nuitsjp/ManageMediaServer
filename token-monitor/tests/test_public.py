"""Exercise the real nginx proxy against an isolated Hub protocol fixture."""
import concurrent.futures
import http.server
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PUBLIC = ROOT / "token-monitor/public"
spec = importlib.util.spec_from_file_location("render_auth", PUBLIC / "render-auth.py")
render_auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render_auth)
check_spec = importlib.util.spec_from_file_location("public_check", PUBLIC / "check.py")
public_check = importlib.util.module_from_spec(check_spec)
check_spec.loader.exec_module(public_check)
SECRET = "PublicTestSecret_" + "aB2_" * 12


class Hub(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, data=None):
        raw = json.dumps(data or {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw) if code != 204 else 0))
        self.end_headers()
        if code != 204:
            self.wfile.write(raw)

    def handle_api(self):
        path = self.path.split("?", 1)[0]
        self.server.calls.append((self.command, path))
        if self.command == "OPTIONS":
            return self.reply(204)
        if path == "/api/health":
            return self.reply(200, {"ok": True, "role": "hub", "secretRequired": self.server.auth})
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.lower().startswith("bearer ") else self.headers.get("X-Token-Monitor-Secret", "").strip()
        if self.server.auth and token != SECRET:
            return self.reply(401)
        if path == "/api/failure":
            return self.reply(500, {"error": "private backend detail"})
        if path == "/api/stats/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                self.wfile.write(b'event: snapshot\ndata: {"stats":{}}\n\n')
                self.wfile.flush()
                while not self.server.finished.is_set():
                    time.sleep(0.1)
                    self.wfile.write(b": hb\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        return self.reply(200, {"devices": [], "method": self.command, "bytes": len(raw)})

    do_GET = handle_api
    do_POST = handle_api
    do_PUT = handle_api
    do_DELETE = handle_api
    do_OPTIONS = handle_api


@unittest.skipUnless(shutil.which("nginx"), "nginx is required for proxy integration tests")
class PublicProxyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.cleanup)
        self.folder = Path(self.temp.name)
        self.hub = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        self.hub.daemon_threads = True
        self.hub.auth = True
        self.hub.calls = []
        self.hub.finished = threading.Event()
        self.thread = threading.Thread(target=self.hub.serve_forever, daemon=True)
        self.thread.start()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.base = f"http://127.0.0.1:{port}"
        (self.folder / "auth.conf").write_text(render_auth.auth_config(SECRET))
        config = (PUBLIC / "nginx.conf").read_text()
        for before, after in [
            ("/etc/token-monitor-public/auth.conf", str(self.folder / "auth.conf")),
            ("/run/token-monitor-public", str(self.folder)),
            ("/var/log/token-monitor-public", str(self.folder)),
            ("127.0.0.1:17422", f"127.0.0.1:{port}"),
            ("127.0.0.1:17322", f"127.0.0.1:{self.hub.server_port}"),
        ]:
            config = config.replace(before, after)
        self.config = self.folder / "nginx.conf"
        self.config.write_text(config)
        validation = subprocess.run([shutil.which("nginx"), "-t", "-c", str(self.config)], capture_output=True, text=True)
        self.assertEqual(validation.returncode, 0, validation.stderr)
        self.nginx = subprocess.Popen([shutil.which("nginx"), "-c", str(self.config), "-g", "daemon off;"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                if self.call("/api/health")[0] == 200:
                    break
            except urllib.error.URLError:
                time.sleep(0.02)
        else:
            self.fail("nginx did not become ready")

    def cleanup(self):
        if hasattr(self, "nginx"):
            self.nginx.terminate()
            self.nginx.communicate(timeout=5)
        self.hub.finished.set()
        self.hub.shutdown()
        self.hub.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def call(self, path, headers=None, data=None, method=None):
        req = urllib.request.Request(self.base + path, headers=headers or {}, data=data, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.headers, error.read()

    def auth(self, **extra):
        return {"Authorization": "Bearer " + SECRET, **extra}

    def test_health_and_security_headers(self):
        status, headers, body = self.call("/api/health")
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["secretRequired"])
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertIn("max-age=", headers["Strict-Transport-Security"])
        self.assertNotIn("1.24", headers["Server"])

    def test_monitor_accepts_protected_proxy(self):
        with contextlib.redirect_stdout(io.StringIO()):
            public_check.check(self.base)

    def test_monitor_reports_disabled_backend_auth(self):
        self.hub.auth = False
        with self.assertRaisesRegex(ValueError, "authentication is disabled"):
            public_check.check(self.base)

    def test_bearer_and_alternate_header(self):
        for headers in (self.auth(), {"Authorization": "bEaReR " + SECRET}, {"X-Token-Monitor-Secret": SECRET}):
            self.assertEqual(self.call("/api/devices", headers)[0], 200)

    def test_authentication_stays_closed_if_backend_auth_is_disabled(self):
        self.hub.auth = False
        for headers in ({}, {"Authorization": "Bearer wrong"}, {"Authorization": "Bearer " + SECRET.swapcase()}, {"Authorization": "Bearer wrong", "X-Token-Monitor-Secret": SECRET}):
            self.assertEqual(self.call("/api/devices", headers)[0], 401)
        self.assertEqual(self.call("/api/devices", self.auth())[0], 200)

    def test_preflight_cors(self):
        status, headers, _ = self.call("/api/ingest", {"Origin": "null", "Access-Control-Request-Headers": "authorization,content-type"}, method="OPTIONS")
        self.assertEqual(status, 204)
        self.assertEqual(headers["Access-Control-Allow-Origin"], "*")
        self.assertIn("authorization", headers["Access-Control-Allow-Headers"])

    def test_sync_methods_and_payload(self):
        for method in ("POST", "PUT", "DELETE"):
            payload = b'{"deviceId":"test-device","usage":{}}'
            status, _, body = self.call("/api/ingest", self.auth(), payload, method)
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["method"], method)
            self.assertEqual(json.loads(body)["bytes"], len(payload))

    def test_large_upload_is_rejected_before_backend(self):
        self.assertEqual(self.call("/api/ingest", self.auth(), b"x" * (1024 * 1024 + 1), "POST")[0], 413)
        self.assertNotIn(("POST", "/api/ingest"), self.hub.calls)

    def test_failed_authentication_is_rate_limited_by_client_ip(self):
        headers = {"X-Forwarded-For": "198.51.100.8"}
        statuses = [self.call("/api/devices", headers)[0] for _ in range(70)]
        self.assertIn(401, statuses)
        self.assertIn(429, statuses)
        self.assertEqual(self.call("/api/devices", {"X-Forwarded-For": "198.51.100.9"})[0], 401)

    def test_global_rate_limit_applies_across_client_ips(self):
        def send(i):
            return self.call("/api/devices", {"X-Forwarded-For": f"198.51.{i // 250}.{i % 250 + 1}"})[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            statuses = list(pool.map(send, range(220)))
        self.assertIn(429, statuses)

    def test_unknown_paths_are_rate_limited(self):
        statuses = [self.call("/unknown", {"X-Forwarded-For": "198.51.100.15"})[0] for _ in range(70)]
        self.assertIn(404, statuses)
        self.assertIn(429, statuses)

    def test_stream_is_delivered_and_concurrent_streams_are_limited(self):
        streams = []
        try:
            for _ in range(20):
                request = urllib.request.Request(self.base + "/api/stats/stream", headers=self.auth(**{"X-Forwarded-For": "198.51.100.10"}))
                response = urllib.request.urlopen(request, timeout=5)
                streams.append(response)
                self.assertEqual(response.headers.get_content_type(), "text/event-stream")
                self.assertEqual(response.readline(), b"event: snapshot\n")
            self.assertEqual(self.call("/api/stats/stream", self.auth(**{"X-Forwarded-For": "198.51.100.10"}))[0], 429)
        finally:
            for response in streams:
                response.close()

    def test_access_log_excludes_query_and_credentials(self):
        query = "QueryTokenMustNotAppear"
        self.assertEqual(self.call("/api/devices?token=" + query, self.auth())[0], 200)
        log = (self.folder / "access.log").read_text()
        self.assertNotIn(query, log)
        self.assertNotIn(SECRET, log)
        self.assertIn("/api/devices 200", log)

    def test_backend_errors_are_hidden(self):
        status, _, body = self.call("/api/failure", self.auth())
        self.assertEqual(status, 503)
        self.assertEqual(json.loads(body), {"error": "service_unavailable"})

    def test_internal_auth_endpoint_cannot_be_called_directly(self):
        self.assertEqual(self.call("/_public_auth", self.auth())[0], 404)


class SecretValidationTests(unittest.TestCase):
    def test_weak_or_directive_bearing_values_are_rejected(self):
        for secret in ("", "change-me", 'x' * 32 + '"; include /tmp/evil;', "replace-with-openssl-rand-hex-32"):
            with self.assertRaises(ValueError):
                render_auth.auth_config(secret)


if __name__ == "__main__":
    unittest.main()
