import json, sys
from aiobmsble.test_data import bms_advertisements, ignore_advertisements
from aiobmsble.utils import load_bms_plugins, bms_supported
plugins = sorted(load_bms_plugins(), key=lambda m: m.__name__)
out = []
def rec(adv, mac, typ, kind):
    matches = [m.__name__.rsplit('.',1)[-1] for m in plugins if bms_supported(m.BMS, adv, mac)]
    out.append({"kind": kind, "type": typ, "mac": mac, "name": adv.local_name,
        "service_uuids": list(adv.service_uuids),
        "service_data": {k: v.hex() for k, v in adv.service_data.items()},
        "manufacturer_data": {str(k): v.hex() for k, v in adv.manufacturer_data.items()},
        "matches": matches})
for adv, mac, typ, _ in bms_advertisements(): rec(adv, mac, typ, "bms")
for adv, mac, typ, _ in ignore_advertisements(): rec(adv, mac, typ, "ignore")
json.dump(out, open(sys.argv[1], "w"), indent=0)
import collections
print(len(out), collections.Counter(len(o["matches"]) for o in out))
print([ (o["type"], o["matches"]) for o in out if len(o["matches"])>1 or (o["kind"]=="bms" and o["type"] not in o["matches"])][:20])
