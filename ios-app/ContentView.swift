import SwiftUI

struct Outcome: Identifiable { let id = UUID(); let name: String; let price: Double }
struct MatchVM: Identifiable { let id = UUID(); let title: String; let outcomes: [Outcome] }

struct TicketItem: Identifiable { let id = UUID(); let title: String; let outcome: String; let odd: Double }

struct Me: Codable { let username: String; let balance: Double }
struct BetResult: Codable { let balance: Double; let gain: Double }

struct RemoteOutcome: Codable { let name: String; let price: Double }
struct RemoteMarket: Codable { let outcomes: [RemoteOutcome] }
struct RemoteBookmaker: Codable { let markets: [RemoteMarket] }
struct RemoteMatch: Codable {
    let home_team: String
    let away_team: String
    let bookmakers: [RemoteBookmaker]?
}

@main
struct DanilBetApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var token: String? = nil
    @State private var me: Me? = nil
    @State private var matches: [MatchVM] = []
    @State private var ticket: [TicketItem] = []
    @State private var stake: String = ""
    @State private var message: String = ""

    var totalOdd: Double { ticket.reduce(1) { $0 * $1.odd } }
    var potentialGain: Double { (Double(stake) ?? 0) * totalOdd }

    var body: some View {
        NavigationStack {
            if token == nil {
                AuthView(onAuth: { newToken in
                    Task { await loadAfterAuth(token: newToken) }
                })
                .navigationTitle("DanilBet")
            } else {
                VStack {
                    List(matches) { match in
                        VStack(alignment: .leading) {
                            Text(match.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            HStack {
                                ForEach(match.outcomes) { outcome in
                                    Button(action: {
                                        ticket.append(TicketItem(title: match.title, outcome: outcome.name, odd: outcome.price))
                                    }) {
                                        VStack {
                                            Text(outcome.name)
                                                .font(.caption)
                                            Text(String(format: "%.2f", outcome.price))
                                                .font(.headline)
                                        }
                                        .padding(8)
                                        .frame(minWidth: 60)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ticket")
                            .font(.headline)
                        ForEach(ticket) { item in
                            Text("\(item.title) - \(item.outcome) (\(String(format: "%.2f", item.odd)))")
                                .font(.caption)
                        }

                        TextField("Mise", text: $stake)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Text("Cote totale: \(String(format: "%.2f", totalOdd))")
                            Spacer()
                            Text("Gain potentiel: \(String(format: "%.2f", potentialGain))€")
                                .foregroundColor(.green)
                        }

                        if let me { Text("Solde: \(String(format: "%.2f", me.balance))€") }

                        Button("Parier") { Task { await placeBet() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                        Button("Déconnexion") { token = nil; me = nil; ticket.removeAll(); message = "" }
                            .buttonStyle(.bordered)
                            .tint(.red)

                        if !message.isEmpty {
                            Text(message)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }
                .navigationTitle("DanilBet")
                .task {
                    if let token { await loadAfterAuth(token: token) }
                }
            }
        }
    }

    func loadAfterAuth(token: String) async {
        self.token = token
        do {
            self.me = try await API.me(token: token)
        } catch { message = "Erreur /me" }

        do {
            let remoteMatches = try await API.fetchOdds()
            let vms: [MatchVM] = remoteMatches.compactMap { m in
                let title = "\(m.home_team) vs \(m.away_team)"
                let outcomes: [Outcome] = (m.bookmakers?.first?.markets?.first?.outcomes ?? []).map { Outcome(name: $0.name, price: $0.price) }
                if outcomes.isEmpty { return nil }
                return MatchVM(title: title, outcomes: outcomes)
            }
            await MainActor.run { self.matches = vms }
        } catch {
            message = "Erreur /odds"
        }
    }

    func placeBet() async {
        guard let token else { return }
        guard let stakeValue = Double(stake), stakeValue > 0 else { message = "Mise invalide"; return }
        guard !ticket.isEmpty else { message = "Ticket vide"; return }

        do {
            let result = try await API.bet(token: token, stake: stakeValue, odd: totalOdd)
            await MainActor.run {
                self.me = Me(username: me?.username ?? "", balance: result.balance)
                self.message = "Résultat gain: \(String(format: "%.2f", result.gain))€"
                self.ticket.removeAll()
                self.stake = ""
            }
        } catch {
            message = "Erreur parier"
        }
    }
}

struct AuthView: View {
    var onAuth: (String) async -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var isRegister = false
    @State private var message = ""

    var body: some View {
        Form {
            TextField("Username", text: $username)
            SecureField("Password", text: $password)

            Toggle("Créer un compte", isOn: $isRegister)

            Button(isRegister ? "Register" : "Login") {
                Task {
                    do {
                        let token = try await (isRegister ? API.register(username: username, password: password) : API.login(username: username, password: password))
                        await onAuth(token)
                    } catch {
                        message = "Erreur auth"
                    }
                }
            }

            if !message.isEmpty { Text(message).foregroundColor(.secondary) }

            Text("Backend URL & ATS à configurer dans API.swift/Info.plist")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

enum API {
    static let baseURL = URL(string: "http://localhost:3000")! // CHANGE: mettre IP/domaine backend

    static func request(path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.addValue(token, forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func register(username: String, password: String) async throws -> String {
        let data = try await request(path: "/register", method: "POST", body: ["username": username, "password": password])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = obj?["token"] as? String else { throw URLError(.cannotParseResponse) }
        return token
    }

    static func login(username: String, password: String) async throws -> String {
        let data = try await request(path: "/login", method: "POST", body: ["username": username, "password": password])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = obj?["token"] as? String else { throw URLError(.cannotParseResponse) }
        return token
    }

    static func me(token: String) async throws -> Me {
        let data = try await request(path: "/me", token: token)
        return try JSONDecoder().decode(Me.self, from: data)
    }

    static func fetchOdds() async throws -> [RemoteMatch] {
        let data = try await request(path: "/odds")
        return try JSONDecoder().decode([RemoteMatch].self, from: data)
    }

    static func bet(token: String, stake: Double, odd: Double) async throws -> BetResult {
        let data = try await request(path: "/bet", method: "POST", token: token, body: ["stake": stake, "odd": odd])
        return try JSONDecoder().decode(BetResult.self, from: data)
    }
}
