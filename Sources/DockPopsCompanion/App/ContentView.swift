import AppKit
import Observation
import SwiftUI

struct ContentView: View {
    @Bindable var model: CompanionModel
    @State private var selectedPopletIDs: Set<UUID> = []

    var body: some View {
        Group {
            if !model.hasSharedFolderAccess {
                connectStateView
            } else if !model.metadataAvailable {
                waitingForDockPopsStateView
            } else if model.poplets.isEmpty {
                emptyPopsStateView
            } else {
                popletsGridView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(WindowSurfaceModifier())
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(model.isRefreshing ? "Refreshing…" : "Refresh") {
                    Task {
                        await model.refreshNow()
                    }
                }
                .disabled(model.isRefreshing)

                if model.hasSharedFolderAccess {
                    Button("Reveal Folder") {
                        model.revealPopletsFolder()
                    }
                }
            }
        }
    }

    private var popletsGridView: some View {
        VStack(spacing: 18) {
            browserShell
                .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.poplets.map(\.id)) { _, ids in
            let validIDs = Set(ids)
            selectedPopletIDs = selectedPopletIDs.intersection(validIDs)
        }
    }

    private var browserShell: some View {
        VStack(spacing: 0) {
            browserHeader

            Divider()

            PopletFinderGridView(
                poplets: model.poplets,
                selection: $selectedPopletIDs
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            )
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var browserHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 6) {
                Text("Multipops Companion")
                    .font(.headline.weight(.semibold))

                Text(browserHintText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                Text(browserSelectionText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Button("Reveal in Finder") {
                    model.revealPopletsFolder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(18)
    }

    private var visibleSelection: Set<UUID> {
        let validIDs = Set(model.poplets.map(\.id))
        return selectedPopletIDs.intersection(validIDs)
    }

    private var browserSelectionText: String {
        let selectedCount = visibleSelection.count
        if selectedCount > 0 {
            return "\(selectedCount) selected"
        }
        return "\(model.poplets.count) poplets"
    }

    private var browserHintText: String {
        let selectedCount = visibleSelection.count
        if selectedCount > 0 {
            return "Drag the selected Pops into the Dock."
        }
        return "Drag to the Dock, or Command-click to select multiple Pops."
    }

    private var connectStateView: some View {
        setupStateView(
            title: model.statusTitle,
            systemImage: "hand.raised.square",
            message: model.statusMessage
        ) {
            Button("Try Again") {
                Task {
                    await model.refreshNow()
                }
            }
            .buttonStyle(.borderedProminent)

            if model.dockPopsFound {
                Button("Open DockPops") {
                    model.openDockPops()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var waitingForDockPopsStateView: some View {
        setupStateView(
            title: model.statusTitle,
            systemImage: "sparkles.rectangle.stack",
            message: model.statusMessage
        ) {
            Button("Open DockPops") {
                model.openDockPops()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.dockPopsFound)

            Button("Refresh") {
                Task {
                    await model.refreshNow()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var emptyPopsStateView: some View {
        setupStateView(
            title: model.statusTitle,
            systemImage: "app.badge",
            message: model.statusMessage
        ) {
            Button("Open DockPops") {
                model.openDockPops()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.dockPopsFound)

            Button("Reveal Poplets in Finder") {
                model.revealPopletsFolder()
            }
            .buttonStyle(.bordered)
        }
    }

    private func setupStateView<Actions: View>(
        title: String,
        systemImage: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            actions()
        }
    }
}

private struct WindowSurfaceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.thinMaterial, for: .window)
        } else {
            content
        }
    }
}
