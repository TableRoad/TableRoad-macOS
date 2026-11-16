# TableRoad

A native macOS database client for PostgreSQL, MySQL, MariaDB and Redis, with SSH tunnelling, in the TermRoad family.
The full plan is in [docs/PLAN.md](docs/PLAN.md).

## Layout

| Path | What |
|---|---|
| `Apps/macOS/TableRoad` | SwiftUI app target (folder-synced: new files are picked up automatically) |
| `Packages/TableRoadKit` | Shared Swift package: everything that isn't a view or a platform API |
| `Config/` | xcconfig files. **Bundle ID is a placeholder** in `Identifiers.xcconfig` |
| `Brand/` | Icon sources (`tableroad-icon.svg`) and rendered PNGs |
| `docker/` | Integration test environment: Postgres 17, MySQL 8.4, MariaDB 11, Redis 7, SSH bastion |
| `Spikes/` | Phase 0 library spikes and their results ([Spikes/README.md](Spikes/README.md)) |

## Develop

```sh
open TableRoad.xcodeproj                      # run the "TableRoad" scheme
cd Packages/TableRoadKit && swift test        # unit tests
swift format --in-place --recursive Packages/TableRoadKit/Sources Packages/TableRoadKit/Tests Apps
```

## Test databases

```sh
docker compose -f docker/compose.yml up -d --build --wait
```

| Service | Direct | Via SSH bastion (`127.0.0.1:12222`) |
|---|---|---|
| Postgres | `127.0.0.1:15432` | `postgres:5432` |
| MySQL 8.4 | `127.0.0.1:13306` | `mysql:3306` |
| MariaDB 11 | `127.0.0.1:13307` | `mariadb:3306` |
| Redis 7 | `127.0.0.1:16379` | `redis:6379` |

All credentials are `tableroad` / `tableroad`. The SSH user `tableroad` accepts that password, or any key in `docker/keys`
(test-only keys; the encrypted ones use the passphrase `tableroad`).
