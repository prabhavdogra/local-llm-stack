#!/usr/bin/env python3
"""Generate LITELLM_MASTER_KEY and GRAFANA_ADMIN_PASSWORD in .env."""

import os
import secrets
import sys
from pathlib import Path


def litellm_placeholder(value: str) -> bool:
    return value in ("", "sk-replace-me-with-a-strong-random-value", "sk-llmstack-local") or value.startswith(
        "sk-replace-me"
    )


def grafana_placeholder(value: str) -> bool:
    return value in ("", "replace-me-with-a-strong-password", "admin") or value.startswith("replace-me")


def webui_password_placeholder(value: str) -> bool:
    return value in ("", "admin", "replace-me-with-a-strong-password") or value.startswith("replace-me")


def main() -> int:
    only_placeholders = os.environ.get("ONLY_PLACEHOLDERS") == "1"
    path = Path(".env")
    if not path.exists():
        print("ERROR: .env not found — run make config first", file=sys.stderr)
        return 1

    lines: list[str] = []
    changed: list[str] = []
    for raw in path.read_text().splitlines(keepends=True):
        stripped = raw.strip()
        if stripped.startswith("LITELLM_MASTER_KEY="):
            value = stripped.split("=", 1)[1]
            if not only_placeholders or litellm_placeholder(value):
                raw = f"LITELLM_MASTER_KEY=sk-{secrets.token_hex(24)}\n"
                changed.append("LITELLM_MASTER_KEY")
        elif stripped.startswith("GRAFANA_ADMIN_PASSWORD="):
            value = stripped.split("=", 1)[1]
            if not only_placeholders or grafana_placeholder(value):
                raw = f"GRAFANA_ADMIN_PASSWORD={secrets.token_urlsafe(24)}\n"
                changed.append("GRAFANA_ADMIN_PASSWORD")
        elif stripped.startswith("WEBUI_ADMIN_PASSWORD="):
            value = stripped.split("=", 1)[1]
            if not only_placeholders or webui_password_placeholder(value):
                raw = f"WEBUI_ADMIN_PASSWORD={secrets.token_urlsafe(16)}\n"
                changed.append("WEBUI_ADMIN_PASSWORD")
        lines.append(raw)

    path.write_text("".join(lines))

    quiet = os.environ.get("QUIET") == "1"
    if changed:
        print("Generated:", ", ".join(changed))
        if not quiet:
            print("Edit .env for BACKEND, VLLM_MODEL, HF_TOKEN, etc. before running make up.")
    elif only_placeholders and not quiet:
        print("Secrets already set — nothing to regenerate.")
    elif not quiet:
        print("Wrote secrets to .env")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
