import asyncio
import json
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from datetime import timedelta

from tests.helpers import TempDirTestCase, now, png, stamps
from xcreen_server import PROTOCOL
from xcreen_server.api import serve
from xcreen_server.service import XCreenService
from xcreen_server.store import BATCH_IMAGES

TOKEN = "t" * 43


class APITestCase(TempDirTestCase):
    mode = "ok"

    def setUp(self):
        super().setUp()
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        config = self.config()

        async def build():
            service = XCreenService(config, encoder=None, launch_override=self.fake_launch(self.mode))
            await service.start(connect=False)
            return service
        self.service = asyncio.run_coroutine_threadsafe(build(), self.loop).result(10)
        self.server = serve(self.service, self.loop, TOKEN, "127.0.0.1", 0)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        asyncio.run_coroutine_threadsafe(self.service.stop(), self.loop).result(10)
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(5)
        super().tearDown()

    def call(self, method, path, body=None, *, token=TOKEN, raw=None, content_type="application/json"):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        request = urllib.request.Request(self.base + path, data=data, method=method)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        if data is not None:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                return response.status, (json.loads(payload) if response.headers["Content-Type"] == "application/json" else payload)
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def upload(self, count=BATCH_IMAGES):
        times = stamps(count, now() - timedelta(minutes=10))
        items = [{"id": f"ocr-{n}", "timestamp": t.isoformat(), "text": f"text {n}", "app": "com.app", "title": "Doc"} for n, t in enumerate(times)]
        self.assertEqual(self.call("POST", "/v1/ocr", {"items": items})[0], 200)
        for n, moment in enumerate(times):
            stamp = moment.isoformat().replace("+00:00", "Z")
            status, body = self.call("PUT", f"/v1/images/image-{n}?timestamp={stamp}", raw=png(seed=n), content_type="image/png")
            self.assertEqual(status, 200, body)
        return times

    def wait(self, predicate, timeout=10):
        import time
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("condition not reached")


class AuthTests(APITestCase):
    def test_health_is_open_everything_else_needs_the_token(self):
        status, body = self.call("GET", "/v1/health", token=None)
        self.assertEqual((status, body["protocol"]), (200, PROTOCOL))
        self.assertEqual(self.call("GET", "/v1/status", token=None)[0], 401)
        self.assertEqual(self.call("GET", "/v1/status", token="wrong" * 9)[0], 401)
        status, body = self.call("GET", "/v1/status")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"]["protocol"], PROTOCOL)
        self.assertTrue(body["status"]["integrity"])


class UploadTests(APITestCase):
    def test_upload_forms_a_batch_that_digests_after_integrity_off(self):
        self.upload()
        status = self.call("GET", "/v1/status")[1]["status"]
        self.assertEqual(status["batches"]["pending"], 1)
        self.assertEqual(self.call("POST", "/v1/capture", {"capture": "running", "reason": "", "integrity": False})[0], 200)
        self.wait(lambda: self.call("GET", "/v1/status")[1]["status"]["batches"]["completed"] == 1)
        rows = self.call("GET", "/v1/batches")[1]["batches"]
        self.assertEqual(rows[0]["state"], "completed")
        self.assertEqual(rows[0]["receipt"], {"status": "skipped", "verified": True, "effects": 0})

    def test_upload_is_idempotent_and_validated(self):
        moment = now().isoformat()
        quoted = urllib.parse.quote(moment)
        item = {"id": "ocr-1", "timestamp": moment, "text": "x", "app": "", "title": ""}
        self.assertEqual(self.call("POST", "/v1/ocr", {"items": [item]})[1]["accepted"], 1)
        self.assertEqual(self.call("POST", "/v1/ocr", {"items": [item]})[1]["duplicates"], 1)
        self.assertEqual(self.call("POST", "/v1/ocr", {"items": [dict(item, text="y")]})[0], 409)
        self.assertEqual(self.call("POST", "/v1/ocr", {"items": [dict(item, id="ocr-2", timestamp="yesterday")]})[0], 400)
        self.assertEqual(self.call("POST", "/v1/ocr", {"items": [dict(item, id="ocr-3", timestamp="2026-10-20T10:00:00")]})[0], 400)
        self.assertEqual(self.call("PUT", f"/v1/images/image-1?timestamp={quoted}", raw=b"not an image")[0], 400)
        self.assertEqual(self.call("POST", "/v1/ocr", raw=b"{" * 10)[0], 400)

    def test_image_download_and_unknown_routes(self):
        moment = urllib.parse.quote(now().isoformat())
        self.assertEqual(self.call("PUT", f"/v1/images/image-1?timestamp={moment}", raw=png())[0], 200)
        status, data = self.call("GET", "/v1/images/image-1")
        self.assertEqual((status, data), (200, png()))
        request = urllib.request.Request(self.base + "/v1/images/image-1", headers={"Authorization": f"Bearer {TOKEN}"})
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertTrue(response.headers["X-Xcreen-Captured-At"].startswith(now().strftime("%Y-%m-%d")[:4]))
        self.assertEqual(self.call("GET", "/v1/images/image-2")[0], 404)
        self.assertEqual(self.call("GET", "/v1/nothing")[0], 404)
        self.assertEqual(self.call("GET", "/v1/images/..%2Fetc")[0], 404)

    def test_oversized_body_is_refused_before_reading_it(self):
        import http.client
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        connection.putrequest("POST", "/v1/ocr")
        connection.putheader("Authorization", f"Bearer {TOKEN}")
        connection.putheader("Content-Length", "2000001")
        connection.endheaders()
        response = connection.getresponse()
        self.assertEqual(response.status, 413)
        self.assertEqual(json.loads(response.read())["error"]["code"], "too_large")
        self.assertEqual(response.getheader("Connection"), "close")


class SessionTests(APITestCase):
    def test_ask_and_long_poll(self):
        status, body = self.call("POST", "/v1/ask", {"question": "what was on screen?"})
        self.assertEqual(status, 200)
        turn = body["turn"]
        while not turn["done"]:
            turn = self.call("GET", f"/v1/turns/{turn['id']}?after={turn['version']}&wait_ms=5000")[1]["turn"]
        self.assertEqual((turn["state"], turn["text"]), ("completed", "Hello there"))
        self.assertEqual(self.call("POST", "/v1/cancel")[0], 400)

    def test_models_default_visibility_history_and_config(self):
        routes = self.call("GET", "/v1/models")[1]["routes"]
        self.assertIn({"provider": "anthropic", "model": "claude-sonnet-5-5"}, routes)
        status, body = self.call("PUT", "/v1/model/default", {"provider": "anthropic", "model": "claude-sonnet-5-5"})
        self.assertEqual(body["status"]["model"]["default"]["model"], "claude-sonnet-5-5")
        self.assertEqual(self.call("PUT", "/v1/model/default", {"provider": "x", "model": "y"})[0], 502)
        body = self.call("PUT", "/v1/session/visibility", {"visible": True})[1]
        self.assertTrue(body["status"]["session_visible_confirmed"])
        history = self.call("GET", "/v1/history")[1]["history"]
        self.assertEqual(history["count"], 2)
        self.assertIn("vault", self.call("GET", "/v1/config")[1]["config"])
        self.assertEqual(self.call("PUT", "/v1/config", {"token": "x"})[0], 400)


if __name__ == "__main__":
    unittest.main()
