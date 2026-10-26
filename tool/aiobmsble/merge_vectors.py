"""Merge per-test traces recorded by bmsrec.py into one JSON file per BMS module.

Usage: python merge_vectors.py <recorded dir> <out dir>
Identical traces (same events, config) are kept once.
"""
import glob, json, os, sys
src, out = sys.argv[1], sys.argv[2]
by_mod = {}
for f in sorted(glob.glob(os.path.join(src, "*.json"))):
    d = json.load(open(f))
    mods = {b["module"] for b in d["bms"]}
    if len(mods) != 1:
        continue
    mod = mods.pop()
    if mod == "dummy_bms":
        continue
    key = json.dumps([d["bms"], d["events"]], sort_keys=True)
    lst = by_mod.setdefault(mod, {})
    lst.setdefault(key, {"tests": [], "bms": d["bms"], "events": d["events"]})["tests"].append(d["test"].split("::", 1)[-1])
os.makedirs(out, exist_ok=True)
n = 0
for mod, traces in sorted(by_mod.items()):
    with open(os.path.join(out, mod + ".json"), "w") as fh:
        json.dump(list(traces.values()), fh, separators=(",", ":"))
    n += len(traces)
print(f"{len(by_mod)} modules, {n} traces")
