import ShortlistCore
import SwiftUI

/// Where jobs come from: company boards, remote-job feeds, and boards to find through your network.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false
    @State private var keywords = ""

    var body: some View {
        Form {
            Section {
                TextField("Title keywords", text: $keywords, prompt: Text("product design, ux, product manager"), axis: .vertical)
                    .lineLimit(1...3)
                    .onSubmit { model.setTitleKeywords(keywords) }
                HStack {
                    Text("Only jobs with one of these in the title are kept, separated by commas. It's the first cut, before anything is scored.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { model.setTitleKeywords(keywords) }
                        .disabled(keywords == model.titleKeywords.joined(separator: ", "))
                }
            } header: {
                Text("Title keywords")
            }

            Section {
                if model.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No sources yet. Start with feeds that suit a senior product designer or PM, or paste a company's careers page.")
                            .foregroundStyle(.secondary)
                        Button("Add Recommended Feeds") { Task { await model.addRecommended() } }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(model.sources) { item in
                    SourceRow(item: item)
                }
            } header: {
                HStack {
                    Text("Your sources")
                    Spacer()
                    if let message = model.refreshMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }

            if !model.leads.isEmpty {
                Section {
                    ForEach(model.leads) { lead in
                        LeadRow(lead: lead)
                    }
                } header: {
                    Text("Companies you know people at")
                } footer: {
                    Text("Shortlist checks Greenhouse, Lever, Ashby and SmartRecruiters for a public board under the company's name.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
                .help("Add a careers page or feed")

                Button {
                    Task { await model.refreshAll(force: true) }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing || model.sources.isEmpty)
                .help("Fetch every enabled source now")
            }
        }
        .sheet(isPresented: $isAdding) { AddSourceSheet() }
        .onAppear { keywords = model.titleKeywords.joined(separator: ", ") }
        .onChange(of: model.titleKeywords) { _, new in keywords = new.joined(separator: ", ") }
    }
}

private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let item: SourceListItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.name)
                Text(details).font(.callout).foregroundStyle(.secondary)
                if let error = item.source.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { item.source.isEnabled },
                set: { model.setEnabled($0, for: item.source) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .contextMenu {
            Button("Fetch Now") { Task { await model.refresh(item.source) } }
            Divider()
            Button("Remove Source", role: .destructive) { model.remove(item.source) }
        }
    }

    private var details: String {
        var parts = [item.source.kind.displayName]
        if item.source.kind.isCompanyBoard, let board = item.source.boardID { parts.append(board) }
        parts.append("\(item.openJobs) open")
        if let fetched = item.source.lastFetchedAt {
            parts.append("checked \(fetched.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("not fetched yet")
        }
        return parts.joined(separator: " · ")
    }
}

private struct LeadRow: View {
    @Environment(AppModel.self) private var model
    let lead: NetworkLead

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lead.company.name)
                Text("\(lead.company.count) connection\(lead.company.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            switch model.boardSearches[lead.id] {
            case nil:
                Button("Find Job Board") { Task { await model.findBoards(for: lead) } }
            case .searching:
                ProgressView().controlSize(.small)
            case .found(let boards) where boards.isEmpty:
                Text("No public board found").font(.callout).foregroundStyle(.secondary)
            case .found(let boards):
                HStack {
                    ForEach(boards) { board in
                        Button("Watch \(board.kind.displayName) (\(board.openJobs))") {
                            Task { await model.watch(board, for: lead) }
                        }
                    }
                }
            }
        }
    }
}

private struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var detected: Source? { SourceLocator.source(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a source").font(.title2.weight(.semibold))
            Text("Paste a company's careers page on Greenhouse, Lever, Ashby or SmartRecruiters, or the address of an RSS feed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://jobs.lever.co/company", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Group {
                if let detected {
                    Label("\(detected.kind.displayName): \(detected.boardID ?? detected.url ?? detected.name)", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if !text.isEmpty {
                    Label("That doesn't look like a careers page or feed URL.", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Divider()
            HStack {
                Button("Add Recommended Feeds") {
                    Task { await model.addRecommended() }
                    dismiss()
                }
                .help("Himalayas, We Work Remotely, Remote OK, Remotive and HN Who is hiring")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(detected == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() {
        guard let detected else { return }
        Task { await model.add(detected) }
        dismiss()
    }
}
