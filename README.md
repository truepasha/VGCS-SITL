# VGCS-SITL

Tracks official [ArduPilot](https://github.com/ArduPilot/ardupilot) vehicle release tags and publishes **Windows (Cygwin) SITL** binaries for VectorGCS — same runtime model as Mission Planner, with **exact version** control per vehicle.

## Scope

| Vehicle tags | Versions |
| --- | --- |
| `Copter-*`, `Plane-*`, `Rover-*`, `Sub-*` | Stable `X.Y.Z` **≥ 4.5.0** |

Each GitHub Release is named like the upstream tag (`Plane-4.5.7`) and contains:

- `ArduPlane.elf` / `ArduCopter.elf` / `ArduRover.elf` / `ArduSub.elf` (vehicle for that tag)
- required `cyg*.dll` runtime files
- `git.txt`, `build.txt`, `vgcs-sitl.txt`

## Automation

Workflow: [`.github/workflows/sitl-cygwin.yml`](.github/workflows/sitl-cygwin.yml)

- **schedule** every 6 hours — builds up to **2** missing tags (oldest first)
- **workflow_dispatch** — optional `only_tag` (e.g. `Plane-4.5.7`) and `max_builds`

Discover logic: [`scripts/discover_missing_tags.py`](scripts/discover_missing_tags.py)  
Build script: [`scripts/build_sitl_vehicle.sh`](scripts/build_sitl_vehicle.sh) (based on ArduPilot `Tools/scripts/cygwin_build.sh`)

## License

- Repository automation: [GPL-3.0](LICENSE)
- Published SITL binaries: built from ArduPilot source (**GPLv3**); use/redistribute under ArduPilot terms
