import asyncio
import os
import struct
import sys
import tempfile
import unittest
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from xcreen_server.config import ServerConfig  # noqa: E402
from xcreen_server.gateway import Launch  # noqa: E402

FAKE = Path(__file__).resolve().parent / "fake_gateway.py"


def png(width: int = 8, height: int = 8, seed: int = 0) -> bytes:
    rows = b"".join(b"\x00" + bytes(((x + y + seed) % 256) for x in range(width * 3)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def now() -> datetime:
    return datetime.now(timezone.utc)


def stamps(count: int, start: datetime | None = None, step: float = 10) -> list[datetime]:
    start = start or now() - timedelta(minutes=30)
    return [start + timedelta(seconds=step * i) for i in range(count)]


class TempDirTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def config(self) -> ServerConfig:
        config = ServerConfig(data_dir=str(self.tmp / "evidence"), log_dir=str(self.tmp / "logs"))
        config.path = str(self.tmp / "server.json")
        return config

    def fake_launch(self, mode: str = "ok") -> Launch:
        self.gateway_log = self.tmp / "gateway-requests.jsonl"
        return Launch(sys.executable, (str(FAKE), mode, str(self.gateway_log)))

    def requests(self) -> list[str]:
        import json
        if not self.gateway_log.exists():
            return []
        return [json.loads(line)["method"] for line in self.gateway_log.read_text().splitlines()]


def run(coro, timeout: float = 20):
    return asyncio.run(asyncio.wait_for(coro, timeout))


async def until(predicate, timeout: float = 10, interval: float = 0.02):
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        if asyncio.get_running_loop().time() > deadline:
            raise AssertionError("condition not reached in time")
        await asyncio.sleep(interval)
