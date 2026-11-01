import AppKit
import ShortlistCore
import SwiftUI

/// Everything that reaches beyond this window: the browser extension, web access, and what runs by
/// itself in the morning.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var tailoringModel = ""

    var body: some View {
        Form {
            extensionSection
            webSection
            morningSection
            Section("Tailoring") {
                TextField("Model", text: $tailoringModel)
                    .onSubmit { model.setTailoringModel(tailoringModel) }
            }
            if let message = model.connectMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .navigationTitle("Connect")
        .onAppear { tailoringModel = model.tailoringModel }
    }

    private var extensionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("1. In Chrome or Brave, open the Extensions page and turn on Developer mode.")
                Text("2. Choose Load unpacked and pick the Extension folder in this project.")
                Text("3. Click the extension's icon and paste your token.")
            }
            .font(.callout)
            HStack {
                Button("Show Extension Folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.extensionFolder)
                }
                Spacer()
                tokenButtons
            }
        } header: {
            Text("Browser extension")
        } footer: {
            Text("It fills in application forms from your prepared materials. You check them and press Submit yourself.")
        }
    }

    private var tokenButtons: some View {
        HStack {
            Button("Copy Token") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.serverToken, forType: .string)
            }
            .disabled(model.serverToken.isEmpty)
            Button("New Token") { Task { await model.resetServerToken() } }
                .help("Replaces the token, if you think it's been seen. You'll paste the new one again.")
        }
    }

    private var webSection: some View {
        Section {
            Toggle("Open Shortlist to my other devices", isOn: Binding {
                model.webAccess
            } set: { enabled in
                Task { await model.setWebAccess(enabled) }
            })
            if let address = model.webAddress {
                LabeledContent("Address") {
                    Text("http://\(address):\(String(AppAPI.port))").textSelection(.enabled)
                }
            }
        } header: {
            Text("Web access")
        } footer: {
            Text("Works over Tailscale, so only your own devices can reach it, and only while this Mac is awake. Sign in with the same token.")
        }
    }

    private var morningSection: some View {
        Section {
            Toggle("Refresh every morning", isOn: Binding {
                model.morningHour != nil
            } set: { enabled in
                model.setMorningHour(enabled ? 8 : nil)
            })
            if let hour = model.morningHour {
                Picker("Time", selection: Binding {
                    hour
                } set: {
                    model.setMorningHour($0)
                }) {
                    ForEach(5...11, id: \.self) { Text("\($0):00 AM").tag($0) }
                }
            }
            Toggle("Open Shortlist when I log in", isOn: Binding {
                model.launchesAtLogin
            } set: {
                model.setLaunchesAtLogin($0)
            })
        } header: {
            Text("Morning refresh")
        } footer: {
            Text("Fetches new jobs, scores up to \(JobScorer.defaultLimit) of them and fills today's list, once a day. It runs when Shortlist is open, so opening it at login makes it reliable.")
        }
    }

    private static var extensionFolder: String {
        // The app is built into the project folder, next to Extension.
        Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "Extension").path
    }
}
