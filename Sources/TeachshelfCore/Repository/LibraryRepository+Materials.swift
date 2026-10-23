import Foundation

extension LibraryRepository {
    public func updateMaterial(_ material: MaterialRecord) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == material.id }) else { throw LibraryError.missingRecord("资料") }
            guard !material.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("请输入资料标题。") }
            let existing = state.materials[index]
            guard existing.storedPath == material.storedPath, existing.isManaged == material.isManaged, existing.sourcePath == material.sourcePath else {
                throw LibraryError.invalidInput("编辑资料时不能改变文件位置，请重新导入文件。")
            }
            var material = material
            if material.courseID != existing.courseID { material.folderID = nil; material.customOrder = nil }
            material.category = try rememberCategory(material.category, in: &state)
            state.materials[index] = material
        }
    }

    /// Reconnect an external reference without changing its identity or annotations.
    /// Managed copies retain their library paths and must be reimported instead.
    public func relinkMaterial(id: UUID, to url: URL) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("资料") }
            guard !state.materials[index].isManaged else { throw LibraryError.invalidInput("库内副本不能重新链接，请重新导入文件。") }
            let url = url.standardizedFileURL
            try ensureSafePath(url, beneath: nil)
            guard fileManager.fileExists(atPath: url.path) else { throw LibraryError.missingFile(url.path) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw LibraryError.invalidInput("请选择一个普通文件。") }
            state.materials[index].sourcePath = url.path
            state.materials[index].storedPath = url.path
            state.materials[index].originalName = url.lastPathComponent
            state.materials[index].size = Int64(values.fileSize ?? 0)
        }
    }

    /// Removing a record deliberately retains its managed file on disk.
    public func removeMaterials(ids: Set<UUID>) throws {
        try commit { state in
            state.materials.removeAll { ids.contains($0.id) }
            for index in state.tasks.indices {
                state.tasks[index].materialIDs.removeAll { ids.contains($0) }
                for e in state.tasks[index].exceptions.indices {
                    state.tasks[index].exceptions[e].details?.materialIDs.removeAll { ids.contains($0) }
                }
            }
        }
    }
    public func setFavorite(id: UUID, favorite: Bool) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("资料") }
            state.materials[index].isFavorite = favorite
        }
    }
    public func recordOpen(id: UUID) throws {
        try commit { state in
            guard let index = state.materials.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("资料") }
            state.materials[index].lastOpenedAt = Date()
        }
    }
    public func resolveURL(_ material: MaterialRecord) throws -> URL {
        try withLock {
            // Editors and drag providers may still hold the pre-move value snapshot.
            let current = snapshot.materials.first(where: { $0.id == material.id }) ?? material
            let url = try fileURL(for: current)
            try ensureSafePath(url, beneath: current.isManaged ? root : nil)
            guard fileManager.fileExists(atPath: url.path) else { throw LibraryError.missingFile(url.path) }
            return url
        }
    }

    public func importFiles(urls: [URL], courseID: UUID?, category: String, copy: Bool, folderID: UUID? = nil) throws -> ImportSummary {
        try withLock {
            try ensureCourse(courseID)
            try Self.ensureMaterialFolder(folderID, courseID: courseID, in: snapshot)
            var next = snapshot
            let normalizedCategory = try rememberCategory(category, in: &next)
            var summary = ImportSummary()
            var created: [URL] = []
            var seen = Set(next.materials.filter { $0.courseID == courseID }.map(\.sourcePath))
            let candidates = collectFiles(urls, summary: &summary)
            do {
                for source in candidates {
                    if seen.contains(source.path) { summary.skipped += 1; continue }
                    do {
                        let id = UUID()
                        let name = source.lastPathComponent
                        var material = MaterialRecord(id: id, courseID: courseID, title: source.deletingPathExtension().lastPathComponent, originalName: name, sourcePath: source.path, storedPath: source.path, isManaged: copy, category: normalizedCategory)
                        material.folderID = folderID
                        let existingRanks = next.materials.filter { $0.courseID == courseID && $0.folderID == folderID }.compactMap(\.customOrder)
                        if !existingRanks.isEmpty || next.courses.first(where: { $0.id == courseID })?.materialSort == .custom {
                            material.customOrder = (existingRanks.max() ?? -1) + 1
                        }
                        if copy { material.storedPath = MaterialStorageLayout.relativePath(for: material, courses: next.courses) }
                        let values = try source.resourceValues(forKeys: [.fileSizeKey])
                        material.size = Int64(values.fileSize ?? 0)
                        if copy {
                            let target = root.appendingPathComponent(material.storedPath)
                            try ensureSafePath(target, beneath: root)
                            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fileManager.copyItem(at: source, to: target)
                            created.append(target)
                        }
                        next.materials.append(material)
                        seen.insert(source.path); summary.imported += 1
                    } catch { summary.errors.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
                }
                if summary.imported > 0 {
                    try saveSnapshot(next)
                }
                return summary
            } catch {
                for url in created {
                    try? fileManager.removeItem(at: url)
                    removeEmptyMaterialDirectories(from: url.deletingLastPathComponent())
                }
                throw error
            }
        }
    }

    public func setMaterialSort(_ mode: MaterialSortMode, courseID: UUID) throws {
        try commit { state in
            guard let index = state.courses.firstIndex(where: { $0.id == courseID }) else { throw LibraryError.missingRecord("课程") }
            if mode == .custom {
                let usesDefaultOrder = state.courses[index].materialSort == nil
                let previous = state.courses[index].materialSort ?? .name
                let records = state.materials.filter { $0.courseID == courseID }
                for group in Dictionary(grouping: records, by: \.folderID).values where usesDefaultOrder || group.allSatisfy({ $0.customOrder == nil }) {
                    for (rank, material) in MaterialOrdering.sorted(group, by: previous).enumerated() {
                        state.materials[state.materials.firstIndex { $0.id == material.id }!].customOrder = rank
                    }
                }
            }
            state.courses[index].materialSort = mode
        }
    }

    public func reorderMaterials(ids: Set<UUID>, before target: UUID?, courseID: UUID, folderID: UUID?) throws {
        try commit { state in
            try Self.ensureMaterialIDs(ids, courseID: courseID, in: state)
            try Self.ensureMaterialFolder(folderID, courseID: courseID, in: state)
            guard !ids.isEmpty else { return }
            let records = MaterialOrdering.sorted(state.materials.filter { $0.courseID == courseID && $0.folderID == folderID }, by: .custom)
            guard ids.isSubset(of: Set(records.map(\.id))), target == nil || records.contains(where: { $0.id == target }) else {
                throw LibraryError.invalidInput("只能调整当前文件夹中的资料顺序。")
            }
            if let target, ids.contains(target) { return }
            let moving = records.filter { ids.contains($0.id) }
            var remaining = records.filter { !ids.contains($0.id) }
            let index = target.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.count
            remaining.insert(contentsOf: moving, at: index)
            for (rank, record) in remaining.enumerated() {
                state.materials[state.materials.firstIndex { $0.id == record.id }!].customOrder = rank
            }
            state.courses[state.courses.firstIndex { $0.id == courseID }!].materialSort = .custom
        }
    }

    @discardableResult
    public func createMaterialFolder(name: String, courseID: UUID, parentID: UUID? = nil, materialIDs: Set<UUID> = []) throws -> MaterialFolder {
        var result: MaterialFolder!
        try commit { state in
            try Self.ensureMaterialIDs(materialIDs, courseID: courseID, in: state)
            try Self.ensureMaterialFolder(parentID, courseID: courseID, in: state)
            result = MaterialFolder(courseID: courseID, parentID: parentID, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            state.materialFolders.append(result)
            Self.assignMaterials(materialIDs, to: result.id, in: &state)
        }
        return result
    }

    public func renameMaterialFolder(id: UUID, name: String) throws {
        try commit { state in
            guard let index = state.materialFolders.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("文件夹") }
            state.materialFolders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func updateMaterialFolder(id: UUID, name: String, colorHex: String?) throws {
        try commit { state in
            guard let index = state.materialFolders.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("文件夹") }
            if let colorHex, RGBColor(hex: colorHex) == nil { throw LibraryError.invalidInput("请输入六位 HEX 文件夹颜色。") }
            state.materialFolders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            state.materialFolders[index].colorHex = colorHex.flatMap { RGBColor(hex: $0)?.hex }
        }
    }

    public func moveMaterials(ids: Set<UUID>, to folderID: UUID?, courseID: UUID) throws {
        try commit { state in
            try Self.ensureMaterialIDs(ids, courseID: courseID, in: state)
            try Self.ensureMaterialFolder(folderID, courseID: courseID, in: state)
            Self.assignMaterials(ids, to: folderID, in: &state)
        }
    }

    /// Dissolving a group returns all descendants to its parent without deleting files.
    public func dissolveMaterialFolder(id: UUID) throws {
        try commit { state in
            guard let folder = state.materialFolders.first(where: { $0.id == id }) else { throw LibraryError.missingRecord("文件夹") }
            let descendants = Set(state.materialFolders.filter { MaterialOrdering.folderPath($0.id, in: state.materialFolders).contains(where: { $0.id == id }) }.map(\.id))
            let ids = Set(state.materials.filter { $0.folderID.map(descendants.contains) == true }.map(\.id))
            Self.assignMaterials(ids, to: folder.parentID, in: &state)
            state.materialFolders.removeAll { descendants.contains($0.id) }
        }
    }

    /// Only managed library copies enter Trash; external originals remain untouched.
    public func trashMaterials(ids: Set<UUID>) throws {
        try trashMaterials(ids: ids, moveToTrash: { source in
            var trashed: NSURL?
            try fileManager.trashItem(at: source, resultingItemURL: &trashed)
            guard let trashed else { throw LibraryError.invalidInput("文件已移到废纸篓，但无法记录其恢复位置。请从废纸篓恢复文件后重试。") }
            return trashed as URL
        })
    }

    func trashMaterials(ids: Set<UUID>, moveToTrash: (URL) throws -> URL) throws {
        try withLock {
            guard !ids.isEmpty, ids.isSubset(of: Set(snapshot.materials.map(\.id))) else { throw LibraryError.missingRecord("资料") }
            var moved: [(URL, URL)] = []
            do {
                for record in snapshot.materials where ids.contains(record.id) && record.isManaged {
                    let source = try fileURL(for: record)
                    try ensureSafePath(source, beneath: filesURL)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryError.unsafePath(source.path) }
                    moved.append((source, try moveToTrash(source)))
                }
                try removeMaterials(ids: ids)
            } catch {
                var failed: [String] = []
                for (original, trashed) in moved.reversed() {
                    do { try fileManager.moveItem(at: trashed, to: original) }
                    catch { failed.append(original.lastPathComponent) }
                }
                if !failed.isEmpty { throw LibraryError.invalidInput("删除未完成，部分文件可从废纸篓恢复：" + failed.joined(separator: "、")) }
                throw error
            }
        }
    }

    public func exportMaterials(ids: Set<UUID>, to destination: URL) throws {
        try withLock {
            let records = snapshot.materials.filter { ids.contains($0.id) }
            guard !ids.isEmpty, records.count == ids.count else { throw LibraryError.missingRecord("所选资料") }
            let destination = destination.standardizedFileURL
            try ensureSafePath(destination, beneath: nil)
            guard !isBeneath(destination, root: root), destination.pathExtension.lowercased() == "zip" else {
                throw LibraryError.invalidInput("请将 ZIP 导出到资料库以外的文件夹。")
            }
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".teachshelf-export-\(UUID().uuidString)")
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: stage) }
            let payload = stage.appendingPathComponent("课程资料", isDirectory: true)
            try fileManager.createDirectory(at: payload, withIntermediateDirectories: false)
            var used: Set<String> = []
            let multipleCourses = Set(records.map(\.courseID)).count > 1
            var directories: [UUID: URL] = [:]
            for record in records {
                var directory = payload
                if multipleCourses {
                    let course = snapshot.courses.first { $0.id == record.courseID }
                    directory.appendPathComponent(MaterialStorageLayout.component(course?.name ?? "未分类", byteLimit: 120) + " [\(record.courseID?.uuidString ?? "未分类")]")
                }
                for folder in MaterialOrdering.folderPath(record.folderID, in: snapshot.materialFolders) {
                    directory.appendPathComponent(folder.name)
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                directories[record.id] = directory
            }
            for record in MaterialOrdering.sorted(records, by: .custom) {
                let source = try resolveURL(record)
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryError.unsafePath(source.path) }
                let directory = directories[record.id]!
                let name = MaterialStorageLayout.component(record.originalName, byteLimit: 218)
                let ext = URL(fileURLWithPath: name).pathExtension
                let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                var candidate = directory.appendingPathComponent(name), number = 2
                while fileManager.fileExists(atPath: candidate.path) || used.contains(candidate.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))) {
                    candidate = directory.appendingPathComponent("\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")); number += 1
                }
                used.insert(candidate.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
                try fileManager.copyItem(at: source, to: candidate)
            }
            let archive = stage.appendingPathComponent("export.zip")
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--norsrc", "--keepParent", payload.path, archive.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LibraryError.invalidInput("压缩失败：" + (String(data: data, encoding: .utf8) ?? "无法生成 ZIP")) }
            try ZipUTF8Names.mark(in: archive)
            try atomicRename(archive, destination)
        }
    }

    static func ensureMaterialFolder(_ id: UUID?, courseID: UUID?, in state: LibraryState) throws {
        if let id, !state.materialFolders.contains(where: { $0.id == id && $0.courseID == courseID }) {
            throw LibraryError.invalidInput("文件夹不属于当前课程。")
        }
    }
    private static func ensureMaterialIDs(_ ids: Set<UUID>, courseID: UUID, in state: LibraryState) throws {
        guard state.courses.contains(where: { $0.id == courseID }), ids.isSubset(of: Set(state.materials.filter { $0.courseID == courseID }.map(\.id))) else {
            throw LibraryError.invalidInput("请选择同一课程中的资料。")
        }
    }
    private static func assignMaterials(_ ids: Set<UUID>, to folderID: UUID?, in state: inout LibraryState) {
        var rank = (state.materials.filter { $0.folderID == folderID }.compactMap(\.customOrder).max() ?? -1) + 1
        for record in MaterialOrdering.sorted(state.materials.filter { ids.contains($0.id) }, by: .custom) where record.folderID != folderID {
            let index = state.materials.firstIndex { $0.id == record.id }!
            state.materials[index].folderID = folderID; state.materials[index].customOrder = rank; rank += 1
        }
    }
    static func validateMaterialOrganization(_ state: LibraryState) throws {
        guard Set(state.materialFolders.map(\.id)).count == state.materialFolders.count else { throw LibraryError.invalidInput("文件夹编号重复。") }
        var names: Set<String> = []
        for folder in state.materialFolders {
            if let color = folder.colorHex, !ColorPalette.isStoredColor(color) { throw LibraryError.invalidInput("文件夹颜色无效。") }
            guard state.courses.contains(where: { $0.id == folder.courseID }), !folder.name.isEmpty,
                  folder.name == folder.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  folder.name.utf8.count <= 120, folder.name != ".", folder.name != "..",
                  !folder.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }) else {
                throw LibraryError.invalidInput("文件夹名称不能为空、超过 120 字节或包含路径分隔符。")
            }
            try ensureMaterialFolder(folder.parentID, courseID: folder.courseID, in: state)
            var visited: Set<UUID> = [folder.id], parent = folder.parentID
            while let id = parent {
                guard visited.insert(id).inserted else { throw LibraryError.invalidInput("文件夹不能形成循环。") }
                parent = state.materialFolders.first { $0.id == id }?.parentID
            }
            let key = "\(folder.courseID)/\(folder.parentID?.uuidString ?? "root")/" + folder.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw LibraryError.invalidInput("同一位置已存在同名文件夹。") }
        }
        for record in state.materials {
            try ensureMaterialFolder(record.folderID, courseID: record.courseID, in: state)
            if let rank = record.customOrder, rank < 0 || rank >= Int.max - state.materials.count - 1 { throw LibraryError.invalidInput("资料顺序无效。") }
        }
    }

    func fileURL(for material: MaterialRecord) throws -> URL {
        if material.isManaged {
            guard !material.storedPath.hasPrefix("/"), material.storedPath.hasPrefix("files/"), !material.storedPath.split(separator: "/").contains(".."), !material.storedPath.contains("\0") else { throw LibraryError.unsafePath(material.storedPath) }
            let url = root.appendingPathComponent(material.storedPath).standardizedFileURL
            guard isBeneath(url, root: filesURL), url.path != filesURL.path else { throw LibraryError.unsafePath(material.storedPath) }
            return url
        }
        guard material.storedPath.hasPrefix("/") else { throw LibraryError.unsafePath(material.storedPath) }
        return URL(fileURLWithPath: material.storedPath).standardizedFileURL
    }

    private func collectFiles(_ urls: [URL], summary: inout ImportSummary) -> [URL] {
        var result: [URL] = []
        func visit(_ url: URL) {
            do {
                let url = url.standardizedFileURL
                try ensureSafePath(url, beneath: nil)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) { visit(child) }
                } else if values.isRegularFile == true { result.append(url) }
                else { summary.skipped += 1 }
            } catch { summary.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)"); summary.skipped += 1 }
        }
        for url in urls { visit(url) }
        return result
    }

    private static let builtInCategories = ["课件", "教材", "笔记", "参考资料", "其他"]
    func normalizeCategory(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LibraryError.invalidInput("类别名称需要 1–40 个字符，不能包含换行或控制字符。") }
        guard !["作业", "全部类别", "全部用途"].contains(name) else { throw LibraryError.invalidInput("请使用具体的资料类别；作业请放入课程作业文件夹。") }
        return name
    }
    func rememberCategory(_ value: String, in state: inout LibraryState) throws -> String {
        let normalized = try normalizeCategory(value)
        let known = Self.builtInCategories + state.customCategories + state.materials.map(\.category)
        let name = known.first { $0.caseInsensitiveCompare(normalized) == .orderedSame } ?? normalized
        if !Self.builtInCategories.contains(name), !state.customCategories.contains(name) { state.customCategories.append(name) }
        return name
    }
}
