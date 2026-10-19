"""Recompression of digested screenshots (strategy pattern).

The digest always sees the lossless capture; only retained evidence for later
questions is lossy. Quality settings were measured on real screenshots with Apple
Vision OCR: mozjpeg q30 kept ~95% of readable words at ~1/8 of the PNG size;
standard libjpeg needs about q20 for the same word retention.
"""
from __future__ import annotations

import asyncio
import io
import logging
import os
from pathlib import Path

from .store import JPEG_MAGIC, MAX_IMAGE_BYTES, EvidenceStore

log = logging.getLogger("xcreen.images")


class EncodingFailed(Exception):
    pass


class ImageEncoder:
    name = "none"

    async def encode(self, path: Path) -> bytes:  # pragma: no cover - interface
        raise NotImplementedError


class MozJPEGEncoder(ImageEncoder):
    """mozjpeg's ``cjpeg`` reads PNG directly. Fixed install locations only, never PATH."""
    name = "mozjpeg"
    quality = 30
    candidates = ("/opt/homebrew/opt/mozjpeg/bin/cjpeg", "/usr/local/opt/mozjpeg/bin/cjpeg", "/opt/mozjpeg/bin/cjpeg")

    def __init__(self, executable: str):
        self.executable = executable

    @classmethod
    def locate(cls, candidates=None) -> "MozJPEGEncoder | None":
        for path in candidates or cls.candidates:
            resolved = os.path.realpath(path)
            if os.path.isfile(resolved) and os.access(resolved, os.X_OK):
                return cls(resolved)
        return None

    async def encode(self, path: Path) -> bytes:
        process = await asyncio.create_subprocess_exec(self.executable, "-quality", str(self.quality), str(path),
                                                       stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                                                       stderr=asyncio.subprocess.DEVNULL, env={})
        try:
            data, _ = await asyncio.wait_for(process.communicate(), timeout=30)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise EncodingFailed("cjpeg timed out")
        if process.returncode != 0 or len(data) <= 3 or len(data) > MAX_IMAGE_BYTES or not data.startswith(JPEG_MAGIC):
            raise EncodingFailed("cjpeg failed")
        return data


class PillowEncoder(ImageEncoder):
    """Fallback where mozjpeg isn't packaged (e.g. Debian): Pillow's libjpeg at the
    quality that matched mozjpeg q30 in OCR word retention."""
    name = "pillow"
    quality = 20

    def __init__(self, module):
        self.image_module = module

    @classmethod
    def locate(cls) -> "PillowEncoder | None":
        try:
            from PIL import Image  # type: ignore
        except Exception:
            return None
        return cls(Image)

    def _encode_sync(self, path: Path) -> bytes:
        with self.image_module.open(path) as image:
            image.load()
            rgb = image.convert("RGB")
        out = io.BytesIO()
        rgb.save(out, "JPEG", quality=self.quality, optimize=True, progressive=True, subsampling=2)
        data = out.getvalue()
        if len(data) <= 3 or len(data) > MAX_IMAGE_BYTES or not data.startswith(JPEG_MAGIC):
            raise EncodingFailed("Pillow produced no JPEG")
        return data

    async def encode(self, path: Path) -> bytes:
        try:
            return await asyncio.to_thread(self._encode_sync, path)
        except EncodingFailed:
            raise
        except Exception as exc:
            raise EncodingFailed(str(exc)) from exc


class NetpbmCjpegEncoder(ImageEncoder):
    """Packaged on Debian/Ubuntu (``netpbm`` + ``libjpeg-turbo-progs``): ``pngtopnm`` decodes,
    libjpeg-turbo's ``cjpeg`` encodes at the quality that matched mozjpeg q30."""
    name = "libjpeg-turbo"
    quality = 20
    candidates = (("/usr/bin/pngtopnm", "/usr/bin/cjpeg"), ("/usr/local/bin/pngtopnm", "/usr/local/bin/cjpeg"))

    def __init__(self, decoder: str, encoder: str):
        self.decoder, self.encoder = decoder, encoder

    @classmethod
    def locate(cls, candidates=None) -> "NetpbmCjpegEncoder | None":
        for decoder, encoder in candidates or cls.candidates:
            if all(os.path.isfile(p) and os.access(p, os.X_OK) for p in (decoder, encoder)):
                return cls(decoder, encoder)
        return None

    async def encode(self, path: Path) -> bytes:
        read, write = os.pipe()
        try:
            decode = await asyncio.create_subprocess_exec(self.decoder, str(path), stdin=asyncio.subprocess.DEVNULL, stdout=write,
                                                          stderr=asyncio.subprocess.DEVNULL, env={})
            encode = await asyncio.create_subprocess_exec(self.encoder, "-quality", str(self.quality), "-optimize", stdin=read,
                                                          stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env={})
        finally:
            os.close(read)
            os.close(write)
        try:
            data, _ = await asyncio.wait_for(encode.communicate(), timeout=60)
            await asyncio.wait_for(decode.wait(), timeout=5)
        except asyncio.TimeoutError:
            for process in (decode, encode):
                if process.returncode is None:
                    process.kill()
                    await process.wait()
            raise EncodingFailed("pngtopnm | cjpeg timed out")
        if decode.returncode != 0 or encode.returncode != 0 or len(data) <= 3 or len(data) > MAX_IMAGE_BYTES or not data.startswith(JPEG_MAGIC):
            raise EncodingFailed("pngtopnm | cjpeg failed")
        return data


def default_encoder() -> ImageEncoder | None:
    """Best available, in order of measured size at equal OCR retention."""
    return MozJPEGEncoder.locate() or PillowEncoder.locate() or NetpbmCjpegEncoder.locate()


class ImageCompactor:
    """Replaces digested PNGs with JPEGs. Output that isn't smaller, or fails to encode,
    keeps the PNG and is not retried until restart."""

    def __init__(self, store: EvidenceStore, encoder: ImageEncoder | None):
        self.store = store
        self.encoder = encoder
        self.skipped: set[str] = set()

    @property
    def available(self) -> bool:
        return self.encoder is not None

    async def run(self, limit: int = 120) -> int:
        if self.encoder is None:
            return 0
        self.store.remove_superseded_originals()
        replaced = 0
        for image in self.store.compressible_images(limit + len(self.skipped)):
            if replaced >= limit:
                break
            if image.id in self.skipped:
                continue
            try:
                size = image.path.stat().st_size
                data = await self.encoder.encode(image.path)
            except (OSError, EncodingFailed) as exc:
                log.warning("compression failed for %s: %s", image.id, exc)
                self.skipped.add(image.id)
                continue
            if len(data) >= size or self.store.replace_image(image.id, image.path, data) is None:
                self.skipped.add(image.id)
                continue
            replaced += 1
        return replaced


def describe(encoder: ImageEncoder | None) -> str:
    if encoder is None:
        return "none (digested screenshots stay PNG; install mozjpeg, Pillow, or netpbm + libjpeg-turbo-progs)"
    if isinstance(encoder, MozJPEGEncoder):
        return f"mozjpeg ({encoder.executable}, quality {encoder.quality})"
    return f"{encoder.name} (quality {encoder.quality})"
