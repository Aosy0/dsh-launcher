#!/usr/bin/env python3
"""Generate mac/Support/AppIcon-1024.png for the macOS app bundle.

The drawing lives in tools/make-icon.py (the Windows .ico generator), so both
platforms share one visual language. The PNG is committed because build.sh only
needs sips/iconutil on the Mac (no Python/Pillow at build time).

usage: python tools/make-mac-icon.py
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_FILE = ROOT / "mac" / "Support" / "AppIcon-1024.png"
ICON_SCRIPT = ROOT / "tools" / "make-icon.py"


def load_icon_module():
    spec = importlib.util.spec_from_file_location("dsh_icon", ICON_SCRIPT)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {ICON_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    module = load_icon_module()
    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    image = module.render(1024)
    image.save(OUT_FILE, format="PNG")
    print(f"wrote {OUT_FILE} ({OUT_FILE.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
