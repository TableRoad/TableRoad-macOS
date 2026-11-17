# TableRoad

**A native, open-source macOS database client: a free alternative to TablePlus, Sequel Ace and Postico.**

Browse, filter, edit and query MySQL, MariaDB, PostgreSQL, CockroachDB, SQL Server, Oracle, Vertica, Cassandra,
SQLite, LibSQL/Turso, ClickHouse and Redis, with backups, database sync, and export/import. Part of the TermRoad
family.

**Free and open source under the [MIT licence](LICENSE).** Every feature is available to everyone.

## Why TableRoad?

- **Native Mac app.** SwiftUI and AppKit, not Electron or Java: fast to launch, real keyboard shortcuts, dark mode.
- **One app for many databases.** If you use Sequel Ace for MySQL and something else for PostgreSQL or SQL Server,
  TableRoad covers them in one place, with the same grid, filters and editor everywhere.
- **Pure-Swift drivers.** No client libraries to install: the SQL Server, Oracle, Vertica and Cassandra protocols
  are implemented in Swift.
- **Free, with no account.** No licence key, no sign-in, no tracking. Connections and passwords stay on your Mac
  (in the Keychain).
- **Familiar workflow.** If you're coming from TablePlus: connection groups and tags, staged edits with an SQL
  preview, foreign-key navigation, Quick Look for long values, running-query management, scheduled backups and
  database sync.

TableRoad is an independent project, not affiliated with TablePlus, Sequel Ace, Postico or their developers.

- Source: https://github.com/TableRoad/TableRoad-macOS
- Issues and ideas: https://github.com/TableRoad/TableRoad-macOS/issues
- Releases: https://github.com/TableRoad/TableRoad-macOS/releases
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)

## Layout

| Path | What |
|---|---|
| `Apps/macOS/TableRoad` | SwiftUI app target (folder-synced: new files are picked up automatically) |
| `Packages/TableRoadKit` | Shared Swift package: drivers, SQL, export/import, backups, storage — everything that isn't a view |
| `Config/` | xcconfig files. **Bundle ID is a placeholder** in `Identifiers.xcconfig` |
| `docker/` | Test databases for the integration tests (see below) |
| `.github/workflows` | CI: package tests, Debug and Release builds, lint |

## Develop

```sh
open TableRoad.xcodeproj                      # run the "TableRoad" scheme
cd Packages/TableRoadKit && swift test        # unit and integration tests
swift format --in-place --recursive Packages/TableRoadKit/Sources Packages/TableRoadKit/Tests Apps
```

Debug builds launched with `TABLEROAD_DEV_FIXTURES=1` use a throwaway connections file with a "Docker" group
pointing at the test databases (your real connections are untouched).

## Test databases

```sh
docker compose -f docker/compose.yml up -d --build
```

| Service | Direct | Via SSH bastion (`127.0.0.1:12222`) | Login |
|---|---|---|---|
| Postgres 17 | `127.0.0.1:15432` | `postgres:5432` | `tableroad` / `tableroad` |
| MySQL 8.4 | `127.0.0.1:13306` | `mysql:3306` | `tableroad` / `tableroad` |
| MariaDB 11 | `127.0.0.1:13307` | `mariadb:3306` | `tableroad` / `tableroad` |
| Redis 7 | `127.0.0.1:16379` | `redis:6379` | password `tableroad` |
| SQL Server 2022 | `127.0.0.1:11433` | | `sa` / `TableRoad!2026` |
| Vertica 25.4 | `127.0.0.1:15433` | | `dbadmin`, no password |
| Cassandra 5 | `127.0.0.1:19042` | | `cassandra` / `cassandra` |
| CockroachDB | `127.0.0.1:26257` | | `root`, insecure |
| ClickHouse | `127.0.0.1:18123` | | `tableroad` / `tableroad` |
| libSQL | `127.0.0.1:18080` | | none |

SQL Server and Vertica are x86 images (they run under Rosetta on Apple Silicon); all of them together need
about 8 GB of Docker memory, so start just the ones you need, e.g. `docker compose -f docker/compose.yml up -d mysql postgres`.
Integration tests skip engines whose server isn't running.

To run the VERIFY_CA test, copy MySQL's generated CA out of the container (it's per-container, so not committed):
`docker cp tableroad-test-mysql-1:/var/lib/mysql/ca.pem docker/certs/mysql-ca.pem`

To try the row-count estimate on a large table, load `docker/large-table.sql` into the MySQL container (instructions
inside; drop the table again before running the tests).

The SSH user `tableroad` accepts the password `tableroad`, or any key in `docker/keys` (test-only keys; the
encrypted ones use the passphrase `tableroad`).

## Licence

MIT — see [LICENSE](LICENSE).
