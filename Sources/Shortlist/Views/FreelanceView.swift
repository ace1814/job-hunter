import ShortlistCore
import SwiftUI

/// Freelance and contract work: today's top picks, or everything, on the left, and the chosen post
/// on the right. It stays apart from Today, so proposals don't count toward your daily target.
struct FreelanceView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: JobListItem.ID?
    @State private var showsAll = false

    private var items: [JobListItem] { showsAll ? model.freelanceJobs : model.freelancePicks }
    private var toDo: [JobListItem] { items.filter(\.job.status.isWaiting) }
    private var done: [JobListItem] { items.filter { !$0.job.status.isWaiting } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(model.stats.proposals)").font(.system(size: 30, weight: .semibold).monospacedDigit())
                    Text("proposal\(model.stats.proposals == 1 ? "" : "s") sent").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                Divider()
                ScoreBar()
                list
            }
            .frame(minWidth: 320, idealWidth: 400)

            Group {
                if let item = items.first(where: { $0.id == selection }) {
                    JobDetail(item: item)
                } else {
                    ContentUnavailableView("Pick a post", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Freelance")
        .navigationSubtitle(showsAll ? "\(items.count) open" : "Top \(DailyQueue.freelanceSize) for today")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $showsAll) {
                    Text("Top Picks").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Today's top picks, or all open freelance work")
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Fetch Jobs", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
                    }
                }
                .disabled(model.isRefreshing)
                .help("Fetch new work from your sources. Reddit adds about a minute per subreddit.")
            }
        }
        .onAppear { if selection == nil { selection = toDo.first?.id } }
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label(showsAll ? "No freelance work yet" : "No picks yet", systemImage: "briefcase")
            } description: {
                Text(model.pendingScores > 0
                     ? "Score your jobs to fill this list."
                     : "No post scored \(DailyQueue.minimumScore) or above. Good freelance work is rarer than jobs, so check back tomorrow.")
            }
        } else {
            List(selection: $selection) {
                if !toDo.isEmpty {
                    Section(showsAll ? "Open" : "To do") {
                        ForEach(toDo) { JobRow(item: $0) }
                    }
                }
                if !done.isEmpty {
                    Section("Done") {
                        ForEach(done) { JobRow(item: $0).opacity(0.6) }
                    }
                }
            }
        }
    }
}
