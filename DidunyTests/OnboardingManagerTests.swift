@testable import Diduny
import XCTest

final class OnboardingManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_confirmedEmailLeadsToSharedPlansBeforeCaptureSetup() {
        XCTAssertEqual(OnboardingScreen.signIn.next, .plans)
        XCTAssertEqual(OnboardingScreen.plans.next, .capturePanel)
    }

    func test_legacyStepRawValuesRemainStable() {
        XCTAssertEqual(OnboardingStep.welcome.rawValue, 0)
        XCTAssertEqual(OnboardingStep.microphonePermission.rawValue, 1)
        XCTAssertEqual(OnboardingStep.accessibilityPermission.rawValue, 2)
        XCTAssertEqual(OnboardingStep.screenRecordingPermission.rawValue, 3)
        XCTAssertEqual(OnboardingStep.shortcutSetup.rawValue, 4)
        XCTAssertEqual(OnboardingStep.apiSetup.rawValue, 5)
        XCTAssertEqual(OnboardingStep.complete.rawValue, 6)
        XCTAssertEqual(OnboardingStep(rawValue: 5), .apiSetup)
    }

    func test_prepareForLaunchAppliesDefaultsOnlyForFreshInstall() {
        var applyCount = 0
        let manager = OnboardingManager(defaults: defaults) { applyCount += 1 }

        XCTAssertTrue(manager.prepareForLaunch())
        XCTAssertEqual(applyCount, 1)
        XCTAssertNotNil(defaults.object(forKey: "onboarding.firstLaunchTimestamp"))
        XCTAssertFalse(manager.hasCompletedOnboarding)

        XCTAssertFalse(manager.prepareForLaunch())
        XCTAssertEqual(applyCount, 1)
    }

    func test_prepareForLaunchPreservesExistingOnboardingStateAndRawStep() {
        defaults.set(123.0, forKey: "onboarding.firstLaunchTimestamp")
        defaults.set(OnboardingStep.apiSetup.rawValue, forKey: "onboarding.currentStep")
        var applyCount = 0
        let manager = OnboardingManager(defaults: defaults) { applyCount += 1 }

        XCTAssertFalse(manager.prepareForLaunch())
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(manager.currentStep, .apiSetup)
        XCTAssertEqual(defaults.integer(forKey: "onboarding.currentStep"), 5)
    }

    func test_existingInstallEvidenceNeverReceivesFreshDefaults() {
        var applyCount = 0
        let manager = OnboardingManager(defaults: defaults) { applyCount += 1 }

        XCTAssertFalse(manager.prepareForLaunch(hasExistingInstallState: true))
        XCTAssertEqual(applyCount, 0)
        XCTAssertNotNil(defaults.object(forKey: "onboarding.firstLaunchTimestamp"))
        XCTAssertFalse(manager.hasCompletedOnboarding)
    }

    func test_hidingSetupGuideIsSessionOnlyAndNeverCompletesOnboarding() {
        let manager = OnboardingManager(defaults: defaults) {}
        _ = manager.prepareForLaunch()

        XCTAssertTrue(manager.shouldShowSetupGuide)

        manager.hideSetupGuideForSession()

        XCTAssertFalse(manager.shouldShowSetupGuide)
        XCTAssertFalse(manager.hasCompletedOnboarding)
        XCTAssertNil(defaults.object(forKey: "onboarding.completed"))

        manager.showSetupGuide()

        XCTAssertTrue(manager.shouldShowSetupGuide)
        XCTAssertFalse(manager.hasCompletedOnboarding)
    }

    func test_incompleteSetupPresentsStandaloneWindowUntilDeferredOrCompleted() {
        let manager = OnboardingManager(defaults: defaults) {}

        XCTAssertTrue(manager.shouldPresentOnboardingWindow)

        manager.hideSetupGuideForSession()
        XCTAssertFalse(manager.shouldPresentOnboardingWindow)

        manager.showFromSettings()
        XCTAssertTrue(manager.shouldPresentOnboardingWindow)

        manager.hasCompletedOnboarding = true
        manager.hideSetupGuideForSession()
        XCTAssertFalse(manager.shouldPresentOnboardingWindow)
    }

    func test_hidingIncompleteSetupDoesNotRevealUpdateHighlights() {
        let manager = OnboardingManager(defaults: defaults) {}
        _ = manager.prepareForLaunch()

        manager.hideSetupGuideForSession()

        XCTAssertFalse(manager.shouldShowSetupGuide)
        XCTAssertFalse(manager.canShowUpdateHighlights)
        XCTAssertFalse(manager.hasCompletedOnboarding)
    }

    func test_completedUserCanOpenAndHideSetupGuideFromSettingsForCurrentSession() {
        let manager = OnboardingManager(defaults: defaults) {}
        manager.hasCompletedOnboarding = true

        XCTAssertFalse(manager.shouldShowSetupGuide)

        manager.showFromSettings()

        XCTAssertTrue(manager.shouldShowSetupGuide)
        XCTAssertTrue(manager.hasCompletedOnboarding)

        manager.hideSetupGuideForSession()

        XCTAssertFalse(manager.shouldShowSetupGuide)
        XCTAssertTrue(manager.hasCompletedOnboarding)
    }

    func test_practiceRequiresSignInAndAllOnboardingPermissions() {
        let manager = OnboardingManager(defaults: defaults) {}

        XCTAssertFalse(manager.canStartPractice(
            isAuthenticated: false,
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true
        ))
        XCTAssertFalse(manager.canStartPractice(
            isAuthenticated: true,
            microphoneGranted: false,
            accessibilityGranted: true,
            screenRecordingGranted: true
        ))
        XCTAssertFalse(manager.canStartPractice(
            isAuthenticated: true,
            microphoneGranted: true,
            accessibilityGranted: false,
            screenRecordingGranted: true
        ))
        XCTAssertFalse(manager.canStartPractice(
            isAuthenticated: true,
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false
        ))
        XCTAssertTrue(manager.canStartPractice(
            isAuthenticated: true,
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true
        ))
    }

    func test_incompleteAuthenticatedSetupUsesCloudWithoutChangingConfiguredProvider() {
        let manager = OnboardingManager(defaults: defaults) {}
        let configuredProvider = TranscriptionProvider.local

        XCTAssertEqual(
            manager.dictationProvider(
                configuredProvider: configuredProvider,
                isAuthenticated: true
            ),
            .cloud
        )
        XCTAssertEqual(configuredProvider, .local)

        manager.hasCompletedOnboarding = true

        XCTAssertEqual(
            manager.dictationProvider(
                configuredProvider: configuredProvider,
                isAuthenticated: true
            ),
            .local
        )
    }

    func test_onlySavedNonemptyAuthenticatedCloudDictationCompletesSetup() {
        let manager = OnboardingManager(defaults: defaults) {}

        XCTAssertFalse(
            manager.didSaveSuccessfulDictation(
                recordingID: nil,
                text: "Unsaved result",
                provider: .cloud,
                isAuthenticated: true,
                requiredPermissionsGranted: true
            )
        )
        XCTAssertFalse(
            manager.didSaveSuccessfulDictation(
                recordingID: UUID(),
                text: "",
                provider: .cloud,
                isAuthenticated: true,
                requiredPermissionsGranted: true
            )
        )
        XCTAssertFalse(
            manager.didSaveSuccessfulDictation(
                recordingID: UUID(),
                text: "Local result",
                provider: .local,
                isAuthenticated: true,
                requiredPermissionsGranted: true
            )
        )
        XCTAssertFalse(
            manager.didSaveSuccessfulDictation(
                recordingID: UUID(),
                text: "Unsigned result",
                provider: .cloud,
                isAuthenticated: false,
                requiredPermissionsGranted: true
            )
        )
        XCTAssertFalse(
            manager.didSaveSuccessfulDictation(
                recordingID: UUID(),
                text: "Missing permissions",
                provider: .cloud,
                isAuthenticated: true,
                requiredPermissionsGranted: false
            )
        )
        XCTAssertTrue(
            manager.didSaveSuccessfulDictation(
                recordingID: UUID(),
                text: "First cloud dictation",
                provider: .cloud,
                isAuthenticated: true,
                requiredPermissionsGranted: true
            )
        )
        XCTAssertTrue(manager.hasCompletedOnboarding)
        XCTAssertEqual(defaults.integer(forKey: "onboarding.version"), 1)
        XCTAssertEqual(defaults.integer(forKey: "onboarding.currentStep"), 6)
    }

    func test_practiceShowsReadyOnlyAfterConfirmedSetupCompletion() {
        let manager = OnboardingManager(defaults: defaults) {}

        XCTAssertFalse(manager.shouldShowReadyAfterPractice(recordingState: .success))

        manager.hasCompletedOnboarding = true

        XCTAssertFalse(manager.shouldShowReadyAfterPractice(recordingState: .processing))
        XCTAssertTrue(manager.shouldShowReadyAfterPractice(recordingState: .success))
    }

    func test_successfulSavedDictationKeepsSuccessGuideVisibleUntilDone() {
        let manager = OnboardingManager(defaults: defaults) {}
        _ = manager.prepareForLaunch()

        XCTAssertTrue(
            manager.didSaveSuccessfulDictation(
                recordingID: UUID(),
                text: "First cloud dictation",
                provider: .cloud,
                isAuthenticated: true,
                requiredPermissionsGranted: true
            )
        )

        XCTAssertTrue(manager.hasCompletedOnboarding)
        XCTAssertTrue(manager.shouldShowSetupGuide)
        XCTAssertFalse(manager.canShowUpdateHighlights)

        manager.hideSetupGuideForSession()

        XCTAssertFalse(manager.shouldShowSetupGuide)
        XCTAssertTrue(manager.canShowUpdateHighlights)
    }

    func test_voicePipelineRejectsCleanedEmptyTextAndMissingRequiredSave() throws {
        XCTAssertThrowsError(try requireNonemptyVoiceDictation(" \n ")) { error in
            guard case .emptyTranscription = error as? TranscriptionError else {
                return XCTFail("Expected empty transcription, got \(error)")
            }
        }
        XCTAssertEqual(try requireNonemptyVoiceDictation("First dictation"), "First dictation")

        XCTAssertThrowsError(
            try requireSavedSetupRecording(nil, required: true, recoveryPreserved: true)
        ) { error in
            XCTAssertTrue(error is VoiceDictationPersistenceError)
        }
        XCTAssertNoThrow(
            try requireSavedSetupRecording(nil, required: false, recoveryPreserved: false)
        )
        XCTAssertNoThrow(
            try requireSavedSetupRecording(UUID(), required: true, recoveryPreserved: false)
        )
    }

    func test_failedRequiredSetupSaveKeepsRecoverableAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = RecoveryStateManager(
            fileURL: directory.appendingPathComponent("recovery_state.json")
        )
        let audio = Data("setup audio".utf8)

        XCTAssertTrue(
            preserveVoiceRecovery(audioData: audio, startTime: Date(), manager: manager)
        )
        XCTAssertThrowsError(
            try requireSavedSetupRecording(nil, required: true, recoveryPreserved: true)
        )

        let recovery = try XCTUnwrap(manager.hasOrphanedRecording())
        XCTAssertTrue(recovery.fileExists)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: recovery.state.tempFilePath)),
            audio
        )
    }
}
