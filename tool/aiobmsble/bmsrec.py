"""pytest plugin: record GATT traces + results of aiobmsble tests as JSON vectors."""
import inspect, json, os, enum
import pytest
from bleak.uuids import normalize_uuid_str
import aiobmsble.basebms as bb
from aiobmsble import TempSensor

OUT = os.environ.get("BMSREC_OUT", "/tmp/bmsrec")
_cur = None


def _c(spec):
    if isinstance(spec, str):
        return normalize_uuid_str(spec)
    if isinstance(spec, int):
        return f"handle:{spec}"
    if hasattr(spec, "handle") and hasattr(spec, "uuid"):
        return f"{normalize_uuid_str(spec.uuid)}#{spec.handle}"
    u = getattr(spec, "uuid", None)
    return normalize_uuid_str(u) if u else repr(spec)


def _norm(v):
    if isinstance(v, TempSensor):
        return {"t": float(v.value), "k": int(v.type)}
    if isinstance(v, bool):
        return v
    if isinstance(v, enum.IntEnum):
        return int(v)
    if isinstance(v, int) and abs(v) >= 2**53:
        return {"big": str(v)}
    if isinstance(v, (int, float, str)) or v is None:
        return v
    if isinstance(v, (list, tuple)):
        return [_norm(x) for x in v]
    if isinstance(v, dict):
        return {k: _norm(x) for k, x in v.items()}
    if isinstance(v, (bytes, bytearray)):
        return v.hex()
    return repr(v)


def _task_no():
    """Small number for the asyncio task an event happens in: 0 is the test
    (and so the BMS) task; notifications pushed from a mock's own task get
    another number, which tells the replay to deliver them later."""
    import asyncio
    try:
        t = asyncio.current_task()
    except RuntimeError:
        t = None
    tasks = _cur.setdefault("_tasks", {})
    return tasks.setdefault(id(t), len(tasks))


def ev(**kw):
    if _cur is not None:
        kw["k"] = _task_no()
        _cur["events"].append(kw)


def _instrument(client):
    if getattr(client, "_rec", False):
        return client
    client._rec = True
    ow, orr, osn, ostop = (client.write_gatt_char, client.read_gatt_char,
                           client.start_notify, client.stop_notify)

    async def write(spec, data, response=None, **kw):
        rec = dict(e="write", c=_c(spec), d=bytes(data).hex(), r=response)
        ev(**rec)
        try:
            return await ow(spec, data, response=response, **kw)
        except BaseException as x:
            if _cur is not None and _cur["events"]:
                _cur["events"][-1]["raise"] = type(x).__name__
            raise

    async def read(spec, **kw):
        try:
            v = await orr(spec, **kw)
        except BaseException as x:
            ev(e="read", c=_c(spec), d="", **{"raise": type(x).__name__})
            raise
        ev(e="read", c=_c(spec), d=bytes(v).hex())
        return v

    async def start(spec, cb, **kw):
        cu = _c(spec)
        ev(e="notify_on", c=cu)
        if inspect.iscoroutinefunction(cb):
            async def w(s, d):
                ev(e="rx", c=cu, d=bytes(d).hex())
                return await cb(s, d)
        else:
            def w(s, d):
                ev(e="rx", c=cu, d=bytes(d).hex())
                return cb(s, d)
        return await osn(spec, w, **kw)

    async def stop(spec, **kw):
        ev(e="notify_off", c=_c(spec))
        return await ostop(spec, **kw)

    client.write_gatt_char, client.read_gatt_char = write, read
    client.start_notify, client.stop_notify = start, stop
    return client


@pytest.fixture(autouse=True)
def _bmsrec(request, monkeypatch):
    global _cur
    _cur = {"test": request.node.nodeid, "events": []}
    orig_est = bb.establish_connection

    async def est(*a, **kw):
        cl = await orig_est(*a, **kw)
        svcs = []
        try:
            for sv in cl.services:
                for ch in sv.characteristics:
                    svcs.append({"s": normalize_uuid_str(sv.uuid), "c": normalize_uuid_str(ch.uuid),
                                 "h": ch.handle, "p": list(ch.properties)})
        except Exception as x:
            svcs = [{"err": repr(x)}]
        ev(e="connect", services=svcs)
        return _instrument(cl)

    monkeypatch.setattr(bb, "establish_connection", est)
    o_upd, o_info, o_init = bb.BaseBMS.async_update, bb.BaseBMS.device_info, bb.BaseBMS.__init__

    def init(self, dev, config=None, logger_name=""):
        o_init(self, dev, config, logger_name)
        _cur.setdefault("bms", []).append({
            "module": type(self).__module__.rsplit(".", 1)[-1],
            "name": dev.name, "address": dev.address,
            "secret": (config.secret if config else ""),
            "keep_alive": (config.keep_alive if config else True)})

    async def upd(self, raw=False):
        ev(e="update", raw=raw)
        try:
            r = await o_upd(self, raw)
        except BaseException as x:
            ev(e="error", t=type(x).__name__)
            raise
        ev(e="result", v=_norm(r))
        return r

    async def info(self):
        ev(e="info_req")
        try:
            r = await o_info(self)
        except BaseException as x:
            ev(e="error", t=type(x).__name__)
            raise
        ev(e="info", v=_norm(r))
        return r

    async def disc(self, reset=False):
        ev(e="disconnect")
        return await o_disc(self, reset)
    o_disc = bb.BaseBMS.disconnect
    monkeypatch.setattr(bb.BaseBMS, "__init__", init)
    monkeypatch.setattr(bb.BaseBMS, "async_update", upd)
    monkeypatch.setattr(bb.BaseBMS, "device_info", info)
    monkeypatch.setattr(bb.BaseBMS, "disconnect", disc)
    yield
    rec, _cur = _cur, None
    rec.pop("_tasks", None)
    rep = getattr(request.node, "rep_call", None)
    rec["passed"] = bool(rep and rep.passed)
    if rec.get("bms") and any(e["e"] in ("result", "info") for e in rec["events"]):
        os.makedirs(OUT, exist_ok=True)
        fn = rec["test"].replace("/", "_").replace("::", "__")
        fn = "".join(ch if ch.isalnum() or ch in "._-[]" else "_" for ch in fn)[:180]
        with open(os.path.join(OUT, fn + ".json"), "w") as f:
            json.dump(rec, f)


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    r = outcome.get_result()
    if r.when == "call":
        item.rep_call = r
