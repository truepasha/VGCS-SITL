# VGCS-SITL

Tracks official [ArduPilot](https://github.com/ArduPilot/ardupilot) vehicle release tags and publishes **Windows (Cygwin) SITL** binaries for VectorGCS — same runtime model as Mission Planner, with **exact version** control per vehicle.

## Scope

| Vehicle tags | Versions |
| --- | --- |
| `Copter-*`, `Plane-*`, `Rover-*`, `Sub-*` | Stable `X.Y.Z` **≥ 4.5.0** |

Each GitHub Release is named like the upstream tag (`Plane-4.5.7`) and contains:

- `ArduPlane.elf` / `ArduCopter.elf` / `ArduRover.elf` / `ArduSub.elf` (vehicle for that tag)
- matching `.exe` copy of the primary binary
- required `cyg*.dll` runtime files
- `git.txt`, `build.txt`, `vgcs-sitl.txt`

**Official ArduPilot release day** (UTC, no time) is written in the release notes as a machine-readable line:

```text
ArduPilot-Release-Date: 2024-05-28
```

Prefer `published_at` from the matching [ArduPilot/ardupilot](https://github.com/ArduPilot/ardupilot) GitHub Release; otherwise the git commit day of that tag. VectorGCS parses this line from the releases API `body` and caches it in `sitl-firmware-catalog.json`. Do **not** attach `ardupilot-release.json`.

Backfill older releases (missing the date line):

```powershell
pwsh -File scripts/backfill_ardupilot_release_date.ps1
# optional: -OnlyTag Plane-4.5.7 -WhatIf
```

## Automation

Workflow: [`.github/workflows/sitl-cygwin.yml`](.github/workflows/sitl-cygwin.yml)

- **schedule** every 6 hours — builds up to **2** missing tags (oldest first)
- **workflow_dispatch** — optional `only_tag` (e.g. `Plane-4.5.7`) and `max_builds`
- **one Windows job per run** installs Cygwin once, then builds the whole batch
- **Cygwin + ccache** restored via `actions/cache` when possible
- **Python 3.9** on Cygwin (waf for 4.5.x needs stdlib `imp`; not available on 3.12)

Discover logic: [`scripts/discover_missing_tags.py`](scripts/discover_missing_tags.py)  
Build script: [`scripts/build_sitl_vehicle.sh`](scripts/build_sitl_vehicle.sh) (based on ArduPilot `Tools/scripts/cygwin_build.sh`)

## License

- Repository automation: [GPL-3.0](LICENSE)
- Published SITL binaries: built from ArduPilot source (**GPLv3**); use/redistribute under ArduPilot terms
