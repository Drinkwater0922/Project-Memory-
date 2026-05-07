import Foundation

public struct Project: Identifiable, Equatable, Codable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, rootPath: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
    }
}

public enum SourceKind: String, Codable, CaseIterable {
    case markdown
    case pdf
    case html
    case text
    case gitCommit
    case webCapture
    case activitySession   // <-- new in Phase 2
    case unsupported
}

public struct MemorySource: Identifiable, Equatable, Codable {
    public let id: UUID
    public var projectID: UUID?
    public var kind: SourceKind
    public var title: String
    public var path: String
    public var url: String?
    public var extractedText: String
    public var modifiedAt: Date
    public var indexedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID?,
        kind: SourceKind,
        title: String,
        path: String,
        url: String? = nil,
        extractedText: String,
        modifiedAt: Date,
        indexedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.title = title
        self.path = path
        self.url = url
        self.extractedText = extractedText
        self.modifiedAt = modifiedAt
        self.indexedAt = indexedAt
    }
}

public enum TimelineEventKind: String, Codable {
    case sourceAdded
    case sourceUpdated
    case gitCommit
    case questionAnswered
}

public struct TimelineEvent: Identifiable, Equatable, Codable {
    public let id: UUID
    public var projectID: UUID
    public var sourceID: UUID?
    public var kind: TimelineEventKind
    public var title: String
    public var summary: String
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceID: UUID?,
        kind: TimelineEventKind,
        title: String,
        summary: String,
        occurredAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceID = sourceID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
    }
}

public struct Brief: Identifiable, Equatable, Codable {
    public let id: UUID
    public var projectID: UUID?
    public var title: String
    public var body: String
    public var sourceIDs: [UUID]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID?,
        title: String,
        body: String,
        sourceIDs: [UUID],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.sourceIDs = sourceIDs
        self.createdAt = createdAt
    }
}

public enum ActivityCategory: String, Codable, CaseIterable {
    case work
    case socialMedia
    case chat
    case other
}

public struct ActivityCandidate: Equatable {
    public let observedAt: Date
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?

    public init(
        observedAt: Date,
        bundleID: String,
        appName: String,
        windowTitle: String?,
        browserURL: String?
    ) {
        self.observedAt = observedAt
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
    }
}

public struct ActivityFrame: Identifiable, Equatable, Codable {
    public let id: UUID
    public let observedAt: Date
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?
    public let category: ActivityCategory
    public let projectID: UUID?

    public init(
        id: UUID = UUID(),
        observedAt: Date,
        bundleID: String,
        appName: String,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        category: ActivityCategory,
        projectID: UUID? = nil
    ) {
        self.id = id
        self.observedAt = observedAt
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.category = category
        self.projectID = projectID
    }
}

public enum ProjectFilter: Equatable {
    case any
    case unassigned
    case project(UUID)
}

public enum AssignmentStatus: String, Codable, CaseIterable, Equatable {
    case unassigned
    case ruleAssigned
    case manualAssigned
    case ignored
}

public struct PreservedAssignment: Equatable {
    public let sessionID: UUID
    public let assignmentStatus: AssignmentStatus  // .manualAssigned 或 .ignored
    public let projectID: UUID?

    public init(sessionID: UUID, assignmentStatus: AssignmentStatus, projectID: UUID?) {
        self.sessionID = sessionID
        self.assignmentStatus = assignmentStatus
        self.projectID = projectID
    }
}
