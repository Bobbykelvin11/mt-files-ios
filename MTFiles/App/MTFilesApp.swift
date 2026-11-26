import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let ipa: UTType = UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip)
}

@main
struct MTFilesApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var places = LocationStore()
    @StateObject private var app = AppModel()

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.uiBG
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = Theme.uiBG
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(places)
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    app.receive(url)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var places: LocationStore
    @State private var showIPALibrary = false

    var body: some View {
        TabView(selection: $app.tab) {
            filesTab
                .tabItem { Label("Files", systemImage: "rectangle.split.2x1") }
                .tag(0)
            HomeView(selectedTab: Binding(get: { 0 }, set: { if $0 == 1 { showIPALibrary = true } }))
                .sheet(isPresented: $showIPALibrary) { LibraryView().environmentObject(store).preferredColorScheme(.dark) }
                .tabItem { Label("IPA", systemImage: "app.badge") }
                .tag(1)
            AssistantView(context: app.context(for: app.active), isTab: true)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(2)
            MTSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .overlay {
            if let msg = app.busy ?? store.busyMessage { BusyOverlay(message: msg) }
        }
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                Text(t).font(.callout.bold())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 90)
                    .transition(.opacity)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { app.error != nil || store.lastError != nil },
            set: { if !$0 { app.error = nil; store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { app.error = nil; store.lastError = nil }
        } message: {
            Text(app.error ?? store.lastError ?? "")
        }
        .fullScreenCover(item: $app.open) { req in
            ViewerHost(request: req)
                .environmentObject(app)
                .environmentObject(store)
                .environmentObject(places)
                .overlay {
                    if let msg = app.busy ?? store.busyMessage { BusyOverlay(message: msg) }
                }
        }
    }

    private var filesTab: some View {
        NavigationStack {
            DualPaneView()
                .navigationTitle("MT Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { app.transfer(from: app.active, move: false) } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("Copy selected to other pane")
                        Button { app.transfer(from: app.active, move: true) } label: { Image(systemName: "arrow.right.doc.on.clipboard") }
                            .accessibilityLabel("Move selected to other pane")
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { app.left.go(app.right.dir); } label: { Image(systemName: "arrow.left.arrow.right") }
                            .accessibilityLabel("Sync panes")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        app.assistantContext = app.context(for: app.active)
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 54, height: 54)
                            .background(Theme.accent, in: Circle())
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 70)
                }
        }
        .sheet(item: $app.assistantContext) { ctx in
            AssistantView(context: ctx)
                .environmentObject(app)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
