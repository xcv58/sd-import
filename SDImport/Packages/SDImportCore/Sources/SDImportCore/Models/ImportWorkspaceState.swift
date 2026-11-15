import Foundation

public enum ImportUIPhase: String, Equatable, Sendable {
    case source
    case scanning
    case review
    case preparing
    case copying
    case completed
    case failed
    case cancelled
}

public enum ImportOperationKind: String, Equatable, Sendable {
    case scan
    case prepareImport
    case copy
    case portableReceiptOverride
    case eject
}

public struct ImportWorkspaceAttempt: Equatable, Sendable {
    public let id: UUID
    public let operation: ImportOperationKind
    public private(set) var cancellationRequested = false

    public init(id: UUID = UUID(), operation: ImportOperationKind) {
        self.id = id
        self.operation = operation
    }

    public mutating func requestCancellation() {
        cancellationRequested = true
    }

    public func accepts(_ id: UUID, isProgress: Bool = false) -> Bool {
        self.id == id && (!isProgress || !cancellationRequested)
    }
}

public struct ImportFailureState: Equatable, Sendable {
    public let operation: ImportOperationKind
    public let message: String

    public init(operation: ImportOperationKind, message: String) {
        self.operation = operation
        self.message = message
    }
}

public struct ImportWorkspaceSnapshot: Equatable, Sendable {
    public var phase: ImportUIPhase
    public var activeOperation: ImportOperationKind?
    public var failure: ImportFailureState?

    public init(
        phase: ImportUIPhase = .source,
        activeOperation: ImportOperationKind? = nil,
        failure: ImportFailureState? = nil
    ) {
        self.phase = phase
        self.activeOperation = activeOperation
        self.failure = failure
    }
}

public enum ImportWorkspaceEvent: Equatable, Sendable {
    case beginScan
    case scanSucceeded
    case beginPreparation(ImportOperationKind)
    case beginCopy
    case beginAuxiliaryOperation(ImportOperationKind)
    case endAuxiliaryOperation
    case completed
    case cancelled
    case failed(operation: ImportOperationKind, message: String)
    case recover(hasScannedJob: Bool)
    case recoverCompleted
}

public enum ImportWorkspaceTransition {
    public static func applying(
        _ event: ImportWorkspaceEvent,
        to snapshot: ImportWorkspaceSnapshot
    ) -> ImportWorkspaceSnapshot {
        switch event {
        case .beginScan:
            guard snapshot.activeOperation == nil else { return snapshot }
            return ImportWorkspaceSnapshot(phase: .scanning, activeOperation: .scan)
        case .scanSucceeded:
            guard snapshot.activeOperation == .scan
                    || snapshot.activeOperation == .portableReceiptOverride
            else { return snapshot }
            return ImportWorkspaceSnapshot(phase: .review)
        case .beginPreparation(let operation):
            guard
                snapshot.activeOperation == nil,
                snapshot.phase != .scanning,
                snapshot.phase != .preparing,
                snapshot.phase != .copying,
                operation == .prepareImport || operation == .portableReceiptOverride
            else { return snapshot }
            return ImportWorkspaceSnapshot(phase: .preparing, activeOperation: operation)
        case .beginCopy:
            guard
                snapshot.phase == .preparing || snapshot.phase == .copying,
                snapshot.activeOperation == .prepareImport || snapshot.activeOperation == .copy
            else { return snapshot }
            return ImportWorkspaceSnapshot(phase: .copying, activeOperation: .copy)
        case .beginAuxiliaryOperation(let operation):
            guard snapshot.activeOperation == nil, operation == .eject else { return snapshot }
            return ImportWorkspaceSnapshot(phase: snapshot.phase, activeOperation: operation)
        case .endAuxiliaryOperation:
            guard snapshot.activeOperation == .eject else { return snapshot }
            return ImportWorkspaceSnapshot(phase: snapshot.phase)
        case .completed:
            guard snapshot.activeOperation == .prepareImport || snapshot.activeOperation == .copy else {
                return snapshot
            }
            return ImportWorkspaceSnapshot(phase: .completed)
        case .cancelled:
            guard snapshot.activeOperation != nil else { return snapshot }
            return ImportWorkspaceSnapshot(phase: .cancelled)
        case .failed(let operation, let message):
            return ImportWorkspaceSnapshot(
                phase: .failed,
                failure: ImportFailureState(operation: operation, message: message)
            )
        case .recover(let hasScannedJob):
            return ImportWorkspaceSnapshot(phase: hasScannedJob ? .review : .source)
        case .recoverCompleted:
            return ImportWorkspaceSnapshot(phase: .completed)
        }
    }
}

public struct ImportDefaults: Equatable, Sendable {
    public var photosPath: String
    public var videosPath: String
    public var shootName: String
    public var workflowProfile: ImportWorkflowProfile
    public var mediaSelection: ImportMediaSelection
    public var destinationLayout: ImportDestinationLayout
    public var preferredMixedDestinationLayout: ImportDestinationLayout
    public var folderGrouping: ImportFolderGrouping

    public init(
        photosPath: String,
        videosPath: String,
        shootName: String,
        workflowProfile: ImportWorkflowProfile,
        mediaSelection: ImportMediaSelection,
        destinationLayout: ImportDestinationLayout,
        preferredMixedDestinationLayout: ImportDestinationLayout,
        folderGrouping: ImportFolderGrouping
    ) {
        self.photosPath = photosPath
        self.videosPath = videosPath
        self.shootName = shootName
        self.workflowProfile = workflowProfile
        self.mediaSelection = mediaSelection
        self.destinationLayout = destinationLayout
        self.preferredMixedDestinationLayout = preferredMixedDestinationLayout
        self.folderGrouping = folderGrouping
    }
}

public struct ImportDraft: Equatable, Sendable {
    public var sourcePath: String
    public var photosPath: String
    public var videosPath: String
    public var shootName: String
    public var workflowProfile: ImportWorkflowProfile
    public var mediaSelection: ImportMediaSelection
    public var destinationLayout: ImportDestinationLayout
    public var folderGrouping: ImportFolderGrouping
    public var sessions: [ImportPlanSession]

    public init(
        sourcePath: String,
        photosPath: String,
        videosPath: String,
        shootName: String,
        workflowProfile: ImportWorkflowProfile,
        mediaSelection: ImportMediaSelection,
        destinationLayout: ImportDestinationLayout,
        folderGrouping: ImportFolderGrouping,
        sessions: [ImportPlanSession] = []
    ) {
        self.sourcePath = sourcePath
        self.photosPath = photosPath
        self.videosPath = videosPath
        self.shootName = shootName
        self.workflowProfile = workflowProfile
        self.mediaSelection = mediaSelection
        self.destinationLayout = destinationLayout
        self.folderGrouping = folderGrouping
        self.sessions = sessions
    }
}
