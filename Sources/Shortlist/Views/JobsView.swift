import ShortlistCore
import SwiftUI

/// Every open job from your sources, searchable. The scored, daily view comes in Step 4.
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
        .navigationSubtitle("\(model.jobs.count) open")
        .searchable(text: $model.jobSearch, prompt: "Search titles, companies, descriptions")
        .toolbar {
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

private struct JobRow: View {
    let item: JobListItem

    var body: some View {
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

                Button {
                    if let url = URL(string: job.applyURL ?? job.url) { openURL(url) }
                } label: {
                    Label("Open Posting", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)

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
