import Foundation
import TableRoadCore
import Testing

@testable import TableRoadStorage

@MainActor @Suite struct ConnectionStoreTests {
    let fileURL = FileManager.default.temporaryDirectory.appending(path: "tableroad-test-\(UUID()).json")

    @Test func savesReloadsAndKeepsPasswordsOutOfTheFile() throws {
        let secrets = InMemorySecretStore()
        let store = ConnectionStore(fileURL: fileURL, secrets: secrets)
        let profile = ConnectionProfile(name: "Local MySQL", kind: .mysql, username: "root")
        try store.save(profile, password: "hunter2")

        let reloaded = ConnectionStore(fileURL: fileURL, secrets: secrets)
        #expect(reloaded.profiles.map(\.name) == ["Local MySQL"])
        #expect(reloaded.password(for: profile.id) == "hunter2")
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!json.contains("hunter2"))
    }

    @Test func duplicateAndDelete() throws {
        let store = ConnectionStore(fileURL: fileURL, secrets: InMemorySecretStore())
        let original = ConnectionProfile(name: "Prod", kind: .mariadb)
        try store.save(original, password: "pw")
        let copy = try store.duplicate(original)
        #expect(store.profiles.count == 2)
        #expect(store.password(for: copy.id) == "pw")
        try store.delete(original.id)
        #expect(store.profiles.map(\.id) == [copy.id])
        #expect(store.password(for: original.id) == nil)
    }

    @Test func corruptFileIsNeverOverwritten() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = ConnectionStore(fileURL: fileURL, secrets: InMemorySecretStore())
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) {
            try store.save(ConnectionProfile(name: "x", kind: .mysql), password: nil)
        }
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "not json")
    }
}
