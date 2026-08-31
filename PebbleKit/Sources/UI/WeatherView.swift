import API
import SwiftUI

/// The places the watch shows weather for.
struct WeatherView: View {
    var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var placeQuery = ""

    private var followsPhone: Bool {
        model.weatherPlaces.contains(where: \.followsPhone)
    }

    /// A watch only stores weather if its firmware has the weather app.
    private var watchesWithoutWeather: [String] {
        model.connections
            .filter { $0.isConnected && !$0.device.supportsWeatherApp }
            .map(\.device.name)
    }

    var body: some View {
        Form {
            Section {
                if model.weatherPlaces.isEmpty {
                    ContentUnavailableView {
                        Label("No Places", systemImage: "cloud.sun")
                    } description: {
                        Text("Add where you are, or a place you want to keep an eye on.")
                    }
                }
                ForEach(model.weatherPlaces) { place in
                    LabeledContent {
                        if let report = model.weatherReports.first(where: { $0.id == place.id }) {
                            Text(temperature(report.currentTemperature))
                        }
                    } label: {
                        Text(verbatim: place.name)
                        if place.followsPhone {
                            Text("Follows the phone")
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.weatherPlaces[$0].id }
                    Task {
                        for id in ids { await model.removeWeatherPlace(id: id) }
                    }
                }
            } header: {
                Text("Places")
            } footer: {
                if let updated = model.weatherUpdated {
                    Text("Updated \(updated, format: .relative(presentation: .named)).")
                }
            }

            Section {
                if !followsPhone {
                    Button("Use Where the Phone Is", systemImage: "location") {
                        Task { await model.followPhoneForWeather() }
                    }
                }
                HStack {
                    TextField("Town or city", text: $placeQuery)
                        .onSubmit { addPlace() }
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                    Button("Add", systemImage: "plus") { addPlace() }
                        .labelStyle(.iconOnly)
                        .disabled(placeQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add a Place")
            }

            Section {
                Picker("Temperature", selection: Binding(
                    get: { model.weatherUsesFahrenheit },
                    set: { usesFahrenheit in
                        Task { await model.setWeatherUsesFahrenheit(usesFahrenheit) }
                    }
                )) {
                    Text("Celsius").tag(false)
                    Text("Fahrenheit").tag(true)
                }
                Button("Refresh Now", systemImage: "arrow.clockwise") {
                    Task { await model.refreshWeather() }
                }
                .disabled(model.isRefreshingWeather || model.weatherPlaces.isEmpty)
                if let message = model.weatherStatusMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("The watch keeps the numbers it is given, so they are sent in this unit.")
            }

            if !watchesWithoutWeather.isEmpty {
                Section {
                    ForEach(watchesWithoutWeather, id: \.self) { name in
                        Label {
                            Text("\(name) has no weather app, so nothing is sent to it.")
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let credit = model.weatherCredit {
                Section {
                    Link(destination: credit.legalPageURL) {
                        HStack {
                            AsyncImage(
                                url: colorScheme == .dark ? credit.darkMarkURL : credit.lightMarkURL
                            ) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                Text(verbatim: credit.serviceName)
                            }
                            .frame(height: 16)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Weather data sources")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Weather")
        .task {
            // A forecast an hour old is not worth sending; one from this
            // session is.
            guard model.weatherUpdated == nil || model.weatherUpdated?.timeIntervalSinceNow ?? 0 < -3600 else {
                return
            }
            await model.refreshWeather()
        }
    }

    private func addPlace() {
        let query = placeQuery
        placeQuery = ""
        Task { await model.addWeatherPlace(named: query) }
    }

    private func temperature(_ degrees: Int16) -> String {
        let unit: UnitTemperature = model.weatherUsesFahrenheit ? .fahrenheit : .celsius
        return Measurement(value: Double(degrees), unit: unit)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number))
    }
}
