import SwiftUI
import SimLeaseMenuCore

@main
struct SimLeaseMenuBarApp: App {
    @StateObject private var viewModel = MenuViewModel(provider: Self.makeProvider())
    @StateObject private var cleanupViewModel = CleanupViewModel(
        provider: Self.makeCleanupProvider()
    )

    var body: some Scene {
        MenuBarExtra {
            LeasePopoverView(viewModel: viewModel)
        } label: {
            Label(viewModel.state.menuTitle, systemImage: viewModel.state.symbolName)
        }
        .menuBarExtraStyle(.window)
        .windowResizability(.contentSize)

        Window("Simulator Cleanup", id: "cleanup") {
            CleanupReviewView(viewModel: cleanupViewModel)
        }
        .defaultSize(width: 560, height: 520)
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
