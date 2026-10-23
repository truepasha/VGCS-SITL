#!/usr/bin/env python3
"""Discover ArduPilot vehicle release tags that need a VGCS-SITL Cygwin build."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass

UPSTREAM = "https://github.com/ArduPilot/ardupilot.git"
VEHICLES = ("Copter", "Plane", "Rover", "Sub")
TAG_RE = re.compile(
    r"^(?P<vehicle>Copter|Plane|Rover|Sub)-"
    r"(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$"
)
MIN_VERSION = (4, 5, 0)

WAF_TARGET = {
    "Copter": "copter",
    "Plane": "plane",
    "Rover": "rover",
    "Sub": "sub",
}
ARTIFACT_NAME = {
    "Copter": "ArduCopter.elf",
    "Plane": "ArduPlane.elf",
    "Rover": "ArduRover.elf",
    "Sub": "ArduSub.elf",
}
BINARY_NAME = {
    "Copter": "arducopter",
    "Plane": "arduplane",
    "Rover": "ardurover",
    "Sub": "ardusub",
}


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, text: str) -> Version:
        major, minor, patch = (int(p) for p in text.split("."))
        return cls(major, minor, patch)

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


def list_upstream_tags() -> list[str]:
    result = subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", UPSTREAM],
        check=True,
        capture_output=True,
        text=True,
    )
    tags: list[str] = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        ref = parts[1]
        if ref.startswith("refs/tags/"):
            tags.append(ref.removeprefix("refs/tags/"))
    return tags


def list_existing_releases(repo: str, token: str | None) -> set[str]:
    names: set[str] = set()
    page = 1
    while True:
        url = (
            f"https://api.github.com/repos/{repo}/releases"
            f"?per_page=100&page={page}"
        )
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": "VGCS-SITL-discover",
                **({"Authorization": f"Bearer {token}"} if token else {}),
            },
        )
        try:
            with urllib.request.urlopen(request) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                break
            raise
        if not payload:
            break
        for item in payload:
            tag = item.get("tag_name")
            if isinstance(tag, str) and tag:
                names.add(tag)
        if len(payload) < 100:
            break
        page += 1
    return names


def candidate_tags(all_tags: list[str]) -> list[dict[str, str]]:
    selected: list[tuple[Version, str, dict[str, str]]] = []
    for tag in all_tags:
        match = TAG_RE.fullmatch(tag)
        if match is None:
            continue
        version = Version(
            int(match.group("major")),
            int(match.group("minor")),
            int(match.group("patch")),
        )
        if version < Version(*MIN_VERSION):
            continue
        vehicle = match.group("vehicle")
        selected.append(
            (
                version,
                tag,
                {
                    "tag": tag,
                    "vehicle": vehicle,
                    "version": str(version),
                    "waf_target": WAF_TARGET[vehicle],
                    "artifact_name": ARTIFACT_NAME[vehicle],
                    "binary_name": BINARY_NAME[vehicle],
                },
            )
        )
    selected.sort(key=lambda item: (item[0], item[1]))
    return [item[2] for item in selected]


def write_github_output(path: str, name: str, value: str) -> None:
    with open(path, "a", encoding="utf-8") as handle:
        if "\n" in value:
            handle.write(f"{name}<<EOF\n{value}\nEOF\n")
        else:
            handle.write(f"{name}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="owner/name of VGCS-SITL")
    parser.add_argument("--max-builds", type=int, default=2)
    parser.add_argument("--only-tag", default="")
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT", ""),
    )
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    existing = list_existing_releases(args.repo, token)
    upstream = list_upstream_tags()

    if args.only_tag.strip():
        tag = args.only_tag.strip()
        match = TAG_RE.fullmatch(tag)
        if match is None:
            print(f"Unsupported tag format: {tag}", file=sys.stderr)
            return 2
        version = Version(
            int(match.group("major")),
            int(match.group("minor")),
            int(match.group("patch")),
        )
        if version < Version(*MIN_VERSION):
            print(f"Tag below minimum {MIN_VERSION}: {tag}", file=sys.stderr)
            return 2
        vehicle = match.group("vehicle")
        missing = [
            {
                "tag": tag,
                "vehicle": vehicle,
                "version": str(version),
                "waf_target": WAF_TARGET[vehicle],
                "artifact_name": ARTIFACT_NAME[vehicle],
                "binary_name": BINARY_NAME[vehicle],
            }
        ]
    else:
        missing = [
            item
            for item in candidate_tags(upstream)
            if item["tag"] not in existing
        ]

    batch = missing[: max(0, args.max_builds)]
    matrix = {"include": batch}
    should_build = "true" if batch else "false"

    print(f"Upstream matching tags: {len(candidate_tags(upstream))}")
    print(f"Already released here: {len(existing)}")
    print(f"Missing: {len(missing)}")
    print(f"Batch this run: {len(batch)}")
    for item in batch:
        print(f"  - {item['tag']}")

    if args.github_output:
        write_github_output(args.github_output, "should_build", should_build)
        write_github_output(
            args.github_output,
            "matrix",
            json.dumps(matrix, separators=(",", ":")),
        )
        write_github_output(args.github_output, "missing_count", str(len(missing)))

    print(json.dumps(matrix, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
