import AppKit
import ShortlistCore
import SwiftUI

/// Every open job from your sources, searchable, with scores.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: JobListItem.ID?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                ScoreBar()
                list
            }
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
        .navigationSubtitle("\(model.jobs.count) open")
        .searchable(text: $model.jobSearch, prompt: "Search titles, companies, descriptions")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $model.jobOrder) {
                    Text("Best Match").tag(JobOrder.bestMatch)
                    Text("Newest").tag(JobOrder.newest)
                }
                .pickerStyle(.segmented)
                .help("Change which jobs show and in what order")
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

    @ViewBuilder
    private var list: some View {
        if model.jobs.isEmpty {
            ContentUnavailableView {
                Label(model.jobSearch.isEmpty ? "No jobs yet" : "No matches", systemImage: "tray")
            } description: {
                Text(model.jobSearch.isEmpty ? "Add sources, then refresh." : "Try fewer words.")
            }
        } else {
            List(model.jobs, selection: $selection) { item in
                JobRow(item: item)
            }
        }
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

struct JobRow: View {
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

struct JobDetail: View {
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

                actions(for: item)
                if job.status.isWaiting || item.isPrepared {
                    ApplicationPanel(item: item)
                }
                LabelPicker(item: item)

                Divider()
                Text(job.descriptionText.isEmpty ? "No description in the feed. Open the posting to read it." : job.descriptionText)
                    .textSelection(.enabled)
                    .foregroundStyle(job.descriptionText.isEmpty ? .secondary : .primary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    /// Apply only opens the posting. You send the application yourself, then record it here.
    private func actions(for item: JobListItem) -> some View {
        HStack(spacing: 8) {
            Button {
                if let url = URL(string: item.job.applyURL ?? item.job.url) { openURL(url) }
            } label: {
                Label("Apply", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .help("Opens the posting in your browser")

            switch item.job.status {
            case .dismissed:
                Text("Passed").foregroundStyle(.secondary)
                Button("Undo") { model.restore(item) }
            case .applied, .interviewing, .rejected, .offer:
                Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if item.job.status == .applied {
                    Button("Undo") { model.undoApplied(item) }
                }
            default:
                Button("Mark Applied") { model.markApplied(item) }
                Button("Not for Me") { model.dismiss(item) }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// The tailored resume and answers for one job: making them, and getting at them.
private struct ApplicationPanel: View {
    @Environment(AppModel.self) private var model
    let item: JobListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.preparing.contains(item.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing your resume and answers…").font(.callout)
                }
            } else if item.isPrepared, let application = model.application(for: item) {
                HStack {
                    Label("Application ready", systemImage: "doc.text.fill").fontWeight(.medium)
                    Spacer()
                    if let path = application.resumePDFPath {
                        Button("Open Resume") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    Button("Redo") { Task { await model.prepare(item) } }
                        .help("Write them again with \(model.tailoringModel)")
                }
                ForEach(application.blurbs, id: \.question) { blurb in
                    DisclosureGroup(blurb.question) {
                        Text(blurb.answer).textSelection(.enabled).padding(.vertical, 4)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(blurb.answer, forType: .string)
                        }
                    }
                    .font(.callout)
                }
            } else {
                HStack {
                    Text("Make a resume and answers for this job.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Prepare Application") { Task { await model.prepare(item) } }
                        .help("Uses \(model.tailoringModel), about 2 cents a job or more")
                }
            }
            if let message = model.prepareMessage, !model.preparing.contains(item.id) {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
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
