#if DEBUG
import SwiftUI
import UniformTypeIdentifiers
import Domain
import ASCClient
import Executor

/// DEBUG only (Task 2.12, K11): raw spike requests on the "Purser Spike" group through SpikeProbe (K10). The probe and its
/// write-capable client live while this window shows one workspace; closing the window drops them.
struct SpikeConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var probe: SpikeProbe?
    @State private var probeWorkspace: UUID?
    @State private var spikeId = "S2"
    @State private var step = "S2-1"
    @State private var method = "GET"
    @State private var path = ""
    @State private var query = ""
    @State private var requestBody = ""
    @State private var userVariables = ""
    @State private var createdIdVariable = ""
    @State private var allowed: [String] = []
    @State private var status = ""
    @State private var responseText = ""
    @State private var responseData = Data()
    @State private var importing = false
    @State private var exporting = false
    @State private var sending = false

    private static let methods = ["GET", "POST", "PATCH", "DELETE"]

    private var session: WorkspaceSession? {
        if case let .open(session) = model.phase { return session }
        return nil
    }

    var body: some View {
        Group {
            if let session {
                console(session)
            } else {
                ContentUnavailableView("Open the Juice workspace", systemImage: "lock",
                                       description: Text("The spike console works only on an open non-production workspace."))
            }
        }
        .frame(minWidth: 760, minHeight: 720)
        .onDisappear {
            probe = nil
            probeWorkspace = nil
        }
    }

    private func console(_ session: WorkspaceSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceBanner(config: session.config)
            HStack {
                TextField("Spike", text: $spikeId).frame(width: 80)
                TextField("Step", text: $step).frame(width: 120)
                Picker("Method", selection: $method) {
                    ForEach(Self.methods, id: \.self) { Text($0) }
                }
                .frame(width: 200)
            }
            TextField("Path, e.g. /v1/subscriptionPrices", text: $path).font(.body.monospaced())
            TextField("Query without ?, e.g. include=territory&limit=200", text: $query).font(.body.monospaced())
            HStack {
                Text("Body (JSON, sent only with POST and PATCH)").font(.headline)
                Spacer()
                Button("Load template…") { importing = true }
            }
            TextEditor(text: $requestBody).font(.caption.monospaced()).frame(minHeight: 120)
            Text("Variables (NAME=value, one per line; they override the catalog variables)").font(.headline)
            TextEditor(text: $userVariables).font(.caption.monospaced()).frame(minHeight: 60)
            HStack {
                TextField("Variable for the first created id", text: $createdIdVariable).frame(width: 280)
                Spacer()
                Text("Allowed ids: \(allowed.count)").foregroundStyle(.secondary)
                Button("Refresh list") { Task { await refreshAllowed(session) } }
                Button(method == "GET" ? "Send" : "Send (Touch ID)") { Task { await send(session) } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(sending || path.isEmpty)
            }
            DisclosureGroup("Allowed ids") {
                ScrollView {
                    Text(allowed.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Text(status).font(.headline).textSelection(.enabled)
                Spacer()
                Button("Save response…") { exporting = true }.disabled(responseData.isEmpty)
            }
            ScrollView {
                Text(responseText).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .task(id: session.config.id) { await refreshAllowed(session) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { requestBody = text } else { status = "The template cannot be read." }
        }
        .fileExporter(isPresented: $exporting, document: SpikeResponseDocument(data: responseData), contentType: .json,
                      defaultFilename: "\(step).json") { result in
            if case let .failure(error) = result { status = "Saving failed: \(error.localizedDescription)" }
        }
    }

    private func currentProbe(_ session: WorkspaceSession) throws -> SpikeProbe {
        if let probe, probeWorkspace == session.config.id { return probe }
        let created = try session.makeSpikeProbe()
        probe = created
        probeWorkspace = session.config.id
        return created
    }

    private func refreshAllowed(_ session: WorkspaceSession) async {
        do {
            allowed = try await currentProbe(session).allowedIds().sorted()
        } catch {
            allowed = []
            status = "The probe is not available: \(error)"
        }
    }

    private func send(_ session: WorkspaceSession) async {
        sending = true
        defer { sending = false }
        do {
            let today = CalendarDate.today(now: Date())
            let catalog = SpikeVariables.catalog(snapshot: try session.catalogStore.latestSnapshot(), config: session.config, today: today)
            let variables = catalog.merging(try SpikeVariables.parse(userVariables)) { _, user in user }
            let resolvedPath = try SpikeVariables.substitute(path.trimmingCharacters(in: .whitespaces), variables: variables, today: today)
            let resolvedQuery = try SpikeVariables.substitute(query.trimmingCharacters(in: .whitespaces), variables: variables, today: today)
            let trimmedBody = requestBody.trimmingCharacters(in: .whitespacesAndNewlines)
            var body: Data?
            if method == "POST" || method == "PATCH", !trimmedBody.isEmpty {
                body = Data(try SpikeVariables.substitute(trimmedBody, variables: variables, today: today).utf8)
            }
            let response = try await currentProbe(session).send(SpikeRequest(spikeId: spikeId, step: step, method: method,
                                                                             path: resolvedPath, query: resolvedQuery, body: body))
            status = "\(step): \(method) \(resolvedPath) → \(response.status)"
            responseData = response.body
            responseText = SpikeVariables.pretty(response.body)
            let name = createdIdVariable.trimmingCharacters(in: .whitespaces)
            if let first = response.createdIds.first, !name.isEmpty {
                userVariables += (userVariables.isEmpty || userVariables.hasSuffix("\n") ? "" : "\n") + "\(name)=\(first)"
                createdIdVariable = ""
            }
            await refreshAllowed(session)
        } catch {
            status = "\(step): not sent or failed: \(error)"
        }
    }
}

/// The raw response body handed to fileExporter ("Save response…"); redact it with Tools/redact-fixture.py before committing.
struct SpikeResponseDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
