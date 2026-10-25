#!/usr/bin/env python3
"""Regenerates the import and spec lists in lib/bms/registry.dart from the
driver files in lib/bms/drivers/. Run from the repository root."""

import pathlib
import re

root = pathlib.Path("lib/bms")
reg = root / "registry.dart"
drivers = sorted((root / "drivers").glob("*.dart"))
classes = []
for f in drivers:
    m = re.search(r"^class (\w+) extends", f.read_text(), re.M)
    if m and "static" in f.read_text() and "spec = BmsSpec" in f.read_text():
        classes.append((f.name, m.group(1)))

src = reg.read_text()
imports = "".join(f"import 'drivers/{n}';\n" for n, _ in classes)
src = re.sub(r"(import '../decoders/raw_advertisement.dart';\n)(?:import 'drivers/[^\n]+\n)*",
             lambda m: m.group(1) + imports, src)
specs = "".join(f"  {c}.spec,\n" for _, c in classes)
src = re.sub(r"(final List<BmsSpec> bmsSpecs = \[\n)(?:  \w+\.spec,\n)*", lambda m: m.group(1) + specs, src)
reg.write_text(src)
print(f"{len(classes)} drivers")
