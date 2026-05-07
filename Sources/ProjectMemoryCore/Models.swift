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

public struct ProjectActivityRule: Identifiable, Codable, Equatable {
    public let id: UUID
    public let projectID: UUID
    public let kind: Kind
    /// Pattern is stored only after `trimmingCharacters(in: .whitespacesAndNewlines)`.
    /// Resolver applies kind-specific normalization at match time:
    ///   - urlContains:  normalizedURL.contains(pattern.lowercased())
    ///   - titleContains: stripInvisibleControls(title).lowercased().contains(pattern.lowercased())
    ///   - bundleIDEquals: pattern == draft.bundleID  (case-sensitive — macOS bundle IDs are case-sensitive)
    public let pattern: String
    public let isEnabled: Bool
    public let createdAt: Date

    public enum Kind: String, Codable, CaseIterable {
        case urlContains
        case titleContains
        case bundleIDEquals
    }

    public init(id: UUID = UUID(), projectID: UUID, kind: Kind, pattern: String, isEnabled: Bool, createdAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public struct ActivitySessionDraft: Equatable {
    public let id: UUID                  // = firstFrame.id (Q4 锁定)
    public let startedAt: Date
    public let endedAt: Date
    public let bundleID: String
    public let appName: String
    public let browserHost: String?      // normalize 后的 host；非浏览器为 nil
    public let category: ActivityCategory
    /// max 5; first-seen order; sanitized via `TextSanitizer.stripInvisibleControls` then trimmed; empty strings dropped; deduped.
    public let titleSamples: [String]
    public let frameCount: Int
    public let frameIDs: [UUID]

    public init(id: UUID, startedAt: Date, endedAt: Date, bundleID: String, appName: String, browserHost: String?, category: ActivityCategory, titleSamples: [String], frameCount: Int, frameIDs: [UUID]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundleID = bundleID
        self.appName = appName
        self.browserHost = browserHost
        self.category = category
        self.titleSamples = titleSamples
        self.frameCount = frameCount
        self.frameIDs = frameIDs
    }
}

public struct ResolvedActivitySession: Equatable {
    public let draft: ActivitySessionDraft
    public let assignmentStatus: AssignmentStatus
    public let projectID: UUID?
    /// "manual" | "rule:<uuid>" | nil
    public let assignmentSource: String?

    public init(draft: ActivitySessionDraft, assignmentStatus: AssignmentStatus, projectID: UUID?, assignmentSource: String?) {
        self.draft = draft
        self.assignmentStatus = assignmentStatus
        self.projectID = projectID
        self.assignmentSource = assignmentSource
    }
}

public struct PersistedActivitySession: Identifiable, Equatable, Codable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let bundleID: String
    public let appName: String
    public let browserHost: String?
    public let category: ActivityCategory
    public let assignmentStatus: AssignmentStatus
    public let projectID: UUID?
    public let assignmentSource: String?
    public let titleSamples: [String]
    public let frameCount: Int

    public init(id: UUID, startedAt: Date, endedAt: Date, bundleID: String, appName: String, browserHost: String?, category: ActivityCategory, assignmentStatus: AssignmentStatus, projectID: UUID?, assignmentSource: String?, titleSamples: [String], frameCount: Int) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundleID = bundleID
        self.appName = appName
        self.browserHost = browserHost
        self.category = category
        self.assignmentStatus = assignmentStatus
        self.projectID = projectID
        self.assignmentSource = assignmentSource
        self.titleSamples = titleSamples
        self.frameCount = frameCount
    }
}

public struct SelectedSourceSnippet: Equatable {
    public let source: MemorySource
    public let snippet: String
    public let truncated: Bool

    public init(source: MemorySource, snippet: String, truncated: Bool) {
        self.source = source
        self.snippet = snippet
        self.truncated = truncated
    }
}

public struct ActivitySessionCaps: Equatable {
    public let maxSourcesPerBrief: Int
    public let maxSourcesPerAnswer: Int
    public let maxCharsPerSource: Int
    public let maxTotalBriefActivityChars: Int
    public let maxTotalAnswerActivityChars: Int

    public init(
        maxSourcesPerBrief: Int,
        maxSourcesPerAnswer: Int,
        maxCharsPerSource: Int,
        maxTotalBriefActivityChars: Int,
        maxTotalAnswerActivityChars: Int
    ) {
        self.maxSourcesPerBrief = maxSourcesPerBrief
        self.maxSourcesPerAnswer = maxSourcesPerAnswer
        self.maxCharsPerSource = maxCharsPerSource
        self.maxTotalBriefActivityChars = maxTotalBriefActivityChars
        self.maxTotalAnswerActivityChars = maxTotalAnswerActivityChars
    }

    public static let `default` = ActivitySessionCaps(
        maxSourcesPerBrief: 4,
        maxSourcesPerAnswer: 2,
        maxCharsPerSource: 400,
        maxTotalBriefActivityChars: 900,
        maxTotalAnswerActivityChars: 600
    )
}

public struct SelectionTotals: Equatable {
    public let maxSourcesPerBrief: Int
    public let maxSourcesPerAnswer: Int
    public let maxSourcesPerProject: Int

    public init(maxSourcesPerBrief: Int, maxSourcesPerAnswer: Int, maxSourcesPerProject: Int) {
        self.maxSourcesPerBrief = maxSourcesPerBrief
        self.maxSourcesPerAnswer = maxSourcesPerAnswer
        self.maxSourcesPerProject = maxSourcesPerProject
    }

    public static let `default` = SelectionTotals(
        maxSourcesPerBrief: 12,
        maxSourcesPerAnswer: 8,
        maxSourcesPerProject: 3
    )
}
