# Contributing to TableRoad

Thanks for helping. TableRoad is a native macOS database client, free and open source under the
[MIT licence](LICENSE). Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue at https://github.com/TableRoad/TableRoad-macOS/issues with:

- your macOS version and the TableRoad version (Settings ▸ About),
- the database engine and server version,
- what you did, what you expected, and what happened (screenshots help).

Never paste passwords, connection strings with credentials, or private data.

## Building

You need Xcode 26 or later on macOS 15 or later.

```sh
git clone https://github.com/TableRoad/TableRoad-macOS.git
cd TableRoad-macOS
open TableRoad.xcodeproj        # run the "TableRoad" scheme
```

## Project layout

- `Apps/macOS/TableRoad`: the SwiftUI/AppKit app. Every view has a `#Preview` (inside `#if DEBUG`) with sample
  data that never touches a real database.
- `Packages/TableRoadKit`: everything that isn't a view: the database drivers (one module per engine, all
  pure Swift), SQL generation, export/import, backups and storage. No AppKit or UIKit here.
- `docker/`: the test databases used by the integration tests.

## Tests

```sh
docker compose -f docker/compose.yml up -d --wait   # test databases (see README for ports)
cd Packages/TableRoadKit && swift test
```

Integration tests skip themselves when their database isn't running, so `swift test` always works; run the
containers for the engines you change.

## Pull requests

- Keep changes focused, with tests for new behaviour (driver changes need integration tests against Docker).
- Swift 6 language mode with strict concurrency; sessions are actors.
- Format and lint before pushing (CI runs the same check):

  ```sh
  swift format --in-place --recursive Packages/TableRoadKit/Sources Packages/TableRoadKit/Tests Apps
  swift format lint --strict --recursive Packages/TableRoadKit/Sources Packages/TableRoadKit/Tests Apps
  ```

- Adding an engine? Implement `SQLClient` in a new `TableRoadKit` module, register it in
  `TableRoadDrivers/Drivers.swift`, and add a Docker service and a debug fixture (`DevFixtures.swift`). The SQL
  Server, Vertica and Cassandra drivers are good examples.

By contributing you agree that your contributions are licensed under the MIT licence.
