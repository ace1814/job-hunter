import ShortlistCore
import SwiftUI
import UniformTypeIdentifiers

/// Import your LinkedIn connections and see where your network is.
struct NetworkView: View {
    @Environment(AppModel.self) private var model
    @State private var isPickingFile = false

    var body: some View {
        Group {
            if model.network.connectionCount == 0 {
                emptyState
            } else {
                summary
            }
        }
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem {
                Button {
                    isPickingFile = true
                } label: {
                    Label("Import Connections", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isImporting)
                .help("Import a LinkedIn Connections.csv")
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.importConnections(from: url) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Bring in your network", systemImage: "person.2")
        } description: {
            Text("""
                Import your LinkedIn connections and every job gets flagged when you know someone there.
                On LinkedIn: Settings → Data privacy → Get a copy of your data → Connections.
                """)
        } actions: {
            Button("Import Connections.csv…") { isPickingFile = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.isImporting)
            if let message = model.importMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        List {
            Section {
                HStack(spacing: 32) {
                    stat(model.network.connectionCount, "connections")
                    stat(model.network.companyCount, "companies")
                    stat(model.network.withoutCompanyCount, "with no company")
                }
                .padding(.vertical, 8)
                if let message = model.importMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if let date = model.network.lastImportedAt {
                    Text("Last imported \(date.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Where you know the most people") {
                ForEach(model.network.topCompanies) { company in
                    HStack {
                        Text(company.name)
                        Spacer()
                        Text("\(company.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}
