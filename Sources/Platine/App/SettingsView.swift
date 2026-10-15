import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var query = ""
    @State private var results: [Weather.Place] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var cities = CityViews.all()
    @State private var viewQuery = ""
    @State private var viewAttempt = 0
    @State private var viewStatus: String?
    @State private var searching = false

    var body: some View {
        Form {
            Section("Room") {
                Picker("Framing", selection: $settings.framing) {
                    ForEach(Framing.allCases) { Text($0.title).tag($0) }
                }
                Picker("Rain on the window", selection: $settings.rainMode) {
                    ForEach(RainMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show on all displays", isOn: $settings.allDisplays)
                Picker("Frame rate", selection: $settings.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }

            Section {
                Picker("City", selection: $settings.viewCity) {
                    ForEach(cities) { Text($0.name).tag($0.id) }
                }
                HStack {
                    TextField("Find your own", text: $viewQuery)
                        .onSubmit { findView(attempt: 0) }
                    if searching {
                        ProgressView().controlSize(.small)
                    } else if settings.viewCity.hasPrefix("custom-") {
                        Button("Another photo") { findView(attempt: viewAttempt + 1) }
                    }
                }
                if let viewStatus { Text(viewStatus).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Through the window")
            } footer: {
                Text(CityViews.find(settings.viewCity)?.creditLine ?? "")
                    .textSelection(.enabled)
            }

            Section {
                LabeledContent("City", value: settings.cityName)
                TextField("Search a city", text: $query)
                    .onSubmit { Task { results = await Weather.search(query) } }
                ForEach(results) { place in
                    Button {
                        settings.cityName = place.name
                        settings.latitude = place.lat
                        settings.longitude = place.lon
                        results = []
                        query = ""
                    } label: {
                        VStack(alignment: .leading) {
                            Text(place.name)
                            Text(place.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Weather")
            } footer: {
                Text("If it rains there, it rains on your window. Only the city's coordinates are sent, to Open-Meteo.")
            }

            Section {
                Toggle("Look up track lists in Apple's catalog", isOn: $settings.catalogLookup)
            } header: {
                Text("Track lists")
            } footer: {
                Text("With Music, the track list comes from your library, offline. Turn this on to ask Apple's public catalog when an album isn't in your library, or for Spotify. Otherwise the record is cut around the songs you play.")
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { cities = CityViews.all() }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Free photos of any city, from Openverse: a day and a night one.
    private func findView(attempt: Int) {
        let name = viewQuery.isEmpty ? (CityViews.find(settings.viewCity)?.name ?? "") : viewQuery
        guard !name.isEmpty else { return }
        searching = true
        viewStatus = nil
        Task {
            defer { searching = false }
            do {
                let view = try await CityViews.search(name, attempt: attempt)
                viewAttempt = attempt
                cities = CityViews.all()
                settings.viewCity = view.id      // publishes even when unchanged: the room reloads the new photo
                viewQuery = ""
            } catch {
                viewStatus = error.localizedDescription
            }
        }
    }
}
