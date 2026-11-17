import Foundation

/// Where the open-source project lives (the website links to the same places: Website/config/tableroad.php).
enum ProjectLinks {
    static let repository = URL(string: "https://github.com/TableRoad/TableRoad-macOS")!
    static let issues = repository.appending(path: "issues")
    static let newIssue = repository.appending(path: "issues/new")
    static let releases = repository.appending(path: "releases")
    static let licence = repository.appending(path: "blob/main/LICENSE")
    static let contributing = repository.appending(path: "blob/main/CONTRIBUTING.md")
    static let licenceName = "MIT"
}
