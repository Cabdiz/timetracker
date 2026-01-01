import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Models

struct Client: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var hourlyRate: Double

    init(id: UUID = UUID(), name: String, hourlyRate: Double) {
        self.id = id
        self.name = name
        self.hourlyRate = hourlyRate
    }
}

struct WorkEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let clientId: UUID
    var startDate: Date
    var endDate: Date
    var hourlyRate: Double
    var note: String?

    // Invoice link (prevents double billing)
    var invoiceId: UUID? = nil
    var invoicedAt: Date? = nil

    // Edit audit
    var editedAt: Date? = nil
    var editCount: Int = 0

    init(
        id: UUID = UUID(),
        clientId: UUID,
        startDate: Date,
        endDate: Date,
        hourlyRate: Double,
        note: String? = nil,
        invoiceId: UUID? = nil,
        invoicedAt: Date? = nil,
        editedAt: Date? = nil,
        editCount: Int = 0
    ) {
        self.id = id
        self.clientId = clientId
        self.startDate = startDate
        self.endDate = endDate
        self.hourlyRate = hourlyRate
        self.note = note
        self.invoiceId = invoiceId
        self.invoicedAt = invoicedAt
        self.editedAt = editedAt
        self.editCount = editCount
    }

    var seconds: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
    var minutes: Int { max(0, Int(seconds / 60.0)) }
    var hoursExact: Double { seconds / 3600.0 }
}

struct ActiveSession {
    var client: Client
    var startDate: Date
}

struct InvoiceLineItem: Identifiable, Codable, Equatable {
    let id: UUID
    let entryId: UUID
    let startDate: Date
    let endDate: Date
    let billedMinutes: Int
    let rate: Double
    let amount: Double
    let note: String?

    init(entry: WorkEntry, billedMinutes: Int) {
        self.id = UUID()
        self.entryId = entry.id
        self.startDate = entry.startDate
        self.endDate = entry.endDate
        self.billedMinutes = billedMinutes
        self.rate = entry.hourlyRate
        let billedHours = Double(billedMinutes) / 60.0
        self.amount = billedHours * entry.hourlyRate
        self.note = entry.note
    }

    var billedHours: Double { Double(billedMinutes) / 60.0 }
}

struct Invoice: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case draft, paid } // paid == finalized

    let id: UUID
    var number: String
    var clientId: UUID
    var createdAt: Date
    var status: Status

    // Draft references entries live
    var entryIds: [UUID]

    // Snapshot once paid/finalized
    var paidAt: Date? = nil
    var frozenLineItems: [InvoiceLineItem]? = nil
    var frozenTotalHours: Double? = nil
    var frozenTotalAmount: Double? = nil

    init(
        id: UUID = UUID(),
        number: String,
        clientId: UUID,
        createdAt: Date = Date(),
        status: Status = .draft,
        entryIds: [UUID]
    ) {
        self.id = id
        self.number = number
        self.clientId = clientId
        self.createdAt = createdAt
        self.status = status
        self.entryIds = entryIds
    }
}

// MARK: - Store

final class AppStore: ObservableObject {
    private let clientsKey = "clients_v6"
    private let entriesKey = "work_entries_v6"
    private let invoicesKey = "invoices_v3"
    private let settingsKey = "settings_v3"

    struct Settings: Codable, Equatable {
        // Invoice rounding increment in minutes, rounding DOWN (favor employer)
        var roundingIncrementMinutes: Int = 6
    }

    @Published var clients: [Client] = []
    @Published var entries: [WorkEntry] = []
    @Published var invoices: [Invoice] = []
    @Published var settings: Settings = Settings()

    init() {
        loadClients()
        loadEntries()
        loadInvoices()
        loadSettings()

        if clients.isEmpty {
            clients = [
                Client(name: "Client A", hourlyRate: 50),
                Client(name: "Client B", hourlyRate: 75)
            ]
            saveClients()
        }
    }

    // MARK: Clients

    func addClient(name: String, rate: Double) {
        clients.append(Client(name: name, hourlyRate: rate))
        saveClients()
    }

    func deleteClients(at offsets: IndexSet) {
        clients.remove(atOffsets: offsets)
        saveClients()
    }

    func saveClients() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(clients), forKey: clientsKey) }
        catch { print("Failed to encode clients:", error) }
    }

    private func loadClients() {
        guard let data = UserDefaults.standard.data(forKey: clientsKey) else { clients = []; return }
        do { clients = try JSONDecoder().decode([Client].self, from: data) }
        catch { clients = []; print("Failed to decode clients:", error) }
    }

    func clientName(for id: UUID) -> String {
        clients.first(where: { $0.id == id })?.name ?? "Unknown Client"
    }

    func client(for id: UUID) -> Client? {
        clients.first(where: { $0.id == id })
    }

    func findClientByName(_ name: String) -> Client? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clients.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
    }

    /// If client doesn't exist, create it. If it exists, keep existing rate (do NOT overwrite).
    func getOrCreateClient(named name: String, defaultRate: Double) -> Client {
        if let c = findClientByName(name) { return c }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = Client(name: trimmed.isEmpty ? "Imported Client" : trimmed, hourlyRate: defaultRate)
        clients.append(new)
        saveClients()
        return new
    }

    // MARK: Entries

    func addEntry(_ entry: WorkEntry) {
        entries.append(entry)
        saveEntries()
    }

    func updateEntry(_ updated: WorkEntry) {
        if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
            entries[idx] = updated
            saveEntries()
        }
    }

    func deleteEntries(withIDs ids: [UUID]) {
        entries.removeAll { ids.contains($0.id) }
        saveEntries()
    }

    func saveEntries() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: entriesKey) }
        catch { print("Failed to encode entries:", error) }
    }

    private func loadEntries() {
        guard let data = UserDefaults.standard.data(forKey: entriesKey) else { entries = []; return }
        do { entries = try JSONDecoder().decode([WorkEntry].self, from: data) }
        catch { entries = []; print("Failed to decode entries:", error) }
    }

    // MARK: Invoices

    func saveInvoices() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(invoices), forKey: invoicesKey) }
        catch { print("Failed to encode invoices:", error) }
    }

    private func loadInvoices() {
        guard let data = UserDefaults.standard.data(forKey: invoicesKey) else { invoices = []; return }
        do { invoices = try JSONDecoder().decode([Invoice].self, from: data) }
        catch { invoices = []; print("Failed to decode invoices:", error) }
    }

    func invoice(forId id: UUID?) -> Invoice? {
        guard let id else { return nil }
        return invoices.first(where: { $0.id == id })
    }

    func isEntryPaid(_ entry: WorkEntry) -> Bool {
        guard let inv = invoice(forId: entry.invoiceId) else { return false }
        return inv.status == .paid
    }

    func isEntryInvoiced(_ entry: WorkEntry) -> Bool {
        entry.invoiceId != nil
    }

    func draftInvoice(for clientId: UUID) -> Invoice? {
        invoices.first(where: { $0.clientId == clientId && $0.status == .draft })
    }

    func nextInvoiceNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let existing = invoices.filter { $0.number.hasPrefix("\(year)-") }.count
        return String(format: "%d-%04d", year, existing + 1)
    }

    /// Invoice rounding: rounds billed minutes DOWN to increment (favor employer).
    func billedMinutes(for entry: WorkEntry) -> Int {
        let inc = max(1, settings.roundingIncrementMinutes)
        let m = max(0, entry.minutes)
        return (m / inc) * inc
    }

    /// Live line items for a draft invoice (computed from current entries).
    func liveLineItems(for invoice: Invoice) -> [InvoiceLineItem] {
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return invoice.entryIds.compactMap { id in
            guard let e = byId[id] else { return nil }
            return InvoiceLineItem(entry: e, billedMinutes: billedMinutes(for: e))
        }
        .sorted(by: { $0.startDate < $1.startDate })
    }

    func liveTotals(for invoice: Invoice) -> (hours: Double, amount: Double) {
        let items = liveLineItems(for: invoice)
        let h = items.reduce(0.0) { $0 + $1.billedHours }
        let a = items.reduce(0.0) { $0 + $1.amount }
        return (h, a)
    }

    /// A single function to get totals for either draft or paid (paid uses frozen snapshot).
    func totalsForInvoice(_ invoice: Invoice) -> (hours: Double, amount: Double) {
        if invoice.status == .paid,
           let h = invoice.frozenTotalHours,
           let a = invoice.frozenTotalAmount {
            return (h, a)
        }
        return liveTotals(for: invoice)
    }

    // Draft-review helpers
    func draftInvoiceNeedsReview(_ invoice: Invoice) -> Bool {
        guard invoice.status == .draft else { return false }
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        for entryId in invoice.entryIds {
            guard let e = byId[entryId] else { continue }
            if let invoicedAt = e.invoicedAt,
               let editedAt = e.editedAt,
               editedAt > invoicedAt {
                return true
            }
        }
        return false
    }

    func entryNeedsReviewForDraftInvoice(_ entry: WorkEntry) -> Bool {
        guard let inv = invoice(forId: entry.invoiceId), inv.status == .draft else { return false }
        guard let invoicedAt = entry.invoicedAt, let editedAt = entry.editedAt else { return false }
        return editedAt > invoicedAt
    }

    /// Create or update a draft invoice from selected entries.
    /// Prevents double billing: only entries with invoiceId == nil can be added.
    func createOrAddToDraftInvoice(clientId: UUID, entryIds: [UUID]) throws -> Invoice {
        let selected = entries.filter { entryIds.contains($0.id) }
        if selected.isEmpty { throw NSError(domain: "No entries", code: 1) }
        if selected.contains(where: { $0.clientId != clientId }) { throw NSError(domain: "Mixed clients", code: 2) }
        if selected.contains(where: { $0.invoiceId != nil }) { throw NSError(domain: "Already invoiced", code: 3) }

        let inv: Invoice
        if var existing = draftInvoice(for: clientId) {
            let set = Set(existing.entryIds).union(entryIds)
            existing.entryIds = Array(set)
            if let idx = invoices.firstIndex(where: { $0.id == existing.id }) {
                invoices[idx] = existing
            }
            inv = existing
        } else {
            let new = Invoice(number: nextInvoiceNumber(), clientId: clientId, entryIds: entryIds)
            invoices.append(new)
            inv = new
        }

        for id in entryIds {
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].invoiceId = inv.id
                entries[idx].invoicedAt = Date()
            }
        }

        saveEntries()
        saveInvoices()
        return inv
    }

    /// Mark draft invoice as paid/finalized: snapshot + lock.
    func markInvoicePaid(_ invoiceId: UUID) {
        guard let idx = invoices.firstIndex(where: { $0.id == invoiceId }) else { return }
        var inv = invoices[idx]
        guard inv.status == .draft else { return }

        let items = liveLineItems(for: inv)
        let totals = liveTotals(for: inv)

        inv.status = .paid
        inv.paidAt = Date()
        inv.frozenLineItems = items
        inv.frozenTotalHours = totals.hours
        inv.frozenTotalAmount = totals.amount

        invoices[idx] = inv
        saveInvoices()
    }

    // MARK: Import CSV (entries)

    struct ImportResult {
        var importedEntries: Int
        var skippedAsDuplicate: Int
        var createdClients: Int
    }

    /// Imports entries from CSV exported by this app.
    /// - Does NOT import invoice links/status (fresh entries only).
    /// - Skips duplicates by matching (clientId + start + end + rate + note).
    func importEntriesCSV(_ csvText: String) -> ImportResult {
        // Very simple CSV parser for our own exported format.
        // It supports quoted fields with commas only in a minimal way (double quotes).
        let rows = CSV.parse(csvText)
        guard !rows.isEmpty else { return ImportResult(importedEntries: 0, skippedAsDuplicate: 0, createdClients: 0) }

        // Find header indices we care about
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func idx(_ name: String) -> Int? { header.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }

        guard
            let iClient = idx("Client"),
            let iStartDate = idx("Start Date"),
            let iStartTime = idx("Start Time"),
            let iEndDate = idx("End Date"),
            let iEndTime = idx("End Time"),
            let iRate = idx("Rate")
        else {
            // Not our expected format
            return ImportResult(importedEntries: 0, skippedAsDuplicate: 0, createdClients: 0)
        }

        let iNote = idx("Note")

        let dtf = DateFormatter()
        dtf.locale = Locale(identifier: "en_US_POSIX")
        dtf.dateFormat = "yyyy-MM-dd HH:mm"

        var imported = 0
        var skipped = 0
        var createdClients = 0

        for r in rows.dropFirst() {
            if r.count <= max(iEndTime, iRate) { continue }
            let clientName = r[iClient].trimmingCharacters(in: .whitespacesAndNewlines)
            if clientName.isEmpty { continue }

            let startStamp = "\(r[iStartDate]) \(r[iStartTime])"
            let endStamp = "\(r[iEndDate]) \(r[iEndTime])"

            guard let start = dtf.date(from: startStamp),
                  let end = dtf.date(from: endStamp) else { continue }

            let rate = Double(r[iRate].replacingOccurrences(of: ",", with: ".")) ?? 0
            let note = (iNote != nil && iNote! < r.count) ? r[iNote!] : ""
            let noteNorm = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let noteOpt: String? = noteNorm.isEmpty ? nil : noteNorm

            let existed = findClientByName(clientName) != nil
            let client = getOrCreateClient(named: clientName, defaultRate: rate)
            if !existed { createdClients += 1 }

            // Duplicate check
            let isDup = entries.contains(where: { e in
                e.clientId == client.id &&
                abs(e.startDate.timeIntervalSince(start)) < 1 &&
                abs(e.endDate.timeIntervalSince(end)) < 1 &&
                abs(e.hourlyRate - rate) < 0.0001 &&
                (e.note ?? "") == (noteOpt ?? "")
            })

            if isDup {
                skipped += 1
                continue
            }

            let entry = WorkEntry(
                clientId: client.id,
                startDate: start,
                endDate: end,
                hourlyRate: rate,
                note: noteOpt,
                invoiceId: nil,
                invoicedAt: nil,
                editedAt: nil,
                editCount: 0
            )

            entries.append(entry)
            imported += 1
        }

        if imported > 0 { saveEntries() }
        // clients already saved via getOrCreateClient
        return ImportResult(importedEntries: imported, skippedAsDuplicate: skipped, createdClients: createdClients)
    }

    // MARK: Settings

    func saveSettings() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: settingsKey) }
        catch { print("Failed to encode settings:", error) }
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else { settings = Settings(); return }
        do { settings = try JSONDecoder().decode(Settings.self, from: data) }
        catch { settings = Settings(); print("Failed to decode settings:", error) }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = AppStore()

    var body: some View {
        TabView {
            ClientsView()
                .environmentObject(store)
                .tabItem { Label("Clients", systemImage: "person.3") }

            HistoryView()
                .environmentObject(store)
                .tabItem { Label("History", systemImage: "clock") }

            InvoicesView()
                .environmentObject(store)
                .tabItem { Label("Invoices", systemImage: "doc.text") }
        }
    }
}

// MARK: - Clients

struct ClientsView: View {
    @EnvironmentObject var store: AppStore

    @State private var selectedClient: Client? = nil
    @State private var showingActions = false

    @State private var activeSession: ActiveSession? = nil
    @State private var showingActiveSheet = false

    @State private var showingClockInAtSheet = false
    @State private var clockInAtDate = Date()

    @State private var showingClientDetails = false
    @State private var showingAddClient = false
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(store.clients) { client in
                        Button {
                            selectedClient = client
                            showingActions = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(client.name).font(.headline)
                                    Text(String(format: "$%.2f/hr", client.hourlyRate))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if activeSession?.client.id == client.id {
                                    Text("Active").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete(perform: store.deleteClients)
                }

                Section(header: Text("Invoice rounding (favor employer)")) {
                    Text("Invoices bill time rounded down to the nearest \(store.settings.roundingIncrementMinutes) minutes.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("Change rounding…") { showingSettings = true }
                }
            }
            .navigationTitle("Clients")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAddClient = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
            }
            .confirmationDialog(
                selectedClient?.name ?? "Client",
                isPresented: $showingActions,
                titleVisibility: .visible
            ) {
                Button("Clock in now") { startSession(with: Date()) }

                Button("Clock in at…") {
                    clockInAtDate = Date()
                    showingClockInAtSheet = true
                }

                if let selected = selectedClient,
                   activeSession?.client.id == selected.id {
                    Button("Undo clock in", role: .destructive) {
                        activeSession = nil
                        showingActiveSheet = false
                    }
                }

                Button("View client details") { showingClientDetails = true }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $showingActiveSheet) {
                if let session = activeSession {
                    ActiveSessionView(
                        session: session,
                        onClockOutNow: { clockOut(endDate: Date()) },
                        onClockOutAt: { clockOut(endDate: $0) }
                    )
                } else {
                    Text("No active session").padding()
                }
            }
            .sheet(isPresented: $showingClockInAtSheet) {
                ClockInAtView(
                    clientName: selectedClient?.name ?? "Client",
                    selectedDate: $clockInAtDate,
                    onCancel: { showingClockInAtSheet = false },
                    onConfirm: {
                        showingClockInAtSheet = false
                        startSession(with: clockInAtDate)
                    }
                )
            }
            .sheet(isPresented: $showingClientDetails) {
                if let client = selectedClient {
                    ClientDetailsAndHistoryView(client: client)
                        .environmentObject(store)
                } else {
                    Text("No client selected").padding()
                }
            }
            .sheet(isPresented: $showingAddClient) {
                AddClientView { name, rate in
                    store.addClient(name: name, rate: rate)
                    showingAddClient = false
                } onCancel: { showingAddClient = false }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(store)
            }
        }
    }

    private func startSession(with startDate: Date) {
        guard let c = selectedClient else { return }
        activeSession = ActiveSession(client: c, startDate: startDate)
        showingActiveSheet = true
    }

    private func clockOut(endDate: Date) {
        guard let session = activeSession else { return }
        let entry = WorkEntry(
            clientId: session.client.id,
            startDate: session.startDate,
            endDate: endDate,
            hourlyRate: session.client.hourlyRate
        )
        store.addEntry(entry)
        activeSession = nil
        showingActiveSheet = false
    }
}

// MARK: - Client details + history

struct ClientDetailsAndHistoryView: View {
    @EnvironmentObject var store: AppStore
    let client: Client
    @Environment(\.dismiss) private var dismiss

    @State private var editingEntry: WorkEntry? = nil
    @State private var showLockedAlert = false

    var clientEntries: [WorkEntry] {
        store.entries
            .filter { $0.clientId == client.id }
            .sorted(by: { $0.startDate > $1.startDate })
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Client")) {
                    Text(client.name).font(.headline)
                    Text(String(format: "$%.2f/hr", client.hourlyRate))
                        .foregroundColor(.secondary)
                }

                Section(header: Text("All entries")) {
                    ForEach(clientEntries) { e in
                        let paid = store.isEntryPaid(e)
                        let invoiced = store.isEntryInvoiced(e)
                        let needsReview = store.entryNeedsReviewForDraftInvoice(e)

                        Button {
                            if paid { showLockedAlert = true }
                            else { editingEntry = e }
                        } label: {
                            EntryRow(
                                entry: e,
                                clientName: store.clientName(for: e.clientId),
                                isSelected: false,
                                status: paid ? .paid : (invoiced ? .invoiced : .none),
                                needsReview: needsReview
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Client Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert("Locked entry", isPresented: $showLockedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("This entry is locked because its invoice has been paid/finalized.")
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditView(
                    clientName: store.clientName(for: entry.clientId),
                    entry: entry,
                    isLocked: store.isEntryPaid(entry),
                    onCancel: { editingEntry = nil },
                    onSave: { updated in
                        store.updateEntry(updated)
                        editingEntry = nil
                    }
                )
            }
        }
    }
}

// MARK: - History (export all + import)

struct HistoryView: View {
    @EnvironmentObject var store: AppStore

    @State private var selectedClientId: UUID? = nil
    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var endDate: Date = Date()

    @State private var selectedEntryIds: Set<UUID> = []
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false

    @State private var editingEntry: WorkEntry? = nil
    @State private var editMode = false

    @State private var showError = false
    @State private var errorMessage = ""

    // Import
    @State private var showingImporter = false
    @State private var importSummary: String? = nil
    @State private var showImportSummary = false

    var filteredEntries: [WorkEntry] {
        store.entries
            .filter { e in
                let clientOK = (selectedClientId == nil) || (e.clientId == selectedClientId)
                let rangeOK = e.startDate >= startDate && e.startDate <= endDate
                return clientOK && rangeOK
            }
            .sorted(by: { $0.startDate > $1.startDate })
    }

    var selectedEntries: [WorkEntry] {
        filteredEntries.filter { selectedEntryIds.contains($0.id) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Form {
                    Section(header: Text("Filter")) {
                        Picker("Client", selection: Binding(
                            get: { selectedClientId },
                            set: { selectedClientId = $0; selectedEntryIds.removeAll() }
                        )) {
                            Text("All Clients").tag(UUID?.none)
                            ForEach(store.clients) { c in
                                Text(c.name).tag(UUID?.some(c.id))
                            }
                        }

                        DatePicker("From", selection: $startDate, displayedComponents: [.date])
                        DatePicker("To", selection: $endDate, displayedComponents: [.date])
                    }

                    Section(header: Text("Mode")) {
                        Toggle("Tap to edit entries", isOn: $editMode)
                        Text(editMode ? "Tap an entry to edit it." : "Tap entries to select them for invoice/export.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                List {
                    ForEach(filteredEntries) { e in
                        let paid = store.isEntryPaid(e)
                        let invoiced = store.isEntryInvoiced(e)
                        let needsReview = store.entryNeedsReviewForDraftInvoice(e)

                        EntryRow(
                            entry: e,
                            clientName: store.clientName(for: e.clientId),
                            isSelected: selectedEntryIds.contains(e.id),
                            status: paid ? .paid : (invoiced ? .invoiced : .none),
                            needsReview: needsReview
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if editMode {
                                if paid {
                                    errorMessage = "This entry is locked because its invoice has been paid/finalized."
                                    showError = true
                                } else {
                                    editingEntry = e
                                }
                            } else {
                                toggleSelection(e.id)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { filteredEntries[$0].id }
                        let locked = store.entries.filter { ids.contains($0.id) && store.isEntryPaid($0) }
                        if !locked.isEmpty {
                            errorMessage = "One or more entries are locked (paid invoice) and cannot be deleted."
                            showError = true
                            return
                        }
                        store.deleteEntries(withIDs: ids)
                        selectedEntryIds.subtract(ids)
                    }

                    if filteredEntries.isEmpty {
                        Text("No entries in this range yet.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Import CSV") { showingImporter = true }

                    Button("Draft Invoice") { createDraftInvoiceFromSelection() }
                        .disabled(selectedEntries.isEmpty)

                    Menu("Export") {
                        Button("Export selected (or filtered if none selected)") {
                            let list = selectedEntries.isEmpty ? filteredEntries : selectedEntries
                            exportEntriesCSV(entries: list, filename: "time_entries_filtered_or_selected.csv")
                        }
                        Button("Export ALL entries") {
                            exportEntriesCSV(entries: store.entries.sorted(by: { $0.startDate < $1.startDate }),
                                            filename: "time_entries_ALL.csv")
                        }
                    }
                    .disabled(store.entries.isEmpty)
                }
            }
            .alert("Action blocked", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage) }
            .sheet(isPresented: $showingShare) {
                ShareSheet(activityItems: shareURLs)
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditView(
                    clientName: store.clientName(for: entry.clientId),
                    entry: entry,
                    isLocked: store.isEntryPaid(entry),
                    onCancel: { editingEntry = nil },
                    onSave: { updated in
                        store.updateEntry(updated)
                        editingEntry = nil
                    }
                )
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .failure(let err):
                    errorMessage = "Import failed: \(err.localizedDescription)"
                    showError = true
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importCSV(from: url)
                }
            }
            .alert("Import complete", isPresented: $showImportSummary) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importSummary ?? "")
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedEntryIds.contains(id) { selectedEntryIds.remove(id) }
        else { selectedEntryIds.insert(id) }
    }

    private func createDraftInvoiceFromSelection() {
        let selected = selectedEntries
        guard let first = selected.first else { return }
        let clientId = first.clientId

        if selected.contains(where: { $0.clientId != clientId }) {
            errorMessage = "Please select entries for only one client at a time."
            showError = true
            return
        }

        if selected.contains(where: { $0.invoiceId != nil }) {
            errorMessage = "One or more selected entries are already invoiced (double-billing prevention)."
            showError = true
            return
        }

        do {
            _ = try store.createOrAddToDraftInvoice(clientId: clientId, entryIds: selected.map { $0.id })
            selectedEntryIds.removeAll()
        } catch {
            errorMessage = "Could not create invoice."
            showError = true
        }
    }

    // MARK: Export CSV

    private func exportEntriesCSV(entries: [WorkEntry], filename: String) {
        let csv = makeEntriesCSV(entries: entries)
        if let url = writeTempFile(filename: filename, contents: csv) {
            shareURLs = [url]
            showingShare = true
        }
    }

    private func makeEntriesCSV(entries: [WorkEntry]) -> String {
        let dfDate = DateFormatter(); dfDate.dateFormat = "yyyy-MM-dd"
        let dfTime = DateFormatter(); dfTime.dateFormat = "HH:mm"

        func esc(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }

        var rows: [String] = []
        rows.append("Client,Start Date,Start Time,End Date,End Time,Seconds,Hours Exact,Rate,Note,Invoice Status,Needs Review")

        for e in entries.sorted(by: { $0.startDate < $1.startDate }) {
            let client = store.clientName(for: e.clientId)
            let sd = dfDate.string(from: e.startDate)
            let st = dfTime.string(from: e.startDate)
            let ed = dfDate.string(from: e.endDate)
            let et = dfTime.string(from: e.endDate)

            let status: String = store.isEntryPaid(e) ? "Paid" : (store.isEntryInvoiced(e) ? "Invoiced (Draft)" : "Not invoiced")
            let needsReview = store.entryNeedsReviewForDraftInvoice(e) ? "YES" : "NO"

            rows.append("\(esc(client)),\(sd),\(st),\(ed),\(et),\(Int(e.seconds)),\(String(format: "%.4f", e.hoursExact)),\(String(format: "%.2f", e.hourlyRate)),\(esc(e.note ?? "")),\(esc(status)),\(needsReview)")
        }

        return rows.joined(separator: "\n")
    }

    private func writeTempFile(filename: String, contents: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try contents.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            print("Failed writing file:", error)
            return nil
        }
    }

    // MARK: Import CSV

    private func importCSV(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                errorMessage = "Could not read the file as text."
                showError = true
                return
            }
            let res = store.importEntriesCSV(text)
            importSummary = """
            Imported entries: \(res.importedEntries)
            Skipped duplicates: \(res.skippedAsDuplicate)
            New clients created: \(res.createdClients)
            """
            showImportSummary = true
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            showError = true
        }
    }
}

// MARK: - Invoices

struct InvoicesView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedInvoice: Invoice? = nil

    var draftInvoices: [Invoice] {
        store.invoices.filter { $0.status == .draft }
            .sorted(by: { $0.createdAt > $1.createdAt })
    }

    var paidInvoices: [Invoice] {
        store.invoices.filter { $0.status == .paid }
            .sorted(by: { ($0.paidAt ?? $0.createdAt) > ($1.paidAt ?? $1.createdAt) })
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Draft")) {
                    if draftInvoices.isEmpty {
                        Text("No draft invoices yet.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(draftInvoices) { inv in
                        Button { selectedInvoice = inv } label: { InvoiceRow(invoice: inv) }
                    }
                }

                Section(header: Text("Paid / Finalized")) {
                    if paidInvoices.isEmpty {
                        Text("No paid invoices yet.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(paidInvoices) { inv in
                        Button { selectedInvoice = inv } label: { InvoiceRow(invoice: inv) }
                    }
                }
            }
            .navigationTitle("Invoices")
            .sheet(item: $selectedInvoice) { inv in
                InvoiceDetailView(invoiceId: inv.id)
                    .environmentObject(store)
            }
        }
    }
}

struct InvoiceRow: View {
    @EnvironmentObject var store: AppStore
    let invoice: Invoice

    var body: some View {
        let client = store.clientName(for: invoice.clientId)
        let status = invoice.status == .draft ? "Draft" : "Paid"
        let needsReview = store.draftInvoiceNeedsReview(invoice)
        let totals = store.totalsForInvoice(invoice)

        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Invoice \(invoice.number)").font(.headline)
                Text(client).foregroundColor(.secondary)

                // ✅ Hours + total $ on the list row
                Text(String(format: "Hours: %.2f • Total: $%.2f", totals.hours, totals.amount))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(status)
                    .font(.caption)
                    .foregroundColor(invoice.status == .paid ? .red : .orange)

                if needsReview {
                    Text("REVIEW")
                        .font(.caption2)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(Color.yellow.opacity(0.25))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct InvoiceDetailView: View {
    @EnvironmentObject var store: AppStore
    let invoiceId: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var shareURLs: [URL] = []
    @State private var showingShare = false

    @State private var showError = false
    @State private var errorMessage = ""

    var invoice: Invoice? {
        store.invoices.first(where: { $0.id == invoiceId })
    }

    var body: some View {
        NavigationView {
            if let inv = invoice {
                let clientName = store.clientName(for: inv.clientId)
                let needsReview = (inv.status == .draft) && store.draftInvoiceNeedsReview(inv)

                let lineItems: [InvoiceLineItem] = {
                    if inv.status == .paid, let frozen = inv.frozenLineItems { return frozen }
                    return store.liveLineItems(for: inv)
                }()

                let totals = store.totalsForInvoice(inv)

                List {
                    Section(header: Text("Invoice")) {
                        Text("Number: \(inv.number)")
                        Text("Client: \(clientName)")
                        Text("Status: \(inv.status == .draft ? "Draft" : "Paid / Finalized")")

                        // ✅ Also show totals in the invoice header
                        Text(String(format: "Total billed hours: %.2f", totals.hours))
                        Text(String(format: "Total amount: $%.2f", totals.amount))

                        if needsReview {
                            Text("⚠️ Draft changed after invoicing — review before marking paid.")
                                .foregroundColor(.orange)
                        }

                        if inv.status == .paid, let paidAt = inv.paidAt {
                            Text("Paid at: \(paidAt.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundColor(.secondary)
                        }

                        Text("Rounding: \(store.settings.roundingIncrementMinutes) min down")
                            .foregroundColor(.secondary)
                    }

                    Section(header: Text("Line items")) {
                        ForEach(lineItems) { li in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(li.startDate.formatted(date: .abbreviated, time: .shortened)) → \(li.endDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.subheadline)
                                Text(String(format: "Billed: %.2f hrs (from %d min) • Rate: $%.2f • Amount: $%.2f",
                                            li.billedHours, li.billedMinutes, li.rate, li.amount))
                                    .foregroundColor(.secondary)
                                    .font(.footnote)
                                if let note = li.note, !note.isEmpty {
                                    Text("Note: \(note)").font(.footnote)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .navigationTitle("Invoice \(inv.number)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        if inv.status == .draft {
                            Button("Mark Paid") { store.markInvoicePaid(inv.id) }
                        }
                        Button("Export PDF") {
                            exportInvoicePDF(inv: inv, lineItems: lineItems, totals: totals, clientName: clientName)
                        }
                    }
                }
                .sheet(isPresented: $showingShare) { ShareSheet(activityItems: shareURLs) }
                .alert("Export failed", isPresented: $showError) {
                    Button("OK", role: .cancel) { }
                } message: { Text(errorMessage) }
            } else {
                Text("Invoice not found").padding()
            }
        }
    }

    private func exportInvoicePDF(inv: Invoice, lineItems: [InvoiceLineItem], totals: (hours: Double, amount: Double), clientName: String) {
        let pdfData = InvoicePDFRenderer.render(
            invoiceNumber: inv.number,
            clientName: clientName,
            status: inv.status == .draft ? "DRAFT" : "PAID / FINALIZED",
            createdAt: inv.createdAt,
            paidAt: inv.paidAt,
            roundingMinutes: store.settings.roundingIncrementMinutes,
            lineItems: lineItems,
            totalHours: totals.hours,
            totalAmount: totals.amount
        )

        let filename = "invoice_\(inv.number).pdf"
        if let url = writeTempFile(filename: filename, data: pdfData) {
            shareURLs = [url]
            showingShare = true
        } else {
            errorMessage = "Could not write PDF."
            showError = true
        }
    }

    private func writeTempFile(filename: String, data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("Write failed:", error)
            return nil
        }
    }
}

// MARK: - Entry row

struct EntryRow: View {
    enum Status { case none, invoiced, paid }

    let entry: WorkEntry
    let clientName: String
    let isSelected: Bool
    let status: Status
    let needsReview: Bool

    var body: some View {
        let mainColor: Color = (status == .paid) ? .red : .primary
        let badgeText: String? = {
            switch status {
            case .none: return nil
            case .invoiced: return "INVOICED"
            case .paid: return "PAID"
            }
        }()

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(clientName)
                    .font(.headline)
                    .foregroundColor(mainColor)

                Text("\(entry.startDate.formatted(date: .abbreviated, time: .shortened)) → \(entry.endDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(String(format: "Exact: %d sec (%.4f hrs) • Rate: $%.2f",
                            Int(entry.seconds), entry.hoursExact, entry.hourlyRate))
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if let editedAt = entry.editedAt {
                    Text("Edited \(entry.editCount)x • \(editedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let badgeText {
                    Text(badgeText)
                        .font(.caption2)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background((status == .paid) ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                        .foregroundColor((status == .paid) ? .red : .orange)
                        .clipShape(Capsule())
                }

                if needsReview {
                    Text("REVIEW")
                        .font(.caption2)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(Color.yellow.opacity(0.25))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Entry edit

struct EntryEditView: View {
    let clientName: String
    @State var entry: WorkEntry
    let isLocked: Bool

    let onCancel: () -> Void
    let onSave: (WorkEntry) -> Void

    @State private var showEndBeforeStartAlert = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Client")) { Text(clientName) }

                Section(header: Text("Times")) {
                    DatePicker("Start", selection: $entry.startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $entry.endDate, displayedComponents: [.date, .hourAndMinute])
                }

                Section(header: Text("Rate")) {
                    TextField("Hourly rate", value: $entry.hourlyRate, format: .number)
                        .keyboardType(.decimalPad)
                }

                Section(header: Text("Note")) {
                    TextField("Optional note", text: Binding(
                        get: { entry.note ?? "" },
                        set: { entry.note = $0.isEmpty ? nil : $0 }
                    ))
                }

                if entry.invoiceId != nil {
                    Section {
                        Text("This entry is on a draft invoice. Editing updates draft totals automatically.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isLocked { return }
                        if entry.endDate < entry.startDate {
                            showEndBeforeStartAlert = true
                            return
                        }
                        entry.editCount += 1
                        entry.editedAt = Date()
                        onSave(entry)
                    }
                    .disabled(isLocked)
                }
            }
            .alert("End time can’t be before start time.", isPresented: $showEndBeforeStartAlert) {
                Button("OK", role: .cancel) { }
            }
        }
    }
}

// MARK: - Clock in/out views

struct ClockInAtView: View {
    let clientName: String
    @Binding var selectedDate: Date
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Client")) { Text(clientName) }
                Section(header: Text("Clock in time")) {
                    DatePicker("Start", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.wheel)
                }
                Section { Button("Start session") { onConfirm() } }
            }
            .navigationTitle("Clock in at…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } } }
        }
    }
}

struct ActiveSessionView: View {
    let session: ActiveSession
    let onClockOutNow: () -> Void
    let onClockOutAt: (Date) -> Void

    @State private var now = Date()
    @State private var showingClockOutAt = false
    @State private var clockOutAtDate = Date()
    @State private var showEndBeforeStartAlert = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var elapsedSeconds: Int { max(0, Int(now.timeIntervalSince(session.startDate))) }

    // exact seconds-based earnings, rounded DOWN to cents
    var earningsDisplay: Double {
        let exact = (Double(elapsedSeconds) / 3600.0) * session.client.hourlyRate
        return floor(exact * 100.0) / 100.0
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text(session.client.name).font(.title2)

                Text("Started: \(session.startDate.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundColor(.secondary)

                Text("Elapsed: \(formatElapsed(elapsedSeconds))").font(.title3)
                Text(String(format: "Earnings: $%.2f", earningsDisplay)).font(.title3)

                Spacer()

                Button(role: .destructive) { onClockOutNow() } label: {
                    Text("Clock out now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    clockOutAtDate = Date()
                    showingClockOutAt = true
                } label: {
                    Text("Clock out at…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 8)
            }
            .padding()
            .navigationTitle("Active")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingClockOutAt) {
                NavigationView {
                    Form {
                        Section(header: Text("Clock out time")) {
                            DatePicker("End", selection: $clockOutAtDate, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.wheel)
                        }
                        Section {
                            Button("Confirm clock out") {
                                if clockOutAtDate < session.startDate {
                                    showEndBeforeStartAlert = true
                                    return
                                }
                                showingClockOutAt = false
                                onClockOutAt(clockOutAtDate)
                            }
                        }
                    }
                    .navigationTitle("Clock out at…")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingClockOutAt = false } }
                    }
                }
            }
            .alert("Clock-out can’t be before clock-in.", isPresented: $showEndBeforeStartAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Choose an end time after \(session.startDate.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        .onReceive(timer) { now = $0 }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rounding: Int = 6

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Invoice rounding")) {
                    Stepper("Round down to \(rounding) minutes", value: $rounding, in: 1...30)
                    Text("Invoices bill time rounded down (favoring your employer).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.settings.roundingIncrementMinutes = rounding
                        store.saveSettings()
                        dismiss()
                    }
                }
            }
            .onAppear { rounding = store.settings.roundingIncrementMinutes }
        }
    }
}

// MARK: - Add Client View

struct AddClientView: View {
    @State private var name: String = ""
    @State private var rateText: String = ""

    let onAdd: (String, Double) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Client")) {
                    TextField("Name", text: $name)
                }

                Section(header: Text("Hourly rate")) {
                    TextField("e.g. 75", text: $rateText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Button("Add client") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rate = Double(rateText.replacingOccurrences(of: ",", with: ".")) ?? 0
                        onAdd(trimmed.isEmpty ? "New Client" : trimmed, rate)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
            }
        }
    }
}

// MARK: - PDF Rendering

enum InvoicePDFRenderer {
    static func render(
        invoiceNumber: String,
        clientName: String,
        status: String,
        createdAt: Date,
        paidAt: Date?,
        roundingMinutes: Int,
        lineItems: [InvoiceLineItem],
        totalHours: Double,
        totalAmount: Double
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = 40
            let left: CGFloat = 40

            func draw(_ text: String, font: UIFont, y: CGFloat) -> CGFloat {
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                let rect = CGRect(x: left, y: y, width: pageRect.width - 80, height: 1000)
                let s = NSAttributedString(string: text, attributes: attrs)
                let h = s.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], context: nil).height
                s.draw(in: CGRect(x: left, y: y, width: rect.width, height: h))
                return y + h
            }

            y = draw("INVOICE \(invoiceNumber)", font: .boldSystemFont(ofSize: 20), y: y)
            y = draw("Client: \(clientName)", font: .systemFont(ofSize: 12), y: y + 8)
            y = draw("Status: \(status)", font: .systemFont(ofSize: 12), y: y + 2)
            y = draw("Created: \(df.string(from: createdAt))", font: .systemFont(ofSize: 12), y: y + 2)
            if let paidAt { y = draw("Paid: \(df.string(from: paidAt))", font: .systemFont(ofSize: 12), y: y + 2) }
            y = draw("Rounding: \(roundingMinutes) min down", font: .systemFont(ofSize: 12), y: y + 2)

            y += 12
            y = draw("Line items:", font: .boldSystemFont(ofSize: 14), y: y)
            y += 6

            let headerFont = UIFont.boldSystemFont(ofSize: 10)
            let bodyFont = UIFont.systemFont(ofSize: 10)

            func line(_ s: String, y: CGFloat, bold: Bool = false) -> CGFloat {
                draw(s, font: bold ? headerFont : bodyFont, y: y)
            }

            y = line("Start → End | Billed (hrs) | Rate | Amount | Note", y: y, bold: true)
            y += 4

            for li in lineItems {
                if y > pageRect.height - 120 { ctx.beginPage(); y = 40 }
                let start = df.string(from: li.startDate)
                let end = df.string(from: li.endDate)
                let row = "\(start) → \(end) | \(String(format: "%.2f", li.billedHours)) | $\(String(format: "%.2f", li.rate)) | $\(String(format: "%.2f", li.amount)) | \(li.note ?? "")"
                y = line(row, y: y)
                y += 2
            }

            y += 10
            y = draw(String(format: "Total billed hours: %.2f", totalHours), font: .boldSystemFont(ofSize: 12), y: y)
            y = draw(String(format: "Total amount: $%.2f", totalAmount), font: .boldSystemFont(ofSize: 12), y: y + 2)
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

// MARK: - Simple CSV parser (for our own export/import)

enum CSV {
    /// Parses CSV into rows/fields. Handles quoted fields with doubled quotes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            // Skip completely empty trailing row
            if !(row.count == 1 && row.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) {
                rows.append(row)
            }
            row = []
        }

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]

            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    endField()
                } else if c == "\n" {
                    endField()
                    endRow()
                } else if c == "\r" {
                    // ignore; handle CRLF
                } else {
                    field.append(c)
                }
            }

            i = text.index(after: i)
        }

        // final field/row
        endField()
        endRow()
        return rows
    }
}
