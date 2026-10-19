"""A stand-in for Hermes's stdio tui_gateway with the xCreen RPC methods.

Usage: fake_gateway.py MODE [LOG]. MODE controls automatic turns:
  ok      batch turns complete and their receipt is verified skipped
  saved   batch turns complete with one verified effect
  429     batch turns fail with a provider rate limit; receipt proves zero effects (retry_safe)
  hang    turns never finish until interrupted
LOG, if given, receives one JSON line per request (method + selected params).
"""
import json
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
LOG = open(sys.argv[2], "a") if len(sys.argv) > 2 else None
SESSION = {"runtime": "runtime-1", "stored": "stored-1"}
state = {"prepared": None, "manual": False, "hidden": True, "model": ("anthropic", "claude-haiku-5-5"), "attached": 0, "receipts": {}}


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def event(kind, payload=None):
    send({"jsonrpc": "2.0", "method": "event", "params": {"type": kind, "session_id": SESSION["runtime"], "payload": payload or {}}})


def reply(rid, result):
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def error(rid, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": 4000, "message": message}})


event("gateway.ready", {"change_events": True})
for line in sys.stdin:
    request = json.loads(line)
    method, rid, params = request.get("method"), request.get("id"), request.get("params", {})
    if LOG:
        LOG.write(json.dumps({"method": method, **{k: v for k, v in params.items() if k in ("batch_id", "filename", "hidden", "value", "focus_topic", "mode")}}) + "\n")
        LOG.flush()
    if method == "client.capabilities":
        reply(rid, {"server_requests": [], "declines_not_shown": True})
    elif method == "gateway.capabilities":
        reply(rid, {"per_session_exclusive_submit": True})
    elif method == "session.create":
        reply(rid, {"session_id": SESSION["runtime"], "stored_session_id": SESSION["stored"]})
    elif method == "session.resume":
        if params["session_id"] != SESSION["stored"]:
            SESSION["stored"] = params["session_id"]
        reply(rid, {"session_id": SESSION["runtime"], "resumed": SESSION["stored"]})
    elif method == "model.options":
        reply(rid, {"provider": state["model"][0], "model": state["model"][1], "providers": [
            {"slug": "anthropic", "models": ["claude-haiku-5-5", "claude-sonnet-5-5"]}, {"slug": "openrouter", "models": ["anthropic/claude-haiku-5.5"]}]})
    elif method == "session.set_hidden":
        state["hidden"] = params["hidden"]
        reply(rid, {"hidden": params["hidden"], "session_key": "key-1"})
    elif method == "config.set":
        model, _, rest = params["value"].partition(" --provider ")
        provider = rest.split(" ")[0]
        state["model"] = (provider, model)
        reply(rid, {"key": "model", "value": model, "scope": "session", "confirm_required": False})
    elif method == "xcreen.batch.prepare":
        state["prepared"] = (params["batch_id"], sorted(params["source_ids"]))
        reply(rid, {"batch_id": params["batch_id"], "source_ids": params["source_ids"], "session_id": params["session_id"], "prepared": True})
    elif method == "xcreen.batch.context":
        state["manual"] = True
        reply(rid, {"session_id": params["session_id"], "mode": "manual"})
    elif method == "image.attach_bytes":
        state["attached"] += 1
        reply(rid, {"attached": True})
    elif method == "prompt.submit":
        reply(rid, {"status": "streaming"})
        event("message.start")
        if MODE == "hang":
            continue
        if state["manual"] and state["prepared"] is None:
            event("message.delta", {"text": "Hello "})
            event("message.delta", {"text": "there"})
            event("session.info", {"provider": state["model"][0], "model": state["model"][1], "usage": {"context_used": 1000, "context_max": 200000}})
            event("message.complete", {"text": "Hello there", "status": "complete"})
            state["manual"] = False
            continue
        batch_id, sources = state["prepared"]
        if MODE == "429":
            state["receipts"][batch_id] = {"status": "uncertain", "verified": False, "effects": [], "retry_safe": True}
            event("message.complete", {"text": "", "status": "error", "error_surface": {"code": "rate_limit"}})
        elif MODE == "saved":
            state["receipts"][batch_id] = {"status": "saved", "verified": True, "effects": [{"entry_id": "fact-1", "state": "completed", "day": "2026-10-20"}]}
            event("message.complete", {"text": "Saved one fact.", "status": "complete"})
        else:
            state["receipts"][batch_id] = {"status": "skipped", "verified": True, "effects": []}
            event("message.complete", {"text": "Nothing worth noting.", "status": "complete"})
        state["prepared"] = None
    elif method in ("xcreen.batch.receipt", "xcreen.batch.reconcile"):
        found = state["receipts"].get(params["batch_id"], {"status": "missing", "verified": False, "effects": []})
        reply(rid, {"batch_id": params["batch_id"], "session_id": params["session_id"], "source_ids": params["source_ids"], **found})
    elif method == "session.interrupt":
        reply(rid, {})
        event("session.interrupted")
        state["prepared"] = None
        state["manual"] = False
    elif method == "session.compress":
        reply(rid, {"compressed": True})
    elif method == "xcreen.history.page":
        reply(rid, {"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}], "count": 2, "has_more": False, "next_cursor": None})
    else:
        reply(rid, {})
