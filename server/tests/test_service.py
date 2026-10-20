import asyncio
import json
import unittest
from datetime import timedelta

from tests.helpers import TempDirTestCase, now, png, run, stamps, until
from xcreen_server.service import InvalidRequest, XCreenService
from xcreen_server.store import BATCH_IMAGES


class ServiceTestCase(TempDirTestCase):
    def service(self, mode="ok", **kwargs) -> XCreenService:
        return XCreenService(self.config(), encoder=None, launch_override=self.fake_launch(mode), **kwargs)

    @staticmethod
    def upload(service, count=BATCH_IMAGES):
        times = stamps(count, now() - timedelta(minutes=10))
        service.ingest_ocr([{"id": f"ocr-{n}", "timestamp": t, "text": f"window text {n}", "app": "com.app", "title": "Doc"} for n, t in enumerate(times)])
        for n, moment in enumerate(times):
            service.ingest_image(f"image-{n}", moment, png(seed=n))
        return times


class ConnectionTests(ServiceTestCase):
    def test_connect_resumes_session_hides_it_and_applies_default_model(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.connection("connect")
            status = service.status()
            self.assertTrue(status["hermes"]["connected"])
            self.assertEqual(status["hermes"]["session"], "stored-1")
            self.assertFalse(status["session_visible_confirmed"])
            self.assertTrue(status["model"]["applied"])
            await service.connection("disconnect")
            await service.connection("connect")  # resumes the stored session
            self.assertIn("session.resume", self.requests())
            await service.stop()
        run(scenario())

    def test_unavailable_default_is_reported_without_fallback(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.set_default_model("openai", "gpt-x")  # offline: saved for the next connect
            await service.connection("connect")
            status = service.status()
            self.assertFalse(status["model"]["applied"])
            self.assertIn("no fallback", status["model"]["status"])
            self.assertNotIn("config.set", self.requests())
            await service.stop()
        run(scenario())

    def test_default_alternatives_are_suggested_by_model_leaf(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.set_default_model("openrouter-x", "claude-haiku-5.5")
            await service.connection("connect")
            self.assertIn("anthropic · claude-haiku-5-5", service.status()["model"]["status"])
            await service.stop()
        run(scenario())

    def test_selecting_a_model_switches_the_session_and_persists_the_default(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.select_model("anthropic", "claude-sonnet-5-5")
            self.assertEqual(service.status()["model"]["default"], {"provider": "anthropic", "model": "claude-sonnet-5-5"})
            with self.assertRaises(Exception):
                await service.select_model("nope", "nothing")
            await service.stop()
        run(scenario())

    def test_visibility_is_saved_and_confirmed(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.set_visible(True)  # offline: saved only
            self.assertTrue(service.status()["visibility_pending"])
            await service.connection("connect")
            self.assertTrue(service.status()["session_visible_confirmed"])
            await service.stop()
        run(scenario())


class QuestionTests(ServiceTestCase):
    def test_ask_streams_and_completes(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            record = service.ask("What did I read?")
            result = await service.wait_turn(record.id, -1, 10_000)
            while not result["done"]:
                result = await service.wait_turn(record.id, result["version"], 10_000)
            self.assertEqual(result["state"], "completed")
            self.assertEqual(result["text"], "Hello there")
            self.assertIn("xcreen.batch.context", self.requests())
            self.assertIsNone(service.active_turn)
            self.assertEqual(service.status()["model"]["current"], {"provider": "anthropic", "model": "claude-haiku-5-5"})
            await service.stop()
        run(scenario())

    def test_only_one_question_at_a_time_and_cancel(self):
        async def scenario():
            service = self.service("hang")
            await service.start(connect=False)
            record = service.ask("first")
            with self.assertRaises(InvalidRequest):
                service.ask("second")
            await until(lambda: "prompt.submit" in self.requests())
            await service.cancel()
            result = await service.wait_turn(record.id, -1, 10_000)
            while not result["done"]:
                result = await service.wait_turn(record.id, result["version"], 10_000)
            self.assertEqual(result["state"], "cancelled")
            self.assertIn("session.interrupt", self.requests())
            await service.stop()
        run(scenario())


class DigestTests(ServiceTestCase):
    def test_integrity_defaults_on_and_blocks_digests(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            self.assertTrue(service.integrity)
            self.upload(service)
            await asyncio.sleep(0.3)
            self.assertEqual(service.store.counts()["pending"], 1)
            self.assertNotIn("prompt.submit", self.requests())
            await service.stop()
        run(scenario())

    def test_batch_digests_with_verified_receipt_once_integrity_is_off(self):
        async def scenario():
            service = self.service("saved")
            await service.start(connect=False)
            self.upload(service)
            await service.report_capture("running", "", False)
            await until(lambda: service.store.counts()["completed"] == 1)
            requests = self.requests()
            self.assertEqual(requests.count("image.attach_bytes"), BATCH_IMAGES)
            self.assertLess(requests.index("xcreen.batch.prepare"), requests.index("prompt.submit"))
            self.assertIn("xcreen.batch.receipt", requests)
            record = service.store.batches[0]
            self.assertEqual(record.receipt.effect_count, 1)
            self.assertEqual(json.loads(service.store.status_path.read_text())["desired_integrity"], "off")
            await service.stop()
        run(scenario())

    def test_model_watch_applies_default_on_its_own_timer(self):
        async def scenario():
            service = self.service()
            service.model_check_interval = 0.1
            await service.set_default_model("openai", "gpt-x")
            await service.start(connect=False)
            await service.connection("connect")
            self.assertFalse(service.controller.model_applied)
            service.state.set(model_default={"provider": "anthropic", "model": "claude-sonnet-5-5"})
            await until(lambda: service.controller.model_applied, timeout=5)
            await service.stop()
        run(scenario())

    def test_pipeline_connecting_itself_still_respects_the_model_gate(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.set_default_model("openai", "gpt-x")
            await service.report_capture("running", "", False)
            self.upload(service)  # pipeline connects on its own
            await until(lambda: service.controller.connected)
            await asyncio.sleep(0.3)
            self.assertNotIn("prompt.submit", self.requests())
            self.assertEqual(service.store.counts()["pending"], 1)
            await service.stop()
        run(scenario())

    def test_digests_wait_for_the_default_model_and_resume_when_it_appears(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.set_default_model("openai", "gpt-x")  # not in the inventory
            await service.connection("connect")
            await service.report_capture("running", "", False)
            self.upload(service)
            await asyncio.sleep(0.3)
            self.assertNotIn("prompt.submit", self.requests())
            self.assertIn("default model", service.status()["digest_hold"])
            service.state.set(model_default={"provider": "anthropic", "model": "claude-sonnet-5-5"})  # now configured
            self.assertTrue(await service.controller.refresh_model())
            service.pipeline.kick()
            await until(lambda: service.store.counts()["completed"] == 1)
            self.assertEqual(service.status()["digest_hold"], "")
            await service.stop()
        run(scenario())

    def test_oversized_screenshot_is_attached_as_a_jpeg_copy(self):
        class Encoder:
            name = "fake"
            async def encode(self, path, quality=None):
                assert quality == 85
                return b"\xff\xd8\xff\xe0" + b"\0" * 16

        async def scenario():
            service = XCreenService(self.config(), encoder=Encoder(), launch_override=self.fake_launch("ok"))
            service.pipeline.attachment_limit = 40  # every test PNG is larger than this
            await service.start(connect=False)
            self.upload(service)
            await service.report_capture("running", "", False)
            await until(lambda: service.store.counts()["completed"] == 1)
            log = [json.loads(line) for line in self.gateway_log.read_text().splitlines()]
            names = [entry["filename"] for entry in log if entry["method"] == "image.attach_bytes"]
            self.assertEqual(len(names), BATCH_IMAGES)
            self.assertTrue(all(name.endswith(".jpg") for name in names))
            attach = service.store.root / ".attach"
            await until(lambda: not attach.exists() or not any(attach.iterdir()))  # cleaned up right after the send
            self.assertTrue(all(i.path.suffix == ".png" and i.path.exists() for i in service.store.images))
            await service.stop()
        run(scenario())

    def test_oversized_screenshot_without_encoder_fails_clearly_without_resend(self):
        async def scenario():
            service = self.service()
            service.pipeline.attachment_limit = 40
            await service.start(connect=False)
            self.upload(service)
            await service.report_capture("running", "", False)
            await until(lambda: "JPEG encoder" in service.pipeline.message or service.store.counts()["pending"] == 0)
            self.assertNotIn("prompt.submit", self.requests())
            await service.stop()
        run(scenario())

    def test_provider_rate_limit_with_zero_effects_backs_off(self):
        async def scenario():
            service = self.service("429")
            await service.start(connect=False)
            await service.report_capture("running", "", False)
            self.upload(service)
            await until(lambda: service.store.throttle_until is not None)
            self.assertEqual(service.store.counts()["pending"], 1)
            self.assertIsNotNone(service.status()["next_retry"])
            self.assertIn("rate-limited", service.status()["message"])
            await service.stop()
        run(scenario())

    def test_integrity_on_interrupts_a_running_digest(self):
        async def scenario():
            service = self.service("hang")
            await service.start(connect=False)
            await service.report_capture("running", "", False)
            self.upload(service)
            await until(lambda: "prompt.submit" in self.requests())
            await service.report_capture("paused", "Integrity mode", True)
            await until(lambda: service.store.counts()["uncertain"] == 1)
            self.assertIn("session.interrupt", self.requests())
            await service.stop()
        run(scenario())

    def test_restart_verifies_receipts_without_resending(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.report_capture("running", "", False)
            self.upload(service)
            await until(lambda: service.store.counts()["completed"] == 1)
            await service.stop()
            submits = self.requests().count("prompt.submit")
            again = self.service()
            await again.start(connect=False)
            self.assertEqual(await again.verify(), 0)  # fresh fake host has no receipt: invalidated
            self.assertEqual(again.store.counts()["uncertain"], 1)
            self.assertEqual(self.requests().count("prompt.submit"), submits)
            await again.stop()
        run(scenario())

    def test_hard_compaction_runs_when_idle_above_threshold(self):
        async def scenario():
            service = self.service()
            await service.start(connect=False)
            await service.connection("connect")
            service.runtime.update_usage(600_000, 1_000_000)
            await until(lambda: service.runtime.hard_compactions == 1)
            log = [json.loads(line) for line in self.gateway_log.read_text().splitlines()]
            self.assertIn({"method": "session.compress", "focus_topic": "here 2"}, log)
            await service.stop()
        run(scenario())


if __name__ == "__main__":
    unittest.main()
