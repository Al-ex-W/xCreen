"""Host-issued batch processing receipts (port of the 1.x Swift BatchReceipt).

A receipt comes from the scoped runtime's ``xcreen.batch.receipt`` RPC, never from
assistant prose or history. Only a verified saved/skipped receipt completes a batch.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field


class ProtocolFailure(Exception):
    """The host returned something that does not satisfy the receipt contract."""


@dataclass(frozen=True)
class EffectReceipt:
    entry_id: str
    state: str
    day: str | None = None
    digest: str | None = None

    def encode(self) -> dict:
        out = {"entry_id": self.entry_id, "state": self.state}
        if self.day is not None:
            out["day"] = self.day
        if self.digest is not None:
            out["digest"] = self.digest
        return out


@dataclass(frozen=True)
class BatchReceipt:
    batch_id: str
    source_ids: tuple[str, ...]
    session_id: str
    status: str
    verified: bool
    effects: tuple[EffectReceipt, ...] = field(default_factory=tuple)
    retry_safe: bool | None = None

    @property
    def effect_count(self) -> int:
        return len(self.effects)

    @property
    def completes_processing(self) -> bool:
        return self.verified and self.status in ("saved", "skipped")

    @classmethod
    def parse(cls, data: bytes | str | dict, *, batch_id: str, source_ids, session_id: str) -> "BatchReceipt":
        if isinstance(data, (bytes, str)):
            if len(data) > 48_000:
                raise ProtocolFailure("receipt too large")
            try:
                obj = json.loads(data)
            except ValueError as exc:
                raise ProtocolFailure("receipt is not JSON") from exc
        else:
            obj = data
            if len(json.dumps(obj)) > 48_000:
                raise ProtocolFailure("receipt too large")
        if not isinstance(obj, dict):
            raise ProtocolFailure("receipt is not an object")
        sources = obj.get("source_ids")
        status = obj.get("status")
        verified = obj.get("verified")
        effects = obj.get("effects")
        if (obj.get("batch_id") != batch_id or not isinstance(sources, list) or not all(isinstance(s, str) for s in sources)
                or sorted(sources) != sorted(source_ids) or len(set(sources)) != len(sources)
                or obj.get("session_id") != session_id or status not in ("saved", "skipped", "missing", "uncertain")
                or type(verified) is not bool or not isinstance(effects, list) or not all(isinstance(e, dict) for e in effects)):
            raise ProtocolFailure("receipt does not match the batch binding")
        if verified:
            if not ((status == "saved" and effects) or (status == "skipped" and not effects)):
                raise ProtocolFailure("verified receipt status contradicts its effects")
            ids = [e.get("entry_id") for e in effects]
            # A completed effect that a later bullet revised is reported as "superseded"; it still
            # counts as done (runtime/xcreen_receipts.py treats both as terminal).
            if not all(isinstance(i, str) for i in ids) or len(set(ids)) != len(ids) or any(e.get("state") not in ("completed", "superseded") for e in effects):
                raise ProtocolFailure("verified receipt effects are incomplete")
        parsed = []
        for item in effects:
            entry, state = item.get("entry_id"), item.get("state")
            day, digest = item.get("day"), item.get("digest")
            if (not isinstance(entry, str) or not entry or len(entry.encode()) > 128 or state not in ("completed", "superseded", "pending", "uncertain")
                    or (day is not None and (not isinstance(day, str) or len(day.encode()) > 32))
                    or (digest is not None and (not isinstance(digest, str) or len(digest.encode()) > 128))):
                raise ProtocolFailure("invalid effect receipt")
            parsed.append(EffectReceipt(entry, state, day, digest))
        retry = None
        if "retry_safe" in obj:
            retry = obj["retry_safe"]
            if type(retry) is not bool or (retry and (verified or status != "uncertain" or effects)):
                raise ProtocolFailure("retry_safe contradicts the receipt")
        return cls(batch_id, tuple(sorted(sources)), session_id, status, verified, tuple(parsed), retry)

    # Stored with the batch record using the 1.x Swift field names, so stores stay
    # readable across versions.
    def encode(self) -> dict:
        out = {"batchID": self.batch_id, "sourceIDs": list(self.source_ids), "sessionID": self.session_id,
               "status": self.status, "verified": self.verified, "effectCount": self.effect_count,
               "effects": [e.encode() for e in self.effects]}
        if self.retry_safe is not None:
            out["retrySafe"] = self.retry_safe
        return out

    @classmethod
    def decode(cls, obj: dict) -> "BatchReceipt":
        effects = tuple(EffectReceipt(e["entry_id"], e["state"], e.get("day"), e.get("digest")) for e in obj.get("effects", []))
        return cls(obj["batchID"], tuple(obj.get("sourceIDs", [])), obj["sessionID"], obj["status"], bool(obj["verified"]),
                   effects, obj.get("retrySafe"))

    def summary(self) -> dict:
        return {"status": self.status, "verified": self.verified, "effects": self.effect_count}
