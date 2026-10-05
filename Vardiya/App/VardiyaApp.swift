import SwiftUI

@main
struct VardiyaApp: App {
    @State private var store = ShiftStore()

    var body: some Scene {
        Window("Vardiya", id: "office") {
            MainView()
                .environment(store)
                .onAppear { store.start() }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact)

        // Oturum başına sohbet penceresi
        WindowGroup(id: "chat", for: String.self) { $sessionID in
            if let sessionID {
                ChatWindow(sessionID: sessionID)
                    .environment(store)
            }
        }
        .defaultSize(width: 560, height: 720)

        // Menü çubuğu: pencere kapalıyken de kim çalışıyor, kim sizi bekliyor görünsün.
        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let store: ShiftStore

    var body: some View {
        if store.needsYouCount > 0 {
            Label("\(store.needsYouCount)", systemImage: "hand.raised.fill")
        } else if store.busyCount > 0 {
            Label("\(store.busyCount)", systemImage: "person.2.fill")
        } else {
            Image(systemName: "person.2")
        }
    }
}

private struct MenuBarContent: View {
    @Environment(ShiftStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Vardiya").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(store.busyCount) working")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            if store.shifts.isEmpty {
                Text("Nobody is on shift")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(store.shifts) { shift in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shift.workers) { worker in
                        HStack(spacing: 7) {
                            Image(systemName: worker.activity.symbol)
                                .font(.system(size: 11))
                                .foregroundStyle(worker.activity.tint)
                                .frame(width: 16)
                            Text(worker.name)
                                .font(.system(size: 12, weight: worker.kind == .main ? .semibold : .regular))
                                .padding(.leading, worker.kind == .main ? 0 : 10)
                            Spacer(minLength: 6)
                            StatusPill(activity: worker.activity)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Open office") {
                    openWindow(id: "office")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 300)
    }
}
