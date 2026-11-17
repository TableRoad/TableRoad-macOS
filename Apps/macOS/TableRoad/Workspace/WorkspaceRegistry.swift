import Foundation
import Observation

/// Lets windows that belong to a connection (e.g. Running Queries) find that connection's open workspace.
@MainActor @Observable
final class WorkspaceRegistry {
    private final class WeakBox {
        weak var model: WorkspaceModel?
        init(_ model: WorkspaceModel) { self.model = model }
    }

    private var boxes: [UUID: WeakBox] = [:]

    func register(_ model: WorkspaceModel) {
        boxes[model.profile.id] = WeakBox(model)
    }

    func unregister(_ model: WorkspaceModel) {
        if boxes[model.profile.id]?.model === model { boxes[model.profile.id] = nil }
    }

    func workspace(for connectionID: UUID) -> WorkspaceModel? {
        boxes[connectionID]?.model
    }
}
