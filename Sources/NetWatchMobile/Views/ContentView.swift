/// ContentView.swift — Root tab bar for NetWatch Mobile

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connection: ConnectionState

    var body: some View {
        TabView {
            MobileOverviewView()
                .tabItem { Label("Overview",   systemImage: "eye") }

            MobileConnectorsView()
                .tabItem { Label("Connectors", systemImage: "cable.connector.horizontal") }

            MobileIncidentsView()
                .tabItem { Label("Incidents",  systemImage: "exclamationmark.triangle") }

            MobileSettingsView()
                .tabItem { Label("Settings",   systemImage: "gearshape") }
        }
    }
}
