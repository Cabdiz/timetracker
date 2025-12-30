//
//  ContentView.swift
//  TimeTracker2
//
//  Created by Szk Login on 12/29/25.
//

import SwiftUI

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

struct ActiveSession {
    var client: Client
    var startDate: Date
}

// MARK: - Main View

struct ContentView: View {
    // Persistence
    private let clientsKey = "clients_v1"

    @State private var clients: [Client] = []

    // Selection + dialogs
    @State private var selectedClient: Client? = nil
    @State private var showingActions = false

    // Active session
    @State private var activeSession: ActiveSession? = nil
    @State private var showingActiveSheet = false

    // Clock in at…
    @State private var showingClockInAtSheet = false
    @State private var clockInAtDate = Date()

    // Client details
    @State private var showingClientDetails = false

    // Add client
    @State private var showingAddClient = false

    var body: some View {
        NavigationView {
            List {
                ForEach(clients) { client in
                    Button {
                        selectedClient = client
                        showingActions = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(client.name)
                                    .font(.headline)
                                Text(String(format: "$%.2f/hr", client.hourlyRate))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if activeSession?.client.id == client.id {
                                Text("Active")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteClients)
            }
            .navigationTitle("Clients")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddClient = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
            .onAppear {
                loadClients()
            }
            .onChange(of: clients) { _ in
                saveClients()
            }
            .confirmationDialog(
                selectedClient?.name ?? "Client",
                isPresented: $showingActions,
                titleVisibility: .visible
            ) {
                Button("Clock in now") {
                    startSession(with: Date())
                }

                Button("Clock in at…") {
                    clockInAtDate = Date()
                    showingClockInAtSheet = true
                }

                Button("View client details") {
                    showingClientDetails = true
                }

                Button("Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $showingActiveSheet) {
                if let session = activeSession {
                    ActiveSessionView(session: session) {
                        activeSession = nil
                        showingActiveSheet = false
                    }
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
                if let client = selectedClient,
                   let index = clients.firstIndex(where: { $0.id == client.id }) {
                    ClientDetailView(client: $clients[index])
                } else {
                    Text("No client selected").padding()
                }
            }
            .sheet(isPresented: $showingAddClient) {
                AddClientView { name, rate in
                    clients.append(Client(name: name, hourlyRate: rate))
                    showingAddClient = false
                } onCancel: {
                    showingAddClient = false
                }
            }
        }
    }

    // MARK: - Actions

    private func startSession(with startDate: Date) {
        guard let c = selectedClient else { return }
        activeSession = ActiveSession(client: c, startDate: startDate)
        showingActiveSheet = true
    }

    private func deleteClients(at offsets: IndexSet) {
        clients.remove(atOffsets: offsets)
    }

    // MARK: - Persistence

    private func loadClients() {
        guard let data = UserDefaults.standard.data(forKey: clientsKey) else {
            // First run defaults
            clients = [
                Client(name: "Client A", hourlyRate: 50),
                Client(name: "Client B", hourlyRate: 75)
            ]
            return
        }

        do {
            clients = try JSONDecoder().decode([Client].self, from: data)
            if clients.isEmpty {
                // Safety fallback
                clients = [
                    Client(name: "Client A", hourlyRate: 50),
                    Client(name: "Client B", hourlyRate: 75)
                ]
            }
        } catch {
            // If decode fails, reset to safe defaults
            clients = [
                Client(name: "Client A", hourlyRate: 50),
                Client(name: "Client B", hourlyRate: 75)
            ]
            print("Failed to decode clients:", error)
        }
    }

    private func saveClients() {
        do {
            let data = try JSONEncoder().encode(clients)
            UserDefaults.standard.set(data, forKey: clientsKey)
        } catch {
            print("Failed to encode clients:", error)
        }
    }
}

// MARK: - Views

struct ClientDetailView: View {
    @Binding var client: Client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Client")) {
                    TextField("Name", text: $client.name)
                }

                Section(header: Text("Rate")) {
                    TextField("Hourly rate", value: $client.hourlyRate, format: .number)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Client Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

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
                        let rate = Double(rateText.replacingOccurrences(of: ",", with: ".")) ?? 0
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onAdd(trimmed.isEmpty ? "New Client" : trimmed, rate)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

struct ClockInAtView: View {
    let clientName: String
    @Binding var selectedDate: Date
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Client")) {
                    Text(clientName)
                }

                Section(header: Text("Clock in time")) {
                    DatePicker(
                        "Start",
                        selection: $selectedDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                }

                Section {
                    Button("Start session") { onConfirm() }
                }
            }
            .navigationTitle("Clock in at…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

struct ActiveSessionView: View {
    let session: ActiveSession
    let onClockOut: () -> Void

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var elapsedSeconds: Int {
        max(0, Int(now.timeIntervalSince(session.startDate)))
    }

    var earnings: Double {
        (Double(elapsedSeconds) / 3600.0) * session.client.hourlyRate
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text(session.client.name)
                    .font(.title2)

                Text("Started: \(session.startDate.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundColor(.secondary)

                Text("Elapsed: \(formatElapsed(elapsedSeconds))")
                    .font(.title3)

                Text(String(format: "Earnings: $%.2f", earnings))
                    .font(.title3)

                Spacer()

                Button(role: .destructive) {
                    onClockOut()
                } label: {
                    Text("Clock out")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
            }
            .padding()
            .navigationTitle("Active")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onReceive(timer) { value in
            now = value
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
