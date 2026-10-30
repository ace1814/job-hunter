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
    @State private var selection: SidebarItem? = .network

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    row(.today)
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
            ComingSoon(item: item, step: "Step 4",
                       blurb: "Your top 15 matches for the day, with the job, the AI's reasoning and who you know there, side by side. Plus your progress toward 10 applications.")
        case .allJobs:
            ComingSoon(item: item, step: "Step 2", blurb: "Every job pulled from your sources, searchable, with its score and status.")
        case .profile:
            ComingSoon(item: item, step: "Step 3", blurb: "Your master profile and resume: what jobs are scored against and what tailoring starts from.")
        case .sources:
            ComingSoon(item: item, step: "Step 2", blurb: "Company job boards you watch, remote-job APIs and RSS feeds.")
        }
    }
}

private struct ComingSoon: View {
    let item: SidebarItem
    let step: String
    let blurb: String

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.symbol)
        } description: {
            Text(blurb)
        } actions: {
            Text("Coming in \(step)").font(.callout).foregroundStyle(.secondary)
        }
        .navigationTitle(item.title)
    }
}
