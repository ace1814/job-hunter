import ShortlistCore
import SwiftUI

/// The daily screen: today's picks on the left, the chosen job on the right, and your count at the top.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    let navigate: (SidebarItem) -> Void
    @State private var selection: JobListItem.ID?

    private var toDo: [JobListItem] { model.today.filter(\.job.status.isWaiting) }
    private var done: [JobListItem] { model.today.filter { !$0.job.status.isWaiting } }

    var body: some View {
        Group {
            if isSetUp {
                dashboard
            } else {
                SetupChecklist(navigate: navigate)
            }
        }
        .navigationTitle("Today")
        .navigationSubtitle(Date.now.formatted(date: .complete, time: .omitted))
        .toolbar {
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
                .help("Fetch new jobs from your sources")
            }
        }
    }

    /// The checklist stays until there's something to work through.
    private var isSetUp: Bool {
        model.isReadyToScore || !model.today.isEmpty
    }

    private var dashboard: some View {
        HSplitView {
            VStack(spacing: 0) {
                DayProgress(log: model.todayLog, streak: model.stats.currentStreak)
                Divider()
                ScoreBar()
                list
            }
            .frame(minWidth: 320, idealWidth: 400)

            Group {
                if let item = model.today.first(where: { $0.id == selection }) {
                    JobDetail(item: item)
                } else {
                    ContentUnavailableView("Pick a job", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = toDo.first?.id } }
        .onChange(of: toDo.map(\.id)) { old, new in
            // Once a job is dealt with, move straight on to the next one.
            guard let current = selection, let position = old.firstIndex(of: current), !new.contains(current) else {
                if selection == nil { selection = new.first }
                return
            }
            selection = new.isEmpty ? nil : new[min(position, new.count - 1)]
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.today.isEmpty {
            ContentUnavailableView {
                Label("No picks yet", systemImage: "sun.max")
            } description: {
                Text(model.pendingScores > 0
                     ? "Score your jobs to fill today's list."
                     : "No job scored \(DailyQueue.minimumScore) or above. Fetch new jobs, or widen your target roles in Profile.")
            }
        } else {
            List(selection: $selection) {
                if !toDo.isEmpty {
                    Section("To do") {
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

/// Your count toward the day's target, one pip per application.
private struct DayProgress: View {
    let log: DailyLog
    let streak: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(log.submittedCount)").font(.system(size: 30, weight: .semibold).monospacedDigit())
                Text("of \(log.target) applications").foregroundStyle(.secondary)
                Spacer()
                if streak > 0 {
                    Label("\(streak) day streak", systemImage: "flame.fill").foregroundStyle(.orange)
                }
                if log.submittedCount >= log.target {
                    Label("Done for today", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<log.target, id: \.self) { index in
                    Capsule()
                        .fill(index < log.submittedCount ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                        .frame(height: 6)
                }
            }
        }
        .padding(12)
    }
}

/// What's left before the first scores, each step with its way forward right there.
private struct SetupChecklist: View {
    @Environment(AppModel.self) private var model
    let navigate: (SidebarItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let's get you set up").font(.title2.weight(.semibold))
                    Text("Three steps, then your top 15 appear here.").foregroundStyle(.secondary)
                }
                step(1, "Add job sources", isDone: !model.sources.isEmpty) {
                    Button("Open Sources") { navigate(.sources) }
                }
                if model.scoring.provider == .openAI {
                    step(2, "Add your OpenAI key", isDone: model.hasOpenAIKey) {
                        OpenAIKeyField()
                    }
                }
                step(3, "Add your resume and target roles", isDone: model.profile.isScoreable) {
                    Button("Open Profile") { navigate(.profile) }
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ number: Int, _ title: String, isDone: Bool, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if !isDone || number == 2 { action() }
            }
        }
    }
}
