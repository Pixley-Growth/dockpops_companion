import AppKit
import Observation
import SwiftUI

/// Shared layout metrics for the Companion window.
/// Keep window sizing, browser sizing, and AppKit grid geometry in one place so
/// visual tuning stays surgical instead of being spread across multiple files.
enum CompanionLayout {
    enum Window {
        // SACRED CODE — window sizing. See the full SACRED block in
        // DockPopsCompanionApp.swift. The window is resizable; what is fixed is
        // its MINIMUM (`minSize`, applied as a hard `.frame` floor, never
        // derived from content). `defaultSize` opens tall enough to show all
        // 20 Pops (4 rows of 5) on a normal display and is clamped to the
        // screen on smaller / scaled ones, where the grid scrolls instead.
        static let defaultSize = NSSize(width: 720, height: 880)
        static let minSize = NSSize(width: 560, height: 480)
    }

    enum Content {
        static let outerPadding: CGFloat = 28
        static let sectionSpacing: CGFloat = 16
        static let titleSpacing: CGFloat = 8
        static let guideWidth: CGFloat = 720
        static let cardPadding: CGFloat = 24
        static let cardCornerRadius: CGFloat = 24
    }

    enum Grid {
        static let itemSize = NSSize(width: 112, height: 122)
        static let minimumInteritemSpacing: CGFloat = 14
        static let minimumLineSpacing: CGFloat = 18
        static let sectionInsets = NSEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
    }
}

struct ContentView: View {
    @Bindable var model: CompanionModel
    @State private var selectedPopletIDs: Set<UUID> = []

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            screenContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.hasSharedFolderAccess {
                    Button(primaryActionTitle) {
                        Task {
                            await runPrimaryAction()
                        }
                    }
                    .disabled(model.isRefreshing || primaryActionDisabled)
                }
            }
        }
    }

    private var screenContent: some View {
        Group {
            switch model.screenState {
            case .launching:
                launchStateView
            case .sharedAccess:
                connectStateView
            case .waitingForMetadata:
                waitingForDockPopsStateView
            case .empty:
                emptyPopsStateView
            case .ready:
                readyPopletsStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var readyPopletsStateView: some View {
        ReadyPopletsStateView(poplets: model.poplets, selection: $selectedPopletIDs)
            .onChange(of: model.poplets.map(\.id)) { _, ids in
                let validIDs = Set(ids)
                selectedPopletIDs = selectedPopletIDs.intersection(validIDs)
            }
    }

    private var launchStateView: some View {
        LaunchStateView()
    }

    private var connectStateView: some View {
        SharedAccessStateView(
            title: model.statusTitle,
            message: model.statusMessage,
            actionTitle: sharedAccessActionTitle,
            dockPopsFound: model.dockPopsFound,
            isBusy: model.isRefreshing,
            onPrimaryAction: {
                Task {
                    await runPrimaryAction()
                }
            },
            onOpenDockPops: {
                model.openDockPops()
            }
        )
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
                .frame(maxWidth: CompanionLayout.Content.guideWidth)
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
                .frame(maxWidth: CompanionLayout.Content.guideWidth)
                .padding(.top, 8)
        }
    }

    private var primaryActionTitle: String {
        model.isRefreshing ? "Refreshing…" : "Refresh"
    }

    private var sharedAccessActionTitle: String {
        model.needsSharedAccessWarmup ? "Continue" : "Allow Access"
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

private struct ReadyPopletsStateView: View {
    let poplets: [PopletStatus]
    @Binding var selection: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: CompanionLayout.Content.sectionSpacing) {
            CompanionTitleBlock(
                title: "DockPops Companion",
                message: """
                You can drag as many of the icons below to your Dock. Any changes or Pops you add on the main app will show up here.

                Refresh syncs poplet files and icons. Open poplets may need a quick relaunch to fully update.
                """
            )

            // The grid fills the leftover height of the FIXED window and
            // scrolls internally (NSScrollView) if Pops ever exceed 20. It can
            // no longer inflate the window — the window is hard-pinned to
            // CompanionLayout.Window.fixedSize. See SACRED block in the app file.
            PopletFinderGridView(poplets: poplets, selection: $selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(CompanionLayout.Content.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LaunchStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("Looking for DockPops…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(CompanionLayout.Content.outerPadding)
    }
}

private struct SharedAccessStateView: View {
    let title: String
    let message: String
    let actionTitle: String
    let dockPopsFound: Bool
    let isBusy: Bool
    let onPrimaryAction: () -> Void
    let onOpenDockPops: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 28)

            Image(systemName: "hand.raised.square")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 92, height: 92)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )

            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 700)

            if isBusy {
                // After a grant, the first sync runs for several seconds while
                // this screen is still up. Show progress so the grant doesn't
                // look like it failed — and so there is no button to re-click.
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    Button(actionTitle, action: onPrimaryAction)
                        .buttonStyle(.borderedProminent)

                    if dockPopsFound {
                        Button("Open DockPops", action: onOpenDockPops)
                            .buttonStyle(.bordered)
                    }
                }
            }

            if dockPopsFound {
                WorkflowGuideView(showsAccessStep: true, emphasizesDockDrop: false)
                    .frame(maxWidth: CompanionLayout.Content.guideWidth)
                    .padding(.top, 8)
            }

            Spacer(minLength: 20)
        }
        .padding(CompanionLayout.Content.outerPadding)
        .frame(maxWidth: .infinity)
    }
}

private struct CompanionTitleBlock: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: CompanionLayout.Content.titleSpacing) {
            Text(title)
                .font(.system(size: 32, weight: .bold))

            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CompanionSurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: CompanionLayout.Content.cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: CompanionLayout.Content.cardCornerRadius,
                    style: .continuous
                )
                .strokeBorder(.white.opacity(0.08))
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CompanionLayout.Content.cardCornerRadius,
                    style: .continuous
                )
            )
    }
}

private struct WorkflowGuideView: View {
    var showsAccessStep = false
    var emphasizesDockDrop = true

    var body: some View {
        CompanionSurfaceCard {
            HStack(alignment: .center, spacing: 14) {
                if showsAccessStep {
                    GuideStepCard(
                        symbol: "folder.fill",
                        title: "Open and Allow",
                        detail: "The DockPops folder opens already selected, so you can just click Allow."
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
        }
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
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

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

            Text(
                emphasized
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
