import SwiftUI
import SimLeaseMenuCore

@main
struct SimLeaseMenuBarApp: App {
    @StateObject private var viewModel = MenuViewModel(provider: Self.makeProvider())
    @StateObject private var cleanupViewModel: CleanupViewModel
    @StateObject private var updateController: UpdateController
    @StateObject private var dashboardViewModel = DashboardViewModel(provider: Self.makeProvider())

    init() {
        let cleanup = CleanupViewModel(provider: Self.makeCleanupProvider())
        _cleanupViewModel = StateObject(wrappedValue: cleanup)
        _updateController = StateObject(wrappedValue: UpdateController { [weak cleanup] in
            switch cleanup?.state {
            case .loading?, .applying?: true
            default: false
            }
        })
    }

    var body: some Scene {
        MenuBarExtra {
            LeasePopoverView(
                viewModel: viewModel,
                updateStatus: updateController.status,
                canCheckForUpdates: updateController.isAvailable,
                onCheckForUpdates: updateController.checkForUpdates,
                onInstallUpdate: updateController.installReadyUpdate
            )
        } label: {
            let icon = MenuBarIconState(state: viewModel.state)
            Label {
                Text(icon.text)
            } icon: {
                Image(nsImage: MenuBarIcon.image(icon))
            }
            .labelStyle(.titleAndIcon)
            .task { await viewModel.monitor() }
        }
        .menuBarExtraStyle(.window)
        .windowResizability(.contentSize)

        Window("Simulator Cleanup", id: "cleanup") {
            CleanupReviewView(viewModel: cleanupViewModel)
        }
        .defaultSize(width: 560, height: 520)

        Window("SimLease Dashboard", id: "dashboard") {
            DashboardView(viewModel: dashboardViewModel)
        }
        .defaultSize(width: 900, height: 760)
    }

    private static func makeProvider() -> any MenuStatusProviding {
#if DEBUG
        if let state = ProcessInfo.processInfo.environment["SIMLEASE_PREVIEW_STATE"],
           let provider = PreviewStatusProvider(state: state) {
            return provider
        }
#endif
        return CLIStatusProvider()
    }

    private static func makeCleanupProvider() -> any MenuCleanupProviding {
#if DEBUG
        if let state = ProcessInfo.processInfo.environment[
            "SIMLEASE_CLEANUP_PREVIEW_STATE"
        ],
           let provider = PreviewCleanupProvider(state: state) {
            return provider
        }
#endif
        return CLICleanupProvider()
    }
}
