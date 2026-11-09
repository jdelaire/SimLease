import AppKit
import Combine
import OSLog
import Sparkle
import SimLeaseCore

enum AppUpdateStatus: Equatable {
    case idle
    case available(String)
    case ready(String)
}

@MainActor
final class UpdateController: NSObject, ObservableObject {
    @Published private(set) var status: AppUpdateStatus = .idle
    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var idleTimer: Timer?
    private var requestObserver: NSObjectProtocol?
    private let isBusy: @MainActor () -> Bool

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        requestObserver = DistributedNotificationCenter.default().addObserver(
            forName: UpdateSignal.request,
            object: nil,
            queue: .main
        ) { notification in
            let token = notification.object as? String
            MainActor.assumeIsolated {
                UpdateController.handleRequest(token: token)
            }
        }
        UpdateController.current = self
    }

    private static weak var current: UpdateController?

    private static func handleRequest(token: String?) {
        guard let current, let token, UpdateSignal.isFresh(token) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            UpdateSignal.acknowledge,
            object: token,
            userInfo: nil,
            deliverImmediately: true
        )
        current.checkInBackground()
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func installReadyUpdate() {
        if let installNow {
            self.installNow = nil
            installNow()
        } else {
            checkForUpdates()
        }
    }

    private func checkInBackground() {
        if installNow != nil {
            installWhenIdle()
        } else if case .available = status {
            checkForUpdates()
        } else {
            controller?.updater.checkForUpdatesInBackground()
        }
    }

    private func installWhenIdle() {
        guard installNow != nil else {
            idleTimer?.invalidate()
            idleTimer = nil
            return
        }
        if canInstallSilently {
            idleTimer?.invalidate()
            idleTimer = nil
            installReadyUpdate()
        } else if idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated {
                    UpdateController.current?.installWhenIdle()
                }
            }
        }
    }

    private var canInstallSilently: Bool {
        if isBusy() || NSApplication.shared.isActive { return false }
        return !NSApplication.shared.windows.contains {
            keepsDockPresence(
                isVisible: $0.isVisible,
                isMiniaturized: $0.isMiniaturized,
                isTitled: $0.styleMask.contains(.titled)
            )
        }
    }

    fileprivate func updateReady(version: String, install: @escaping () -> Void) {
        installNow = install
        status = .ready(version)
        installWhenIdle()
    }

    fileprivate func updateAvailable(version: String) {
        if case .ready = status { return }
        status = .available(version)
    }

    fileprivate func sessionFinished() {
        if installNow == nil {
            status = .idle
        }
    }

    fileprivate func cycleFinished() {
        installNow = nil
        idleTimer?.invalidate()
        idleTimer = nil
        status = .idle
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            cycleFinished()
        }
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.domain != SUSparkleErrorDomain || nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        Logger(subsystem: "com.jdelaire.simlease", category: "update")
            .error("Update cycle failed: \(nsError.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code)]")
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = immediateInstallHandler
        MainActor.assumeIsolated {
            updateReady(version: version, install: install)
        }
        return true
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            updateAvailable(version: version)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            sessionFinished()
        }
    }
}

