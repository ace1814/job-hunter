import ShortlistCore
import SwiftUI

/// Every open job from your sources, searchable, with scores and today's picks. The full daily
/// view comes in Step 4.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: JobListItem.ID?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            list
                .frame(minWidth: 300, idealWidth: 380)
            Group {
                if let item = model.jobs.first(where: { $0.id == selection }) {
                    JobDetail(item: item)
                } else {
                    ContentUnavailableView("No job selected", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("All Jobs")
        .navigationSubtitle(subtitle)
        .searchable(text: $model.jobSearch, prompt: "Search titles, companies, descriptions")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $model.jobOrder) {
                    Text("Best Match").tag(JobOrder.bestMatch)
                    Text("Newest").tag(JobOrder.newest)
                    Text("Today (\(model.todayCount))").tag(JobOrder.today)
                }
                .pickerStyle(.segmented)
                .help("Change which jobs show and in what order")
            }
            ToolbarItem {
                scoreButton
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .help("Fetch new jobs from your sources")
            }
        }
    }

    private var subtitle: String {
        if let progress = model.scoringProgress {
            return progress.total == 0 ? "Scoring…" : "Scoring \(progress.done) of \(progress.total)"
        }
        return model.scoringMessage ?? "\(model.jobs.count) open · \(model.pendingScores) to score"
    }

    @ViewBuilder
    private var scoreButton: some View {
        if model.isScoring {
            Button {
                model.stopScoring()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .help("Stop scoring. Finished jobs keep their scores.")
        } else {
            Button {
                model.scoreJobs()
            } label: {
                Label("Score", systemImage: "sparkles")
            }
            .disabled(model.pendingScores == 0)
            .help("Score up to \(JobScorer.defaultLimit) waiting jobs with \(model.scoring.modelName)")
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.jobs.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "tray")
            } description: {
                Text(emptyHint)
            }
        } else {
            List(model.jobs, selection: $selection) { item in
                JobRow(item: item)
            }
        }
    }

    private var emptyTitle: String {
        if !model.jobSearch.isEmpty { return "No matches" }
        return model.jobOrder == .today ? "No picks yet" : "No jobs yet"
    }

    private var emptyHint: String {
        if !model.jobSearch.isEmpty { return "Try fewer words." }
        return model.jobOrder == .today ? "Score your jobs to fill today's list." : "Add sources, then refresh."
    }
}

/// A score, colored by how strong it is.
private struct ScoreBadge: View {
    let score: Int

    private var tint: Color {
        switch score {
        case 75...: .green
        case 50..<75: .orange
        default: .secondary
        }
    }

    var body: some View {
        Text("\(score)")
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(tint)
            .frame(minWidth: 30)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: 6))
    }
}

private struct JobRow: View {
    let item: JobListItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let score = item.score {
                ScoreBadge(score: score.score)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.job.title).fontWeight(.medium).lineLimit(2)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if item.job.remotePolicy != .unknown {
                        Tag(text: item.job.remotePolicy.label)
                    }
                    if item.referralCount > 0 {
                        Tag(text: "\(item.referralCount) you know", symbol: "person.2.fill", tint: .green)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        [item.job.companyName, item.job.location].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct JobDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: JobListItem

    var body: some View {
        let job = item.job
        let referrals = model.referrals(for: job)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(job.companyName).font(.title3).foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if !job.location.isEmpty { fact("Location", job.location) }
                    if job.remotePolicy != .unknown { fact("Work", job.remotePolicy.label) }
                    if let salary = job.salaryText { fact("Pay", salary) }
                    if let posted = job.postedAt { fact("Posted", posted.formatted(date: .abbreviated, time: .omitted)) }
                    fact("Source", item.sourceName ?? item.sourceKind?.displayName ?? "—")
                }
                .font(.callout)

                if let score = item.score {
                    ScoreSummary(score: score)
                }

                if !referrals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("You know people here", systemImage: "person.2.fill").font(.headline).foregroundStyle(.green)
                        ForEach(referrals, id: \.connection.id) { flag in
                            HStack(spacing: 6) {
                                Text(flag.connection.fullName).fontWeight(.medium)
                                Text(flag.connection.position).foregroundStyle(.secondary).lineLimit(1)
                                if flag.jobReferral.confidence == .possible {
                                    Tag(text: "maybe: \(flag.connection.company)")
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.08), in: .rect(cornerRadius: 8))
                }

                HStack(spacing: 14) {
                    Button {
                        if let url = URL(string: job.applyURL ?? job.url) { openURL(url) }
                    } label: {
                        Label("Open Posting", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)

                    LabelPicker(item: item)
                }

                Divider()
                Text(job.descriptionText.isEmpty ? "No description in the feed. Open the posting to read it." : job.descriptionText)
                    .textSelection(.enabled)
                    .foregroundStyle(job.descriptionText.isEmpty ? .secondary : .primary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// What the model made of the job.
private struct ScoreSummary: View {
    let score: JobScore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ScoreBadge(score: score.score)
                Text(score.rationale).fontWeight(.medium).textSelection(.enabled)
            }
            ForEach(score.strengths, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            ForEach(score.gaps, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            if score.dealbreakerHit {
                Label("Matches one of your dealbreakers", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var footnote: String {
        guard let parts = score.criteria else { return score.model }
        return "Role \(parts.role)/4 · Experience \(parts.experience)/4 · Level \(parts.seniority)/4 · "
            + "Location \(parts.location)/4 · Must-haves \(parts.mustHaves)/4 · \(score.model)"
    }
}

/// Your own call on a job. These labels are what the model check measures against.
private struct LabelPicker: View {
    @Environment(AppModel.self) private var model
    let item: JobListItem

    var body: some View {
        HStack(spacing: 6) {
            Text("Would you apply?").font(.callout).foregroundStyle(.secondary)
            ForEach(JobLabelValue.allCases, id: \.self) { label in
                Button(label.rawValue.capitalized) { model.setLabel(label, for: item) }
                    .buttonStyle(.bordered)
                    .tint(item.label == label ? .accentColor : nil)
            }
        }
    }
}

private struct Tag: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

extension RemotePolicy {
    var label: String {
        switch self {
        case .remote: "Remote"
        case .hybrid: "Hybrid"
        case .onsite: "On-site"
        case .unknown: "Unknown"
        }
    }
}
