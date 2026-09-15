import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryStore()
    @StateObject private var sources = BookSourceStore()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            BookshelfView(selectedTab: $selectedTab)
                .environmentObject(library)
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            OnlineSearchView()
                .environmentObject(library)
                .environmentObject(sources)
                .tabItem { Label("书城", systemImage: "globe") }
                .tag(1)

            WiFiImportView()
                .environmentObject(library)
                .tabItem { Label("WiFi传书", systemImage: "wifi") }
                .tag(2)
        }
    }
}
