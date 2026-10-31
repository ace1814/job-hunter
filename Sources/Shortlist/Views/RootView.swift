import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today, allJobs, network, profile, sources

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .allJobs: "All Jobs"
        case .network: "Network"
        case .profile: "Profile"
        case .sources: "Sources"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .allJobs: "tray.full"
        case .network: "person.2"
        case .profile: "person.text.rectangle"
        case .sources: "antenna.radiowaves.left.and.right"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .today

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    row(.today).badge(model.today.filter(\.job.status.isWaiting).count)
                    row(.allJobs)
                }
                Section("Setup") {
                    row(.network)
                    row(.profile)
                    row(.sources)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if let error = model.databaseError {
                ContentUnavailableView("Couldn't open the database", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(error))
            } else {
                detail(for: selection ?? .today)
            }
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol).tag(item)
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .network:
            NetworkView()
        case .today:
            TodayView { selection = $0 }
        case .allJobs:
            JobsView()
        case .profile:
            ProfileView()
        case .sources:
            SourcesView()
        }
    }
}
