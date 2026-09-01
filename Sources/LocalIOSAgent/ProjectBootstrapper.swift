import Darwin
import Foundation

enum ProjectBootstrapItem: String, Sendable, Equatable {
    case agentsInstructions
    case xcodeBuildMCPSkill

    var title: String {
        switch self {
        case .agentsInstructions: "AGENTS.md"
        case .xcodeBuildMCPSkill: "XcodeBuildMCP skill"
        }
    }
}

enum ProjectBootstrapStatus: Sendable, Equatable {
    case created
    case alreadyPresent
    case failed(String)
}

struct ProjectBootstrapAction: Identifiable, Sendable, Equatable {
    let item: ProjectBootstrapItem
    let relativePath: String
    let status: ProjectBootstrapStatus

    var id: String { item.rawValue }
}

struct ProjectBootstrapReport: Sendable, Equatable {
    let projectPath: String?
    let actions: [ProjectBootstrapAction]
    let projectError: String?

    static let noProject = ProjectBootstrapReport(
        projectPath: nil,
        actions: [],
        projectError: nil
    )

    var createdItems: [ProjectBootstrapItem] {
        actions.compactMap { action in
            action.status == .created ? action.item : nil
        }
    }

    var failures: [String] {
        var values = projectError.map { [$0] } ?? []
        values += actions.compactMap { action in
            guard case .failed(let detail) = action.status else { return nil }
            return "\(action.item.title): \(detail)"
        }
        return values
    }
}

protocol ProjectBootstrapping: Sendable {
    func bootstrapProject(at projectURL: URL?) async -> ProjectBootstrapReport
}

protocol ProjectTemplateLoading: Sendable {
    func data(for item: ProjectBootstrapItem) throws -> Data
}

struct ProjectTemplateSearchLoader: ProjectTemplateLoading {
    private let searchRoots: [URL]

    init(searchRoots: [URL] = ProjectTemplateSearchLoader.defaultSearchRoots()) {
        self.searchRoots = searchRoots
    }

    func data(for item: ProjectBootstrapItem) throws -> Data {
        let fileName: String
        switch item {
        case .agentsInstructions:
            fileName = "iOS-AGENTS.md"
        case .xcodeBuildMCPSkill:
            fileName = "XcodeBuildMCP-SKILL.md"
        }

        for root in searchRoots {
            let candidate = root.appending(path: fileName, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }
        throw ProjectBootstrapError.templateMissing(fileName)
    }

    private static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL.appending(path: "ProjectBootstrap", directoryHint: .isDirectory))
        }
        roots.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appending(path: "Templates", directoryHint: .isDirectory)
        )
        return roots
    }
}

struct ProjectBootstrapper: ProjectBootstrapping {
    private struct Specification: Sendable {
        let item: ProjectBootstrapItem
        let relativePath: String
    }

    private let templates: any ProjectTemplateLoading

    init(templates: any ProjectTemplateLoading = ProjectTemplateSearchLoader()) {
        self.templates = templates
    }

    func bootstrapProject(at projectURL: URL?) async -> ProjectBootstrapReport {
        guard let projectURL else { return .noProject }
        let fileManager = FileManager.default
        let standardizedRoot = projectURL.standardizedFileURL.resolvingSymlinksInPath()

        guard isSupportedProjectRoot(standardizedRoot, fileManager: fileManager) else {
            return ProjectBootstrapReport(
                projectPath: standardizedRoot.path,
                actions: [],
                projectError: "Xcode yoki Swift Package build artifact topilmagani uchun agent fayllari yozilmadi."
            )
        }

        let specifications = [
            Specification(item: .agentsInstructions, relativePath: "AGENTS.md"),
            Specification(
                item: .xcodeBuildMCPSkill,
                relativePath: ".opencode/skills/xcodebuildmcp-cli/SKILL.md"
            ),
        ]
        let actions = specifications.map { specification in
            createIfMissing(
                specification,
                projectRoot: standardizedRoot,
                fileManager: fileManager
            )
        }
        return ProjectBootstrapReport(
            projectPath: standardizedRoot.path,
            actions: actions,
            projectError: nil
        )
    }

    private func createIfMissing(
        _ specification: Specification,
        projectRoot: URL,
        fileManager: FileManager
    ) -> ProjectBootstrapAction {
        let destination = projectRoot.appending(
            path: specification.relativePath,
            directoryHint: .notDirectory
        )
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            let status: ProjectBootstrapStatus = isDirectory.boolValue
                ? .failed("Fayl yo‘lida papka mavjud: \(specification.relativePath)")
                : .alreadyPresent
            return ProjectBootstrapAction(
                item: specification.item,
                relativePath: specification.relativePath,
                status: status
            )
        }

        do {
            let data = try templates.data(for: specification.item)
            try validateParentPath(
                of: destination,
                relativePath: specification.relativePath,
                projectRoot: projectRoot,
                fileManager: fileManager
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if try installAtomicallyIfMissing(
                data,
                at: destination,
                fileManager: fileManager
            ) == false {
                return ProjectBootstrapAction(
                    item: specification.item,
                    relativePath: specification.relativePath,
                    status: .alreadyPresent
                )
            }
            return ProjectBootstrapAction(
                item: specification.item,
                relativePath: specification.relativePath,
                status: .created
            )
        } catch {
            return ProjectBootstrapAction(
                item: specification.item,
                relativePath: specification.relativePath,
                status: .failed(error.localizedDescription)
            )
        }
    }

    private func validateParentPath(
        of destination: URL,
        relativePath: String,
        projectRoot: URL,
        fileManager: FileManager
    ) throws {
        let expectedPrefix = projectRoot.path.hasSuffix("/")
            ? projectRoot.path
            : projectRoot.path + "/"
        guard destination.path.hasPrefix(expectedPrefix) else {
            throw ProjectBootstrapError.unsafeDestination(relativePath)
        }

        var current = projectRoot
        for component in relativePath.split(separator: "/").dropLast() {
            current.append(path: String(component), directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: current.path) else { continue }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ProjectBootstrapError.unsafeDestination(relativePath)
            }
        }
    }

    private func installAtomicallyIfMissing(
        _ data: Data,
        at destination: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let temporaryURL = destination.deletingLastPathComponent().appending(
            path: ".local-ios-agent-\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)

        let result = temporaryURL.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.link(sourcePath, destinationPath)
            }
        }
        guard result != 0 else { return true }
        let linkError = errno
        if linkError == EEXIST { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(linkError))
    }

    private func isSupportedProjectRoot(
        _ projectURL: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let children = try? fileManager.contentsOfDirectory(
                  at: projectURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return false
        }
        return children.contains { child in
            child.pathExtension == "xcworkspace"
                || child.pathExtension == "xcodeproj"
                || child.lastPathComponent == "Package.swift"
        }
    }
}

enum ProjectBootstrapError: LocalizedError, Sendable, Equatable {
    case templateMissing(String)
    case unsafeDestination(String)

    var errorDescription: String? {
        switch self {
        case .templateMissing(let name):
            "Ilova resurslarida \(name) shabloni topilmadi."
        case .unsafeDestination(let path):
            "Xavfsizlik uchun symbolic link orqali \(path) yozilmadi."
        }
    }
}
