import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryStore()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            BookshelfView(selectedTab: $selectedTab)
                .environmentObject(library)
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            WiFiImportView()
                .environmentObject(library)
                .tabItem { Label("WiFi传书", systemImage: "wifi") }
                .tag(1)
        }
    }
}
