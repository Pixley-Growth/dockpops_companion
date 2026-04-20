import AppKit
import SwiftUI

@MainActor
struct PopletFinderGridView: NSViewRepresentable {
    let poplets: [PopletStatus]
    @Binding var selection: Set<UUID>

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var parent: PopletFinderGridView
        let scrollView: NSScrollView
        let collectionView: NSCollectionView
        private let iconCache = NSCache<NSString, NSImage>()

        init(parent: PopletFinderGridView) {
            self.parent = parent

            let layout = NSCollectionViewFlowLayout()
            layout.itemSize = CompanionLayout.Grid.itemSize
            layout.minimumInteritemSpacing = CompanionLayout.Grid.minimumInteritemSpacing
            layout.minimumLineSpacing = CompanionLayout.Grid.minimumLineSpacing
            layout.sectionInset = CompanionLayout.Grid.sectionInsets

            let collectionView = NSCollectionView()
            collectionView.collectionViewLayout = layout
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = true
            collectionView.backgroundColors = [.clear]
            collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)

            self.collectionView = collectionView

            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.documentView = collectionView
            self.scrollView = scrollView

            super.init()

            collectionView.delegate = self
            collectionView.dataSource = self
            collectionView.register(
                PopletCollectionItem.self,
                forItemWithIdentifier: PopletCollectionItem.reuseIdentifier
            )
        }

        // MARK: - Data Reload

        func reloadData() {
            iconCache.removeAllObjects()
            collectionView.reloadData()
            syncSelectionFromSwiftUI()
        }

        // MARK: - NSCollectionViewDataSource

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.poplets.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: PopletCollectionItem.reuseIdentifier,
                for: indexPath
            )

            guard
                let popletItem = item as? PopletCollectionItem,
                parent.poplets.indices.contains(indexPath.item)
            else {
                return item
            }

            let poplet = parent.poplets[indexPath.item]
            popletItem.configure(
                poplet: poplet,
                image: icon(for: poplet)
            )
            return popletItem
        }

        // MARK: - Selection Sync

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToSwiftUI()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToSwiftUI()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> (any NSPasteboardWriting)? {
            guard parent.poplets.indices.contains(indexPath.item) else { return nil }
            let url = parent.poplets[indexPath.item].popletURL as NSURL
            return url
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            canDragItemsAt indexPaths: Set<IndexPath>,
            with event: NSEvent
        ) -> Bool {
            !indexPaths.isEmpty
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = indexPaths.count > 1 ? .stack : .none
        }

        private func syncSelectionToSwiftUI() {
            let selectedIDs: Set<UUID> = Set(
                collectionView.selectionIndexPaths.compactMap { indexPath in
                    guard parent.poplets.indices.contains(indexPath.item) else { return nil }
                    return parent.poplets[indexPath.item].id
                }
            )

            if selectedIDs != parent.selection {
                parent.selection = selectedIDs
            }
        }

        /// SwiftUI remains the source of truth for selection, but AppKit owns the
        /// live selection set on the collection view. This bridge keeps the two in
        /// sync without causing redundant deselect/select churn on every update.
        private func syncSelectionFromSwiftUI() {
            let desiredSelection: Set<IndexPath> = Set(
                parent.poplets.enumerated().compactMap { offset, poplet in
                    parent.selection.contains(poplet.id) ? IndexPath(item: offset, section: 0) : nil
                }
            )

            guard desiredSelection != collectionView.selectionIndexPaths else { return }

            collectionView.deselectAll(nil)
            if !desiredSelection.isEmpty {
                collectionView.selectItems(at: desiredSelection, scrollPosition: [])
            }
        }

        // MARK: - Icon Cache

        private func icon(for poplet: PopletStatus) -> NSImage {
            let key = iconCacheKey(for: poplet)
            if let cached = iconCache.object(forKey: key) {
                return cached
            }

            let image = loadIconImage(for: poplet)
            image.size = NSSize(width: 256, height: 256)
            iconCache.setObject(image, forKey: key)
            return image
        }

        private func iconCacheKey(for poplet: PopletStatus) -> NSString {
            let iconURL = poplet.popletURL
                .appending(path: "Contents", directoryHint: .isDirectory)
                .appending(path: "Resources", directoryHint: .isDirectory)
                .appending(path: "AppIcon.icns")

            if let values = try? iconURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                let timestamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                let size = values.fileSize ?? 0
                return "\(poplet.popletURL.path)#\(timestamp)#\(size)" as NSString
            }

            return poplet.popletURL.path as NSString
        }

        private func loadIconImage(for poplet: PopletStatus) -> NSImage {
            let iconURL = poplet.popletURL
                .appending(path: "Contents", directoryHint: .isDirectory)
                .appending(path: "Resources", directoryHint: .isDirectory)
                .appending(path: "AppIcon.icns")

            if let image = NSImage(contentsOf: iconURL) {
                return image
            }

            return NSWorkspace.shared.icon(forFile: poplet.popletURL.path)
        }
    }
}

@MainActor
private final class PopletCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PopletCollectionItem")

    private let iconHolder = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        self.imageView = iconView

        iconHolder.translatesAutoresizingMaskIntoConstraints = false
        iconHolder.wantsLayer = true
        iconHolder.layer?.cornerRadius = 12
        iconHolder.layer?.cornerCurve = .continuous
        iconHolder.layer?.borderWidth = 1
        iconHolder.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        iconHolder.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 2
        titleField.cell?.wraps = true

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .systemFont(ofSize: 11, weight: .medium)
        statusField.alignment = .center
        statusField.lineBreakMode = .byTruncatingTail
        statusField.textColor = .secondaryLabelColor

        view.addSubview(iconHolder)
        iconHolder.addSubview(iconView)
        view.addSubview(titleField)
        view.addSubview(statusField)

        NSLayoutConstraint.activate([
            iconHolder.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            iconHolder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconHolder.widthAnchor.constraint(equalToConstant: 72),
            iconHolder.heightAnchor.constraint(equalToConstant: 72),

            iconView.centerXAnchor.constraint(equalTo: iconHolder.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconHolder.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            titleField.topAnchor.constraint(equalTo: iconHolder.bottomAnchor, constant: 10),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),

            statusField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            statusField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            statusField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            statusField.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6),
        ])

        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet {
            updateSelectionAppearance()
        }
    }

    func configure(poplet: PopletStatus, image: NSImage) {
        imageView?.image = image
        titleField.stringValue = poplet.popName

        switch poplet.iconSource {
        case .popComposite:
            statusField.stringValue = ""
            statusField.isHidden = true
        case .dockPopsApp:
            statusField.stringValue = "Waiting for icon"
            statusField.textColor = .secondaryLabelColor
            statusField.isHidden = false
        case .generic:
            statusField.stringValue = "Icon unavailable"
            statusField.textColor = .systemOrange
            statusField.isHidden = false
        }
    }

    private func updateSelectionAppearance() {
        if isSelected {
            view.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55).cgColor
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.selectedControlColor.withAlphaComponent(0.9).cgColor
        } else {
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.clear.cgColor
        }
    }
}
