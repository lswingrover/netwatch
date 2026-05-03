/// NetWatchMobileApp.swift — iOS companion app entry point
///
/// Architecture: APIClient (owned by ConnectionState) → Views
/// All views receive ConnectionState as an @EnvironmentObject.

import SwiftUI

@main
struct NetWatchMobileApp: App {

    // ConnectionState owns APIClient; both are created together.
    @StateObject private var connection: ConnectionState = {
        let client = APIClient()
        return ConnectionState(client: client)
    }()

    var body: some Scene {
        WindowGroup {
            if connection.client.macIP.isEmpty {
                // First-launch: no Mac IP set — send user to Settings.
                NavigationStack {
                    MobileSettingsView()
                        .environmentObject(connection)
                        .navigationTitle("Setup NetWatch")
                }
                .onAppear {
                    // Start polling anyway; will show unconfigured state gracefully.
                    connection.startPolling()
                }
            } else {
                ContentView()
                    .environmentObject(connection)
                    .onAppear  { connection.startPolling()  }
                    .onDisappear { connection.stopPolling() }
            }
        }
    }
}
