import Testing

@testable import SDImportCore

@Suite("Import workspace transitions")
struct ImportWorkspaceTransitionTests {
    @Test("scan, review, import, and completion produce consistent snapshots")
    func happyPath() {
        var snapshot = ImportWorkspaceSnapshot()

        snapshot = ImportWorkspaceTransition.applying(.beginScan, to: snapshot)
        #expect(snapshot == ImportWorkspaceSnapshot(phase: .scanning, activeOperation: .scan))

        snapshot = ImportWorkspaceTransition.applying(.scanSucceeded, to: snapshot)
        #expect(snapshot == ImportWorkspaceSnapshot(phase: .review))

        snapshot = ImportWorkspaceTransition.applying(.beginPreparation(.prepareImport), to: snapshot)
        #expect(snapshot == ImportWorkspaceSnapshot(phase: .preparing, activeOperation: .prepareImport))

        snapshot = ImportWorkspaceTransition.applying(.beginCopy, to: snapshot)
        #expect(snapshot == ImportWorkspaceSnapshot(phase: .copying, activeOperation: .copy))

        snapshot = ImportWorkspaceTransition.applying(.completed, to: snapshot)
        #expect(snapshot == ImportWorkspaceSnapshot(phase: .completed))
    }

    @Test("callbacks and cancellation belong to the active attempt")
    func importAttemptOwnsCallbacks() {
        let previous = ImportWorkspaceAttempt(operation: .prepareImport)
        var current = ImportWorkspaceAttempt(operation: .prepareImport)
        #expect(!current.accepts(previous.id))
        #expect(!current.accepts(previous.id, isProgress: true))
        #expect(current.accepts(current.id, isProgress: true))

        current.requestCancellation()
        #expect(!current.accepts(current.id, isProgress: true))
        #expect(current.accepts(current.id))
        #expect(!current.accepts(previous.id))
    }

    @Test("failure records the operation and recovery selects the available workspace")
    func failureAndRecovery() {
        let failed = ImportWorkspaceTransition.applying(
            .failed(operation: .copy, message: "Disk disconnected"),
            to: ImportWorkspaceSnapshot(phase: .copying, activeOperation: .copy)
        )

        #expect(failed.phase == .failed)
        #expect(failed.activeOperation == nil)
        #expect(failed.failure == ImportFailureState(operation: .copy, message: "Disk disconnected"))
        #expect(
            ImportWorkspaceTransition.applying(.recover(hasScannedJob: true), to: failed)
                == ImportWorkspaceSnapshot(phase: .review)
        )
        #expect(
            ImportWorkspaceTransition.applying(.recover(hasScannedJob: false), to: failed)
                == ImportWorkspaceSnapshot(phase: .source)
        )
    }

    @Test("auxiliary operations preserve the visible phase")
    func auxiliaryOperationPreservesPhase() {
        let completed = ImportWorkspaceSnapshot(phase: .completed)
        let ejecting = ImportWorkspaceTransition.applying(
            .beginAuxiliaryOperation(.eject),
            to: completed
        )

        #expect(ejecting == ImportWorkspaceSnapshot(phase: .completed, activeOperation: .eject))
        #expect(
            ImportWorkspaceTransition.applying(.endAuxiliaryOperation, to: ejecting)
                == completed
        )
    }

    @Test("overlapping primary and auxiliary operations are rejected")
    func rejectsOverlappingOperations() {
        let ejecting = ImportWorkspaceSnapshot(phase: .review, activeOperation: .eject)
        #expect(ImportWorkspaceTransition.applying(.beginScan, to: ejecting) == ejecting)
        #expect(
            ImportWorkspaceTransition.applying(
                .beginPreparation(.prepareImport),
                to: ejecting
            ) == ejecting
        )

        let scanning = ImportWorkspaceSnapshot(phase: .scanning, activeOperation: .scan)
        #expect(
            ImportWorkspaceTransition.applying(
                .beginAuxiliaryOperation(.eject),
                to: scanning
            ) == scanning
        )
        #expect(ImportWorkspaceTransition.applying(.endAuxiliaryOperation, to: scanning) == scanning)
    }

    @Test("cancellation clears the active operation and invalid copy progress is ignored")
    func cancellationAndInvalidProgress() {
        let scanning = ImportWorkspaceSnapshot(phase: .scanning, activeOperation: .scan)
        #expect(
            ImportWorkspaceTransition.applying(.cancelled, to: scanning)
                == ImportWorkspaceSnapshot(phase: .cancelled)
        )

        let review = ImportWorkspaceSnapshot(phase: .review)
        #expect(ImportWorkspaceTransition.applying(.beginCopy, to: review) == review)
        #expect(ImportWorkspaceTransition.applying(.completed, to: review) == review)
    }

    @Test("a failed completion auxiliary operation can recover to the receipt")
    func restoresCompletionAfterAuxiliaryFailure() {
        let failed = ImportWorkspaceSnapshot(
            phase: .failed,
            failure: ImportFailureState(operation: .eject, message: "Busy")
        )
        let recovered = ImportWorkspaceTransition.applying(.recoverCompleted, to: failed)

        #expect(recovered == ImportWorkspaceSnapshot(phase: .completed))
        #expect(
            ImportWorkspaceTransition.applying(
                .beginAuxiliaryOperation(.eject),
                to: recovered
            ) == ImportWorkspaceSnapshot(phase: .completed, activeOperation: .eject)
        )
    }

    @Test("per-import draft changes do not mutate persisted defaults")
    func draftAndDefaultsAreIndependentValues() {
        let defaults = ImportDefaults(
            photosPath: "/Photos",
            videosPath: "/Videos",
            shootName: "Default",
            workflowProfile: .mixedShootSession,
            mediaSelection: .photosAndVideos,
            destinationLayout: .singleLibrary,
            preferredMixedDestinationLayout: .singleLibrary,
            folderGrouping: .byDay
        )
        var draft = ImportDraft(
            sourcePath: "/Volumes/CARD",
            photosPath: defaults.photosPath,
            videosPath: defaults.videosPath,
            shootName: defaults.shootName,
            workflowProfile: defaults.workflowProfile,
            mediaSelection: defaults.mediaSelection,
            destinationLayout: defaults.destinationLayout,
            folderGrouping: defaults.folderGrouping
        )

        draft.photosPath = "/One-Off"
        draft.shootName = "This Import"

        #expect(defaults.photosPath == "/Photos")
        #expect(defaults.shootName == "Default")
        #expect(draft.photosPath == "/One-Off")
    }
}
