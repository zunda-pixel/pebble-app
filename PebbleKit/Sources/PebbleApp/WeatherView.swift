import PebbleProtocol
import SwiftUI

struct WeatherView: View {
    var model: AppModel

    /// A watch only stores weather if its firmware has the weather app.
    private var watchesWithoutWeather: [String] {
        model.connections
            .filter { $0.isConnected && !$0.watch.supportsWeatherApp }
            .map(\.watch.name)
    }

    var body: some View {
        WeatherContent(
            places: model.weatherPlaces,
            reports: model.weatherReports,
            updated: model.weatherUpdated,
            usesFahrenheit: model.weatherUsesFahrenheit,
            isRefreshing: model.isRefreshingWeather,
            statusMessage: model.weatherStatusMessage,
            watchesWithoutWeather: watchesWithoutWeather,
            credit: model.weatherCredit,
            followPhone: { Task { await model.followPhoneForWeather() } },
            addPlace: { query in Task { await model.addWeatherPlace(named: query) } },
            removePlaces: { ids in
                Task {
                    for id in ids { await model.removeWeatherPlace(id: id) }
                }
            },
            setUsesFahrenheit: { usesFahrenheit in
                Task { await model.setWeatherUsesFahrenheit(usesFahrenheit) }
            },
            refresh: { Task { await model.refreshWeather() } }
        )
        .task {
            // A forecast an hour old is not worth sending; one from this
            // session is.
            guard model.weatherUpdated == nil || model.weatherUpdated?.timeIntervalSinceNow ?? 0 < -3600 else {
                return
            }
            await model.refreshWeather()
        }
    }
}

/// The places the watch shows weather for.
struct WeatherContent: View {
    var places: [WeatherPlace]
    var reports: [WeatherReport]
    var updated: Date?
    var usesFahrenheit: Bool
    var isRefreshing: Bool
    var statusMessage: LocalizedStringKey?
    var watchesWithoutWeather: [String]
    var credit: WeatherCredit?
    var followPhone: () -> Void
    var addPlace: (String) -> Void
    var removePlaces: ([UUID]) -> Void
    var setUsesFahrenheit: (Bool) -> Void
    var refresh: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var placeQuery = ""

    private var followsPhone: Bool {
        places.contains(where: \.followsPhone)
    }

    var body: some View {
        Form {
            Section {
                if places.isEmpty {
                    ContentUnavailableView {
                        Label("No Places", systemImage: "cloud.sun")
                    } description: {
                        Text("Add where you are, or a place you want to keep an eye on.")
                    }
                }
                ForEach(places) { place in
                    LabeledContent {
                        if let report = reports.first(where: { $0.id == place.id }) {
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
                    removePlaces(offsets.compactMap { places.indices.contains($0) ? places[$0].id : nil })
                }
            } header: {
                Text("Places")
            } footer: {
                if let updated {
                    Text("Updated \(updated, format: .relative(presentation: .named)).")
                }
            }

            Section {
                if !followsPhone {
                    Button("Use Where the Phone Is", systemImage: "location", action: followPhone)
                }
                HStack {
                    TextField("Town or city", text: $placeQuery)
                        .onSubmit { submitPlace() }
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                    Button("Add", systemImage: "plus") { submitPlace() }
                        .labelStyle(.iconOnly)
                        .disabled(placeQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add a Place")
            }

            Section {
                Picker("Temperature", selection: Binding(
                    get: { usesFahrenheit },
                    set: { setUsesFahrenheit($0) }
                )) {
                    Text("Celsius").tag(false)
                    Text("Fahrenheit").tag(true)
                }
                Button("Refresh Now", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(isRefreshing || places.isEmpty)
                if let statusMessage {
                    Label(statusMessage, systemImage: "exclamationmark.triangle")
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

            if let credit {
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
                    .accessibilityLabel(Text("Weather data sources"))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Weather"))
    }

    private func submitPlace() {
        let query = placeQuery
        placeQuery = ""
        addPlace(query)
    }

    private func temperature(_ degrees: Int16) -> String {
        let unit: UnitTemperature = usesFahrenheit ? .fahrenheit : .celsius
        return Measurement(value: Double(degrees), unit: unit)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number))
    }
}

#Preview("Two places") {
    NavigationStack {
        WeatherContent(
            places: PreviewSamples.weatherPlaces,
            reports: PreviewSamples.weatherReports,
            updated: .now.addingTimeInterval(-600),
            usesFahrenheit: false,
            isRefreshing: false,
            statusMessage: nil,
            watchesWithoutWeather: [],
            credit: PreviewSamples.weatherCredit,
            followPhone: {},
            addPlace: { _ in },
            removePlaces: { _ in },
            setUsesFahrenheit: { _ in },
            refresh: {}
        )
    }
}

#Preview("One refused, one watch without the app") {
    NavigationStack {
        WeatherContent(
            places: PreviewSamples.weatherPlaces,
            reports: Array(PreviewSamples.weatherReports.prefix(1)),
            updated: .now.addingTimeInterval(-4_000),
            usesFahrenheit: true,
            isRefreshing: false,
            statusMessage: "The forecast for Kyoto was refused by WeatherKit.",
            watchesWithoutWeather: ["Pebble 2 Duo"],
            credit: PreviewSamples.weatherCredit,
            followPhone: {},
            addPlace: { _ in },
            removePlaces: { _ in },
            setUsesFahrenheit: { _ in },
            refresh: {}
        )
    }
}

#Preview("No places") {
    NavigationStack {
        WeatherContent(
            places: [],
            reports: [],
            updated: nil,
            usesFahrenheit: false,
            isRefreshing: false,
            statusMessage: nil,
            watchesWithoutWeather: [],
            credit: nil,
            followPhone: {},
            addPlace: { _ in },
            removePlaces: { _ in },
            setUsesFahrenheit: { _ in },
            refresh: {}
        )
    }
}
