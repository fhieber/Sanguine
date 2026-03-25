import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 1   // default: Doses tab

    var body: some View {
        TabView(selection: $selectedTab) {
            ReadingsTab()
                .tabItem { Label("Readings", systemImage: "chart.xyaxis.line") }
                .tag(0)
            DoseTab()
                .tabItem { Label("Doses", systemImage: "calendar.badge.checkmark") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(2)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDoseDetail)) { _ in
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAddReading)) { _ in
            selectedTab = 0
        }
        .onOpenURL { url in
            switch url.host {
            case "add-reading":
                selectedTab = 0
                NotificationCenter.default.post(name: .navigateToAddReading, object: nil)
            case "dose-detail":
                selectedTab = 1
                NotificationCenter.default.post(name: .navigateToDoseDetail, object: nil)
            default:
                break
            }
        }
    }
}
