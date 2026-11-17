import Foundation
import TableRoadCore
import Testing

@testable import TableRoadStorage

@MainActor
struct ConnectionGroupTests {
    func makeStore() -> (ConnectionStore, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "tr-groups-\(UUID()).json")
        return (ConnectionStore(fileURL: url, secrets: InMemorySecretStore()), url)
    }

    @Test func groupsPersistAndDeletingKeepsConnections() throws {
        let (store, url) = makeStore()
        let group = ConnectionGroup(name: "Clients", icon: .symbol("briefcase.fill"))
        try store.save(group)
        let profile = ConnectionProfile(name: "A", kind: .mysql, groupID: group.id)
        try store.save(profile, password: "pw")
        let reloaded = ConnectionStore(fileURL: url, secrets: InMemorySecretStore())
        #expect(reloaded.groups == [group])
        #expect(reloaded.profiles.first?.groupID == group.id)

        try store.deleteGroup(group.id)
        #expect(store.groups.isEmpty)
        #expect(store.profiles.first?.groupID == nil)
    }

    @Test func version1FileStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tr-v1-\(UUID()).json")
        try Data(#"{"version":1,"connections":[]}"#.utf8).write(to: url)
        let store = ConnectionStore(fileURL: url, secrets: InMemorySecretStore())
        #expect(store.loadError == nil)
        #expect(store.groups.isEmpty)
    }

    @Test func encryptedRoundTripWithNewIDs() throws {
        let (store, _) = makeStore()
        let group = ConnectionGroup(name: "Prod", icon: .image(Data([1, 2, 3])))
        try store.save(group)
        try store.save(ConnectionProfile(name: "DB", kind: .mariadb, groupID: group.id), password: "s3cret")
        try store.setSSHPassword("sshpw", for: store.profiles[0].id)

        let bundle = store.bundle(for: nil, includePasswords: true, includeSSHPasswords: true)
        let data = try ConnectionFile.encode(bundle, password: "file-pass")
        #expect(try ConnectionFile.isEncrypted(data))
        #expect(!String(decoding: data, as: UTF8.self).contains("s3cret"))
        #expect(throws: ConnectionFileError.wrongPassword) { try ConnectionFile.decode(data, password: "nope") }
        #expect(throws: ConnectionFileError.passwordRequired) { try ConnectionFile.decode(data, password: nil) }

        let (target, _) = makeStore()
        let imported = try target.importBundle(ConnectionFile.decode(data, password: "file-pass"))
        #expect(imported.count == 1)
        #expect(imported[0].id != store.profiles[0].id)
        #expect(target.groups.first?.name == "Prod")
        #expect(imported[0].groupID == target.groups.first?.id)
        #expect(target.password(for: imported[0].id) == "s3cret")
        #expect(target.sshPassword(for: imported[0].id) == "sshpw")
    }

    @Test func plainExportNeverContainsPasswords() throws {
        let (store, _) = makeStore()
        try store.save(ConnectionProfile(name: "DB", kind: .mysql), password: "s3cret")
        let data = try ConnectionFile.encode(
            store.bundle(for: nil, includePasswords: true, includeSSHPasswords: true), password: nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("s3cret"))
        #expect(try ConnectionFile.decode(data, password: nil).connections.first?.password == nil)
        #expect(throws: ConnectionFileError.notATableRoadFile) {
            try ConnectionFile.decode(Data("{}".utf8), password: nil)
        }
    }
}
