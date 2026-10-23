#!/usr/bin/env python3
"""Offline checks for discover_missing_tags helpers."""

from __future__ import annotations

import discover_missing_tags as d


def test_filters_and_orders() -> None:
    tags = [
        "Copter-4.4.4",
        "Copter-4.5.0",
        "Plane-4.5.7",
        "Copter-4.5.0-beta1",
        "Sub-4.7.0",
        "ignore-me",
        "Rover-4.6.1",
    ]
    got = [item["tag"] for item in d.candidate_tags(tags)]
    assert got == [
        "Copter-4.5.0",
        "Plane-4.5.7",
        "Rover-4.6.1",
        "Sub-4.7.0",
    ], got


def test_version_compare() -> None:
    assert d.Version(4, 5, 0) == d.Version.parse("4.5.0")
    assert d.Version(4, 4, 9) < d.Version(4, 5, 0)
    assert d.Version(4, 5, 1) > d.Version(4, 5, 0)


if __name__ == "__main__":
    test_filters_and_orders()
    test_version_compare()
    print("ok")
