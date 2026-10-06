import Foundation

private struct WorkspaceDraft: Codable {
    var newTask: String
    var followup: String
    var mode: PromptMode
}

extension AppModel {
    // Outside Project: drafts never enter the guest, checkpoints, or exported copies.
    var draftsDirectory: URL { store.root.appendingPathComponent(".drafts", isDirectory: true) }
    func draftURL(_ id: UUID) -> URL { draftsDirectory.appendingPathComponent(id.uuidString + ".json") }

    func loadDrafts() {
        loadingDrafts = true
        defer { loadingDrafts = false }
        for workspace in workspaces {
            let id = workspace.id, url = draftURL(workspace.id)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let draft = try JSONDecoder().decode(WorkspaceDraft.self, from: Data(contentsOf: url))
                prompts[id] = draft.newTask
                followupPrompts[id] = draft.followup
                composerModes[id] = draft.mode
                savedDrafts.insert(id)
            } catch {
                unreadableDrafts.insert(id)
                draftErrors[id] = "Saved draft couldn’t be read. It has not been overwritten. Restore \(url.path), then reopen Harbor."
            }
        }
    }

    func saveChangedDrafts<Value: Equatable>(old: [UUID: Value], new: [UUID: Value]) {
        guard !loadingDrafts else { return }
        for id in Set(old.keys).union(new.keys) where old[id] != new[id] { saveDraft(id) }
    }

    func canRetryDraftSave(_ id: UUID) -> Bool { !unreadableDrafts.contains(id) && !storageBlocked }

    func saveDraft(_ id: UUID) {
        guard !loadingDrafts, workspaces.contains(where: { $0.id == id }) else { return }
        savedDrafts.remove(id)
        guard !unreadableDrafts.contains(id) else { return }
        guard !storageBlocked else {
            draftErrors[id] = "Draft not saved. Restore Harbor’s storage access before closing the app."
            return
        }
        do {
            try FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let draft = WorkspaceDraft(newTask: prompts[id] ?? "", followup: followupPrompts[id] ?? "", mode: composerModes[id] ?? .newTask)
            // Small per-workspace snapshots commit immediately, including the last edit before quitting.
            try JSONEncoder().encode(draft).write(to: draftURL(id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL(id).path)
            draftErrors[id] = nil
            savedDrafts.insert(id)
        } catch {
            draftErrors[id] = "Draft not saved. Check available space and folder access, then retry before closing Harbor."
        }
    }
}
