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
                Button(primaryActionTitle) {
                    Task {
                        await runPrimaryAction()
                    }
                }
                .disabled(model.isRefreshing || primaryActionDisabled)

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
            WorkflowGuideView()
                .frame(maxWidth: 720)

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
        return "\(model.poplets.count) ready"
    }

    private var browserHintText: String {
        let selectedCount = visibleSelection.count
        if selectedCount > 0 {
            return "Drag the selected Pops into the Dock. Anything you add or change in DockPops will show up here automatically."
        }
        return "Make or edit Pops in DockPops, then drag them into the Dock here. Command-click selects multiple Pops."
    }

    private var connectStateView: some View {
        setupStateView(
            title: model.statusTitle,
            systemImage: "hand.raised.square",
            message: model.statusMessage
        ) {
            Button(sharedAccessActionTitle) {
                Task {
                    await runPrimaryAction()
                }
            }
            .buttonStyle(.borderedProminent)

            if model.dockPopsFound {
                Button("Open DockPops") {
                    model.openDockPops()
                }
                .buttonStyle(.bordered)
            }

            if model.dockPopsFound {
                WorkflowGuideView(showsFolderGrantStep: true, emphasizesDockDrop: false)
                    .frame(maxWidth: 720)
                    .padding(.top, 8)
            }
        }
    }

    private var primaryActionTitle: String {
        if !model.hasSharedFolderAccess && model.dockPopsFound {
            return sharedAccessActionTitle
        }
        return model.isRefreshing ? "Refreshing…" : "Refresh"
    }

    private var sharedAccessActionTitle: String {
        if model.needsSharedAccessWarmup {
            return "Continue"
        }
        return "Choose Folder Again"
    }

    private var primaryActionDisabled: Bool {
        false
    }

    private func runPrimaryAction() async {
        if !model.hasSharedFolderAccess && model.dockPopsFound {
            await model.continueToSharedAccessPrompt()
        } else {
            await model.refreshNow()
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

            WorkflowGuideView(emphasizesDockDrop: false)
                .frame(maxWidth: 720)
                .padding(.top, 8)
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

            WorkflowGuideView(emphasizesDockDrop: false)
                .frame(maxWidth: 720)
                .padding(.top, 8)
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

private struct WorkflowGuideView: View {
    var showsFolderGrantStep = false
    var emphasizesDockDrop = true

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if showsFolderGrantStep {
                GuideStepCard(
                    symbol: "folder.fill",
                    title: "Choose Folder Once",
                    detail: "We remember DockPops' shared folder for future launches."
                )

                GuideArrow()
            }

            GuideStepCard(
                symbol: "app.fill",
                title: "Make or Edit Pops",
                detail: "Anything you create or modify in DockPops appears here automatically."
            )

            GuideArrow()

            GuideStepCard(
                symbol: "square.grid.2x2.fill",
                title: "They Show Up Here",
                detail: "This window refreshes with the latest Poplets from DockPops."
            )

            GuideArrow()

            DockDropCard(emphasized: emphasizesDockDrop)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }
}

private struct GuideStepCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.headline.weight(.semibold))

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct GuideArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }
}

private struct DockDropCard: View {
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottom) {
                HStack(spacing: -10) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(index == 0 ? 0.9 : 0.55),
                                        Color.accentColor.opacity(index == 0 ? 0.55 : 0.3)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 42, height: 42)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(.white.opacity(0.24))
                            )
                            .offset(y: index == 0 ? -8 : 0)
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    }
                }

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.18))
                    )
                    .offset(y: 22)
            }
            .frame(height: 86)

            Text("Drag to the Dock")
                .font(.headline.weight(.semibold))

            Text(emphasized
                ? "Pick any Poplet here and drag it straight into the Dock to pin it."
                : "When your Pops show up here, drag the Poplets you want into the Dock."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
