#!/usr/bin/env python3
from __future__ import annotations

import re
import sys

SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")


def parse(value: str) -> tuple[tuple[int, int, int], tuple[tuple[int, object], ...] | None]:
    match = SEMVER.fullmatch(value)
    if not match:
        raise SystemExit(f"error: invalid semantic version: {value}")
    core = tuple(int(part) for part in match.group(1, 2, 3))
    prerelease = match.group(4)
    if prerelease is None:
        return core, None
    identifiers = tuple((0, int(item)) if item.isdigit() else (1, item) for item in prerelease.split("."))
    return core, identifiers


def is_newer(candidate: str, published: str) -> bool:
    candidate_core, candidate_pre = parse(candidate)
    published_core, published_pre = parse(published)
    if candidate_core != published_core:
        return candidate_core > published_core
    if candidate_pre is None:
        return published_pre is not None
    if published_pre is None:
        return False
    return candidate_pre > published_pre


if len(sys.argv) != 3:
    raise SystemExit("usage: check-newer-version.py CANDIDATE PUBLISHED")
if not is_newer(sys.argv[1], sys.argv[2]):
    raise SystemExit(f"error: local version {sys.argv[1]} must be newer than published latest {sys.argv[2]}")
