//
//  ContentView.swift
//  Image Resize
//
//  Created by Angel Rodriguez on 10/12/25.
//


import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct ImageDoc: Identifiable, Hashable {
    let id = UUID()
    var url: URL?
    var name: String
    var original: NSImage
    /// Logical size used for preview/resizing the focused image
    var displaySize: CGSize
    /// Per-image overlay opacity (only used in overlay mode)
    var overlayOpacity: Double = 1.0
    /// Position for drag-to-move functionality
    var position: CGPoint = .zero
    /// Canvas size for canvas resize mode (the visible frame size around the image)
    var canvasSize: CGSize?
    /// Image offset within the canvas (for centering/positioning)
    var imageOffset: CGPoint = .zero
    /// Original size when first loaded (for modification tracking)
    var originalSize: CGSize
    /// Border color for overlay mode (each image gets a different color)
    var borderColor: Color
    
    var aspectRatio: CGFloat {
        let s = original.size
        return s.height == 0 ? 1 : s.width / s.height
    }
    
    /// Returns true if the image has been modified from its original state
    var isModified: Bool {
        // Check if display size differs from original size (with small tolerance for floating point precision)
        let sizeTolerance: CGFloat = 0.1
        let sizeChanged = abs(displaySize.width - originalSize.width) > sizeTolerance ||
                         abs(displaySize.height - originalSize.height) > sizeTolerance
        
        // Check if position has been moved from center (with tolerance)
        let centerPosition = CGPoint(x: 400, y: 300)
        let positionTolerance: CGFloat = 1.0
        let positionChanged = abs(position.x - centerPosition.x) > positionTolerance ||
                             abs(position.y - centerPosition.y) > positionTolerance
        
        // Check if opacity has been changed from default
        let opacityChanged = abs(overlayOpacity - 1.0) > 0.01
        
        // Check if canvas resize has been used
        let canvasChanged = canvasSize != nil
        
        return sizeChanged || positionChanged || opacityChanged || canvasChanged
    }
}

// Persistent model for history items
struct PersistentImageDoc: Codable {
    let url: URL?
    let name: String
    let displaySize: CGSize
    let originalSize: CGSize
    let lastAccessed: Date
    let imageData: Data? // Store the actual image data
    let borderColorData: Data? // Store the border color as data
    
    init(from doc: ImageDoc) {
        self.url = doc.url
        self.name = doc.name
        self.displaySize = doc.displaySize
        self.originalSize = doc.originalSize
        self.lastAccessed = Date()
        
        // Try to get image data from the original image
        if let tiffData = doc.original.tiffRepresentation {
            self.imageData = tiffData
        } else {
            self.imageData = nil
        }
        
        // Store border color as data (we'll use a simple approach with RGB values)
        let color = doc.borderColor
        let nsColor = NSColor(color)
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        let colorData = Data([
            UInt8(rgb.redComponent * 255),
            UInt8(rgb.greenComponent * 255),
            UInt8(rgb.blueComponent * 255)
        ])
        self.borderColorData = colorData
    }
    
    func toImageDoc() -> ImageDoc? {
        var image: NSImage?
        
        // First try to load from stored image data
        if let data = imageData {
            image = NSImage(data: data)
        }
        
        // If that fails and we have a URL, try loading from URL
        if image == nil, let url = url {
            image = NSImage(contentsOf: url)
        }
        
        // If we still can't load the image, return nil
        guard let img = image else { 
            print("Failed to load image from both data and URL: \(name)")
            return nil 
        }
        
        // Restore border color from data
        let borderColor: Color
        if let colorData = borderColorData, colorData.count >= 3 {
            let red = Double(colorData[0]) / 255.0
            let green = Double(colorData[1]) / 255.0
            let blue = Double(colorData[2]) / 255.0
            borderColor = Color(red: red, green: green, blue: blue)
        } else {
            // Default to red if no color data
            borderColor = .red
        }
        
        return ImageDoc(
            url: url,
            name: name,
            original: img,
            displaySize: displaySize,
            position: CGPoint(x: 400, y: 300),
            originalSize: originalSize,
            borderColor: borderColor
        )
    }
}

// MARK: - ViewModel

@MainActor
final class ImageWorkbench: ObservableObject {
    @Published var docs: [ImageDoc] = []
    @Published var focusedID: ImageDoc.ID? = nil
    @Published var layout: LayoutMode = .sideBySide
    @Published var keepAspect = true
    @Published var canvasResizeMode = false {
        didSet {
            // When switching back to image resize mode, "bake" the canvas size into the display size
            if !canvasResizeMode {
                bakeCanvasSizesIntoDisplaySizes()
            }
        }
    }
    @Published var showBorders = false
    @Published var history: [ImageDoc] = []
    @Published var dragOffset: CGSize = .zero
    @Published var isDragging: Bool = false
    @Published var isRenaming: Bool = false
    @Published var renameText: String = ""
    
    init() {
        loadHistory()
    }
    
    enum LayoutMode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by side"
        case overlay = "Overlay"
        var id: String { rawValue }
    }
    
    // MARK: File I/O
    func openImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .webP, .rawImage]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] resp in
            guard resp == .OK else { return }
            Task { @MainActor in
                await self?.load(urls: panel.urls)
            }
        }
    }
    
    func load(urls: [URL]) async {
        var newDocs: [ImageDoc] = []
        for url in urls {
            if let img = NSImage(contentsOf: url) {
                let s = img.size
                let start = CGSize(width: min(800, s.width), height: min(800 * (s.height / max(s.width, 1)), s.height))
                let centerPosition = CGPoint(x: 400, y: 300) // Default center position
                let borderColor = generateBorderColor(for: newDocs.count)
                let doc = ImageDoc(url: url, name: url.lastPathComponent, original: img, displaySize: start, position: centerPosition, originalSize: s, borderColor: borderColor)
                newDocs.append(doc)
                addToHistory(doc)
            }
        }
        if !newDocs.isEmpty {
            docs.append(contentsOf: newDocs)
            if focusedID == nil { focusedID = docs.first?.id }
        }
    }
    
    func importDropped(items: [NSItemProvider]) {
        let utis: [UTType] = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .webP, .rawImage, .image]
        for provider in items {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: utis.map(\.identifier).first!) { data, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    Task { @MainActor in
                        let s = img.size
                        let start = CGSize(width: min(800, s.width), height: min(800 * (s.height / max(s.width, 1)), s.height))
                        let centerPosition = CGPoint(x: 400, y: 300) // Default center position
                        let borderColor = self.generateBorderColor(for: self.docs.count)
                        let doc = ImageDoc(url: nil, name: "Dropped Image", original: img, displaySize: start, position: centerPosition, originalSize: s, borderColor: borderColor)
                        self.docs.append(doc)
                        self.addToHistory(doc)
                        if self.focusedID == nil { self.focusedID = doc.id }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let urlData = item as? Data,
                          let url = URL(dataRepresentation: urlData, relativeTo: nil) else { return }
                    Task { @MainActor in
                        await self.load(urls: [url])
                    }
                }
            }
        }
    }
    
    func saveFocused(as format: SaveFormat) {
        guard let focused = docs.first(where: { $0.id == focusedID }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.uti]
        panel.canCreateDirectories = true
        // Use the current name (which may have been renamed) instead of the original filename
        // Strip any existing extension before adding the new one
        let base = URL(fileURLWithPath: focused.name).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = base + format.suggestedExtension
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            let target = focused.displaySize
            guard let resized = focused.original.resized(to: target, keepAspect: self.keepAspect),
                  let data = resized.data(for: format) else { return }
            try? data.write(to: dest)
        }
    }
    
    func saveAllModified(as format: SaveFormat) {
        // Filter to only modified images
        let modifiedDocs = docs.filter { $0.isModified }
        
        guard !modifiedDocs.isEmpty else { 
            print("No modified images to save")
            return 
        }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"
        panel.message = "Choose a folder to save \(modifiedDocs.count) modified image\(modifiedDocs.count == 1 ? "" : "s")"
        
        panel.begin { resp in
            guard resp == .OK, let folderURL = panel.url else { return }
            
            Task { @MainActor in
                var savedCount = 0
                var failedCount = 0
                
                for doc in modifiedDocs {
                    // Use the current name (which may have been renamed) instead of the original filename
                    // Strip any existing extension before adding the new one
                    let baseName = URL(fileURLWithPath: doc.name).deletingPathExtension().lastPathComponent
                    let fileName = baseName + format.suggestedExtension
                    let fileURL = folderURL.appendingPathComponent(fileName)
                    
                    let target = doc.displaySize
                    guard let resized = doc.original.resized(to: target, keepAspect: self.keepAspect),
                          let data = resized.data(for: format) else {
                        failedCount += 1
                        continue
                    }
                    
                    do {
                        try data.write(to: fileURL)
                        savedCount += 1
                    } catch {
                        print("Failed to save \(fileName): \(error)")
                        failedCount += 1
                    }
                }
                
                // Show completion message
                let message = "Saved \(savedCount) modified image\(savedCount == 1 ? "" : "s")"
                let detailMessage = failedCount > 0 ? " (\(failedCount) failed)" : ""
                print(message + detailMessage)
                
                // You could show an alert here if you want user feedback
                // For now, we'll just print to console
            }
        }
    }
    
    enum SaveFormat: String, CaseIterable, Identifiable {
        case png = "PNG", jpeg = "JPEG"
        var id: String { rawValue }
        var uti: UTType { self == .png ? .png : .jpeg }
        var suggestedExtension: String { self == .png ? ".png" : ".jpg" }
    }
    
    // MARK: Focus helpers
    func focus(_ id: ImageDoc.ID) { focusedID = id }
    func isFocused(_ doc: ImageDoc) -> Bool { focusedID == doc.id }
    
    // MARK: Rename functionality
    func startRenaming(_ doc: ImageDoc) {
        isRenaming = true
        renameText = doc.name
    }
    
    func confirmRename() {
        guard let focusedID = focusedID,
              let idx = docs.firstIndex(where: { $0.id == focusedID }),
              !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelRename()
            return
        }
        
        docs[idx].name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        renameText = ""
    }
    
    func cancelRename() {
        isRenaming = false
        renameText = ""
    }
    
    // MARK: Close functionality
    func closeImage(_ id: ImageDoc.ID) {
        docs.removeAll { $0.id == id }
        if focusedID == id {
            focusedID = docs.first?.id
        }
    }
    
    func closeAllImages() {
        docs.removeAll()
        focusedID = nil
    }
    
    // MARK: Size updates
    func updateSize(for id: ImageDoc.ID, width: CGFloat? = nil, height: CGFloat? = nil) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        var d = docs[idx]
        var newSize = d.displaySize
        if keepAspect {
            let ar = d.aspectRatio
            if let w = width {
                newSize.width = max(1, w)
                newSize.height = max(1, w / max(ar, 0.0001))
            } else if let h = height {
                newSize.height = max(1, h)
                newSize.width = max(1, h * ar)
            }
        } else {
            if let w = width { newSize.width = max(1, w) }
            if let h = height { newSize.height = max(1, h) }
        }
        d.displaySize = newSize
        docs[idx] = d
    }
    
    func setOpacity(for id: ImageDoc.ID, _ value: Double) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].overlayOpacity = value
    }
    
    // MARK: Position updates
    func updatePosition(for id: ImageDoc.ID, _ position: CGPoint) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].position = position
    }
    
    func updateDragState(offset: CGSize, isDragging: Bool, startPosition: CGPoint = .zero) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] 🔄 UPDATE DRAG STATE - Old offset: \(self.dragOffset), New offset: \(offset), isDragging: \(isDragging)")
        self.dragOffset = offset
        self.isDragging = isDragging
      
    }
    
    // MARK: Corner resize
    func cornerResize(for id: ImageDoc.ID, corner: ResizeCorner, delta: CGSize) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        var doc = docs[idx]
        var newSize = doc.displaySize
        
        switch corner {
        case .topLeft:
            newSize.width = max(50, newSize.width - delta.width)
            newSize.height = max(50, newSize.height - delta.height)
        case .topRight:
            newSize.width = max(50, newSize.width + delta.width)
            newSize.height = max(50, newSize.height - delta.height)
        case .bottomLeft:
            newSize.width = max(50, newSize.width - delta.width)
            newSize.height = max(50, newSize.height + delta.height)
        case .bottomRight:
            newSize.width = max(50, newSize.width + delta.width)
            newSize.height = max(50, newSize.height + delta.height)
        }
        
        if keepAspect {
            let ar = doc.aspectRatio
            if newSize.width / max(newSize.height, 1) > ar {
                newSize.width = newSize.height * ar
            } else {
                newSize.height = newSize.width / max(ar, 0.0001)
            }
        }
        
        doc.displaySize = newSize
        docs[idx] = doc
    }
    
    // MARK: Edge resize (for canvas mode)
    func edgeResize(for id: ImageDoc.ID, edge: ResizeEdge, delta: CGSize) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        var doc = docs[idx]
        
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] 🔧 EDGE RESIZE CALLED - Edge: \(edge), Delta: \(delta)")
        
        // Initialize canvas size if not set (first time in canvas resize mode)
        if doc.canvasSize == nil {
            doc.canvasSize = doc.displaySize
            // Center the image in the canvas initially
            doc.imageOffset = .zero
        }
        
        var canvasSize = doc.canvasSize!
        var imageOffset = doc.imageOffset
        var position = doc.position
        
        // Like Procreate: the image stays at its fixed visual position,
        // When the canvas grows, it grows from center. We need to:
        // 1. Move the canvas position to compensate for center-based growth
        // 2. Adjust image offset within canvas to maintain visual position
        switch edge {
        case .top:
            // Drag up (negative delta) = expand canvas upward
            let oldHeight = canvasSize.height
            canvasSize.height = max(50, canvasSize.height - delta.height)
            let actualDelta = canvasSize.height - oldHeight
            // Move canvas up to counter the growth (negative delta means growing up)
            position.y -= actualDelta / 2
            // Also adjust image offset to compensate for canvas growth from top
            imageOffset.y += actualDelta
        case .bottom:
            // Drag down (positive delta) = expand canvas downward
            let oldHeight = canvasSize.height
            canvasSize.height = max(50, canvasSize.height + delta.height)
            let actualDelta = canvasSize.height - oldHeight
            // Canvas grows from center, so move canvas position by half
            position.y += actualDelta / 2
        case .left:
            // Drag left (negative delta) = expand canvas leftward
            let oldWidth = canvasSize.width
            canvasSize.width = max(50, canvasSize.width - delta.width)
            let actualDelta = canvasSize.width - oldWidth
            // Move canvas left to counter the growth (negative delta means growing left)
            position.x -= actualDelta / 2
            // Also adjust image offset to compensate for canvas growth from left
            imageOffset.x += actualDelta
        case .right:
            // Drag right (positive delta) = expand canvas rightward
            let oldWidth = canvasSize.width
            canvasSize.width = max(50, canvasSize.width + delta.width)
            let actualDelta = canvasSize.width - oldWidth
            // Canvas grows from center, so move canvas position by half
            position.x += actualDelta / 2
        }
        
        // Don't apply aspect ratio constraints in canvas resize mode
        // Canvas resize should allow free-form resizing like Procreate
        if keepAspect && !canvasResizeMode {
            let ar = doc.aspectRatio
            if canvasSize.width / max(canvasSize.height, 1) > ar {
                canvasSize.width = canvasSize.height * ar
            } else {
                canvasSize.height = canvasSize.width / max(ar, 0.0001)
            }
        }
        
        print("[\(timestamp)] 🔧 CANVAS SIZE CHANGE - Old: \(doc.canvasSize?.width ?? 0)x\(doc.canvasSize?.height ?? 0) -> New: \(canvasSize.width)x\(canvasSize.height)")
        
        doc.canvasSize = canvasSize
        doc.imageOffset = imageOffset
        doc.position = position
        docs[idx] = doc
    }
    
    
    func resetPosition(for id: ImageDoc.ID) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].position = CGPoint(x: 400, y: 300) // Reset to center
    }
    
    // MARK: Canvas increment/decrement methods
    func incrementCanvasSize(for id: ImageDoc.ID, edge: ResizeEdge) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        var doc = docs[idx]
        
        // Initialize canvas size if not set
        if doc.canvasSize == nil {
            doc.canvasSize = doc.displaySize
            doc.imageOffset = .zero
        }
        
        var canvasSize = doc.canvasSize!
        var imageOffset = doc.imageOffset
        var position = doc.position
        
        // Increment by 1 pixel for the specified edge
        switch edge {
        case .top:
            let oldHeight = canvasSize.height
            canvasSize.height = max(50, canvasSize.height + 1)
            let actualDelta = canvasSize.height - oldHeight
            position.y -= actualDelta / 2
            imageOffset.y += actualDelta
        case .bottom:
            let oldHeight = canvasSize.height
            canvasSize.height = max(50, canvasSize.height + 1)
            let actualDelta = canvasSize.height - oldHeight
            position.y += actualDelta / 2
        case .left:
            let oldWidth = canvasSize.width
            canvasSize.width = max(50, canvasSize.width + 1)
            let actualDelta = canvasSize.width - oldWidth
            position.x -= actualDelta / 2
            imageOffset.x += actualDelta
        case .right:
            let oldWidth = canvasSize.width
            canvasSize.width = max(50, canvasSize.width + 1)
            let actualDelta = canvasSize.width - oldWidth
            position.x += actualDelta / 2
        }
        
        doc.canvasSize = canvasSize
        doc.imageOffset = imageOffset
        doc.position = position
        docs[idx] = doc
    }
    
    func decrementCanvasSize(for id: ImageDoc.ID, edge: ResizeEdge) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        var doc = docs[idx]
        
        // Initialize canvas size if not set
        if doc.canvasSize == nil {
            doc.canvasSize = doc.displaySize
            doc.imageOffset = .zero
        }
        
        var canvasSize = doc.canvasSize!
        var imageOffset = doc.imageOffset
        var position = doc.position
        
        // Decrement by 1 pixel for the specified edge
        switch edge {
        case .top:
            let oldHeight = canvasSize.height
            canvasSize.height = max(50, canvasSize.height - 1)
            let actualDelta = canvasSize.height - oldHeight
            position.y -= actualDelta / 2
            imageOffset.y += actualDelta
        case .bottom:
            let oldHeight = canvasSize.height
            canvasSize.height = max(50, canvasSize.height - 1)
            let actualDelta = canvasSize.height - oldHeight
            position.y += actualDelta / 2
        case .left:
            let oldWidth = canvasSize.width
            canvasSize.width = max(50, canvasSize.width - 1)
            let actualDelta = canvasSize.width - oldWidth
            position.x -= actualDelta / 2
            imageOffset.x += actualDelta
        case .right:
            let oldWidth = canvasSize.width
            canvasSize.width = max(50, canvasSize.width - 1)
            let actualDelta = canvasSize.width - oldWidth
            position.x += actualDelta / 2
        }
        
        doc.canvasSize = canvasSize
        doc.imageOffset = imageOffset
        doc.position = position
        docs[idx] = doc
    }
    
    func bakeCanvasSizesIntoDisplaySizes() {
        // When switching from canvas resize to image resize mode,
        // "bake" the canvas size into the display size by creating a new composite image
        for idx in docs.indices {
            if let canvasSize = docs[idx].canvasSize {
                let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("[\(timestamp)] 🔄 BAKING CANVAS - Image: \(docs[idx].name)")
                print("[\(timestamp)]   Old display size: \(docs[idx].displaySize.width)x\(docs[idx].displaySize.height)")
                print("[\(timestamp)]   Canvas size: \(canvasSize.width)x\(canvasSize.height)")
                print("[\(timestamp)]   Image offset: \(docs[idx].imageOffset.x)x\(docs[idx].imageOffset.y)")
                
                // Create a new image with the canvas size that includes the original image with padding
                if let compositeImage = createCompositeImage(
                    original: docs[idx].original,
                    displaySize: docs[idx].displaySize,
                    canvasSize: canvasSize,
                    imageOffset: docs[idx].imageOffset
                ) {
                    print("[\(timestamp)]   Created composite image: \(compositeImage.size.width)x\(compositeImage.size.height)")
                    
                    // Replace the original image with the composite
                    docs[idx].original = compositeImage
                    // Set the display size to match the canvas size
                    docs[idx].displaySize = canvasSize
                    
                    print("[\(timestamp)]   New display size: \(docs[idx].displaySize.width)x\(docs[idx].displaySize.height)")
                } else {
                    print("[\(timestamp)]   Failed to create composite image, falling back to size change only")
                    docs[idx].displaySize = canvasSize
                }
                
                // Clear the canvas-specific properties since we're now in image resize mode
                docs[idx].canvasSize = nil
                docs[idx].imageOffset = .zero
            }
        }
    }
    
    private func createCompositeImage(original: NSImage, displaySize: CGSize, canvasSize: CGSize, imageOffset: CGPoint) -> NSImage? {
        // Create a new image with the canvas size
        let composite = NSImage(size: canvasSize)
        
        composite.lockFocus()
        defer { composite.unlockFocus() }
        
        // Fill with transparent background
        NSColor.clear.set()
        NSRect(origin: .zero, size: canvasSize).fill()
        
        // macOS uses bottom-left origin, but SwiftUI uses top-left
        // We need to flip the Y coordinate to match the visual representation
        // When we add padding to the top in SwiftUI (negative imageOffset.y),
        // it should appear at the top in the final image
        let flippedY = canvasSize.height - displaySize.height - imageOffset.y
        
        // Draw the original image at the offset position with the display size
        let destRect = NSRect(
            x: imageOffset.x,
            y: flippedY,
            width: displaySize.width,
            height: displaySize.height
        )
        
        NSGraphicsContext.current?.imageInterpolation = .high
        original.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        
        return composite
    }
    
    // MARK: History management
    func addToHistory(_ doc: ImageDoc) {
        print("Adding to history: \(doc.name)")
        
        // Remove any existing instance of this image (by URL or name if no URL)
        let initialCount = history.count
        history.removeAll { existingDoc in
            if let docURL = doc.url, let existingURL = existingDoc.url {
                return docURL == existingURL
            } else {
                return doc.name == existingDoc.name
            }
        }
        
        if history.count < initialCount {
            print("Removed duplicate from history")
        }
        
        // Add to beginning of history
        history.insert(doc, at: 0)
        
        // Keep only last 11 items
        if history.count > 11 {
            history = Array(history.prefix(11))
        }
        
        print("History now has \(history.count) items")
        
        // Save to persistent storage
        saveHistory()
    }
    
    func openFromHistory(_ doc: ImageDoc) {
        // Check if this image is already open
        let isAlreadyOpen = docs.contains { existingDoc in
            if let docURL = doc.url, let existingURL = existingDoc.url {
                return docURL == existingURL
            } else {
                return doc.name == existingDoc.name
            }
        }
        
        if !isAlreadyOpen {
            // Create a new instance with current timestamp
            let borderColor = generateBorderColor(for: docs.count)
            let newDoc = ImageDoc(
                url: doc.url,
                name: doc.name,
                original: doc.original,
                displaySize: doc.displaySize,
                position: CGPoint(x: 400, y: 300),
                originalSize: doc.originalSize,
                borderColor: borderColor
            )
            docs.append(newDoc)
            focusedID = newDoc.id
        } else {
            // Focus the existing image
            if let existingDoc = docs.first(where: { existingDoc in
                if let docURL = doc.url, let existingURL = existingDoc.url {
                    return docURL == existingURL
                } else {
                    return doc.name == existingDoc.name
                }
            }) {
                focusedID = existingDoc.id
            }
        }
    }
    
    func clearHistory() {
        history.removeAll()
        saveHistory()
    }
    
    // MARK: Persistence
    private let historyKey = "com.pixeltool.imageresize.history"
    
    func saveHistory() {
        print("Saving \(history.count) items to history...")
        print("Using key: \(historyKey)")
        let persistentDocs = history.map { PersistentImageDoc(from: $0) }
        if let data = try? JSONEncoder().encode(persistentDocs) {
            UserDefaults.standard.set(data, forKey: historyKey)
            UserDefaults.standard.synchronize() // Force sync
            print("Successfully saved history to UserDefaults")
            print("Data size: \(data.count) bytes")
        } else {
            print("Failed to encode history data")
        }
    }
    
    func loadHistory() {
        print("Loading history from UserDefaults...")
        print("Using key: \(historyKey)")
        
        guard let data = UserDefaults.standard.data(forKey: historyKey) else {
            print("No history data found in UserDefaults")
            print("Available keys: \(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.contains("history") || $0.contains("Image") })")
            return
        }
        
        guard let persistentDocs = try? JSONDecoder().decode([PersistentImageDoc].self, from: data) else {
            print("Failed to decode history data")
            return
        }
        
        print("Found \(persistentDocs.count) persistent docs")
        
        // Convert persistent docs back to ImageDocs, filtering out any that can't be loaded
        let loadedDocs = persistentDocs.compactMap { persistentDoc in
            let imageDoc = persistentDoc.toImageDoc()
            if imageDoc == nil {
                print("Failed to load image: \(persistentDoc.name)")
            }
            return imageDoc
        }
        
        print("Successfully loaded \(loadedDocs.count) images")
        
        // Sort by last accessed date (most recent first)
        let sortedDocs = loadedDocs.sorted { doc1, doc2 in
            // Since we don't have access to the original lastAccessed date in ImageDoc,
            // we'll maintain the order from the persistent storage
            return true
        }
        
        history = Array(sortedDocs.prefix(11)) // Keep only last 11
        print("Set history to \(history.count) items")
        
        // Save the cleaned history (removes any items that couldn't be loaded)
        if loadedDocs.count != persistentDocs.count {
            print("Cleaning up history - removing \(persistentDocs.count - loadedDocs.count) invalid items")
            saveHistory()
        }
    }
    
    func cleanupHistory() {
        // Remove any history items that can't be loaded (files moved/deleted)
        let validHistory = history.compactMap { doc in
            if let url = doc.url {
                // Check if file still exists
                return FileManager.default.fileExists(atPath: url.path) ? doc : nil
            }
            return doc // Keep items without URLs (like dropped images)
        }
        
        if validHistory.count != history.count {
            history = validHistory
            saveHistory()
        }
    }
    
    
    enum ResizeCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    
    enum ResizeEdge {
        case top, bottom, left, right
    }
    
    // MARK: Border color generation
    private static let borderColors: [Color] = [
        .red, .blue, .green, .orange, .purple, .pink, .yellow, .cyan, .mint, .indigo
    ]
    
    func generateBorderColor(for index: Int) -> Color {
        return ImageWorkbench.borderColors[index % ImageWorkbench.borderColors.count]
    }
    
    // MARK: Restack functionality
    func restackImages() {
        // Move all images to the same center position
        let centerPosition = CGPoint(x: 400, y: 300)
        
        for index in docs.indices {
            docs[index].position = centerPosition
        }
        
        // Shuffle the docs array to randomize the stacking order
        docs.shuffle()
        
        // Update border colors to maintain unique colors for each image
        for (index, _) in docs.enumerated() {
            docs[index].borderColor = generateBorderColor(for: index)
        }
        
        // Keep the same focused image if any
        if let currentFocusedID = focusedID {
            // Find the new index of the focused image after shuffling
            if let newIndex = docs.firstIndex(where: { $0.id == currentFocusedID }) {
                // Move the focused image to the end (top of stack)
                let focusedDoc = docs.remove(at: newIndex)
                docs.append(focusedDoc)
            }
        }
    }
}

// MARK: - App

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var vm: ImageWorkbench
    
    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                ToolbarBar()
                Divider()
                CanvasArea()
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers in
            vm.importDropped(items: providers.map { NSItemProvider(object: $0) })
            return true
        }
    }
}

// Sidebar showing images + inspector
struct Sidebar: View {
    @EnvironmentObject var vm: ImageWorkbench
    
    var body: some View {
        List(selection: Binding(get: {
            vm.focusedID
        }, set: { new in
            if let id = new { vm.focus(id) }
        })) {
            Section("Images") {
                ForEach(vm.docs) { doc in
                    HStack {
                        Thumbnail(image: doc.original)
                        VStack(alignment: .leading) {
                            Text(doc.name).lineLimit(1)
                            Text("\(Int((doc.canvasSize?.width ?? doc.displaySize.width)))×\(Int((doc.canvasSize?.height ?? doc.displaySize.height)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            vm.closeImage(doc.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .opacity(0.7)
                    }
                    .tag(doc.id)
                    .contentShape(Rectangle())
                }
            }
            
            if !vm.history.isEmpty {
                Section("Recent") {
                    ForEach(vm.history) { doc in
                        HStack {
                            Thumbnail(image: doc.original)
                            VStack(alignment: .leading) {
                                Text(doc.name).lineLimit(1)
                                Text("\(Int((doc.canvasSize?.width ?? doc.displaySize.width)))×\(Int((doc.canvasSize?.height ?? doc.displaySize.height)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.openFromHistory(doc)
                        }
                        .contextMenu {
                            Button("Open") {
                                vm.openFromHistory(doc)
                            }
                            Button("Remove from History") {
                                vm.history.removeAll { $0.id == doc.id }
                            }
                        }
                    }
                }
            }
            
            if let focused = vm.docs.first(where: { $0.id == vm.focusedID }) {
                Section("Inspector") {
                    Inspector(doc: focused)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct Thumbnail: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}

struct ToolbarBar: View {
    @EnvironmentObject var vm: ImageWorkbench
    var body: some View {
        VStack(spacing: 8) {
            // Top row: Open button, Layout picker, Lock aspect toggle, and right-aligned controls
            HStack(spacing: 12) {
                Button {
                    vm.openImages()
                } label: {
                    Label("Open", systemImage: "folder.badge.plus")
                }
                Picker("Layout", selection: $vm.layout) {
                    ForEach(ImageWorkbench.LayoutMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Lock aspect", isOn: $vm.keepAspect)
                    .toggleStyle(.switch)
                Spacer()
                if !vm.docs.isEmpty {
                    Button {
                        vm.closeAllImages()
                    } label: {
                        Label("Close All", systemImage: "xmark.circle")
                    }
                }
                if !vm.history.isEmpty {
                    Button {
                        vm.clearHistory()
                    } label: {
                        Label("Clear History", systemImage: "clock.arrow.circlepath")
                    }
                }
                if !vm.docs.isEmpty {
                    Menu {
                        if vm.focusedID != nil {
                            Section("Save Focused") {
                                Button("PNG") { vm.saveFocused(as: .png) }
                                Button("JPEG") { vm.saveFocused(as: .jpeg) }
                            }
                        }
                        let modifiedCount = vm.docs.filter { $0.isModified }.count
                        if modifiedCount > 0 {
                            Section("Save All Modified (\(modifiedCount))") {
                                Button("PNG") { vm.saveAllModified(as: .png) }
                                Button("JPEG") { vm.saveAllModified(as: .jpeg) }
                            }
                        }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
            }
            
            // Bottom row: Overlay-specific controls (when in overlay mode)
            if vm.layout == .overlay {
                HStack(spacing: 12) {
                    Toggle("Canvas Resize", isOn: $vm.canvasResizeMode)
                        .toggleStyle(.switch)
                    Toggle("Show Borders", isOn: $vm.showBorders)
                        .toggleStyle(.switch)
                    Button {
                        vm.restackImages()
                    } label: {
                        Label("Restack", systemImage: "square.stack.3d.up")
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
    }
}

struct CanvasArea: View {
    @EnvironmentObject var vm: ImageWorkbench
    
    var body: some View {
        Group {
            switch vm.layout {
            case .sideBySide:
                ScrollView([.horizontal, .vertical]) {
                    FlowGrid(docs: vm.docs)
                }
                .padding()
            case .overlay:
                GeometryReader { geo in
                    ZStack {
                        ForEach(vm.docs.sorted { doc1, doc2 in
                            // Put focused image last (on top)
                            if vm.isFocused(doc1) { return false }
                            if vm.isFocused(doc2) { return true }
                            return false
                        }) { doc in
                            DraggableResizableImage(doc: doc, maxSize: geo.size)
                                .opacity(doc.overlayOpacity)
                        }
                        
                        // Position display for focused image
                        if let focusedDoc = vm.docs.first(where: { vm.isFocused($0) }) {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    let livePosition = focusedDoc.position
                                    Text("Position: (\(Int(livePosition.x)), \(Int(livePosition.y)))")
                                        .font(.caption)
                                        .padding(8)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                        .padding(.trailing, 16)
                                        .padding(.bottom, 16)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .animation(.default, value: vm.layout)
        .animation(.none, value: vm.docs.map { $0.position })
    }
}

// Side-by-side flow layout
struct FlowGrid: View {
    @EnvironmentObject var vm: ImageWorkbench
    let docs: [ImageDoc]
    
    var body: some View {
        let rows = [
            GridItem(.adaptive(minimum: 300), spacing: 16)
        ]
        LazyHGrid(rows: rows, spacing: 16) {
            ForEach(docs) { doc in
                VStack {
                    FocusableImage(doc: doc, maxSize: CGSize(width: 600, height: 600))
                    HStack {
                        Text(doc.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(Int((doc.canvasSize?.width ?? doc.displaySize.width)))×\(Int((doc.canvasSize?.height ?? doc.displaySize.height)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(vm.isFocused(doc) ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: vm.isFocused(doc) ? 2 : 1)
                )
                .onTapGesture { vm.focus(doc.id) }
            }
        }
        .padding(10)
    }
}

// An image that can be focused and resized with a pinch (magnification gesture)
struct FocusableImage: View {
    @EnvironmentObject var vm: ImageWorkbench
    let doc: ImageDoc
    let maxSize: CGSize
    
    @State private var liveScale: CGFloat = 1.0
    
    var body: some View {
        let isFocused = vm.isFocused(doc)
        let size = CGSize(width: min(doc.displaySize.width * liveScale, maxSize.width),
                          height: min(doc.displaySize.height * liveScale, maxSize.height))
        
        return Image(nsImage: doc.original)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2)
            )
            .shadow(radius: isFocused ? 8 : 0)
            .onTapGesture { vm.focus(doc.id) }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in liveScale = value }
                    .onEnded { value in
                        let newW = doc.displaySize.width * value
                        vm.updateSize(for: doc.id, width: newW)
                        liveScale = 1.0
                    }
            )
            .contextMenu {
                Button("Focus") { vm.focus(doc.id) }
                Button("Close") { vm.closeImage(doc.id) }
                if vm.layout == .overlay {
                    Slider(value: Binding(
                        get: { doc.overlayOpacity },
                        set: { vm.setOpacity(for: doc.id, $0) }
                    ), in: 0...1) {
                        Text("Opacity")
                    }
                }
            }
            .padding(4)
    }
}

// A draggable and resizable image with corner handles
struct DraggableResizableImage: View {
    @EnvironmentObject var vm: ImageWorkbench
    let doc: ImageDoc
    let maxSize: CGSize
    
    @State private var isResizing: Bool = false
    @State private var resizeCorner: ImageWorkbench.ResizeCorner? = nil
    @State private var resizeStartSize: CGSize = .zero
    @State private var resizeStartPosition: CGPoint = .zero
    @State private var isDragging: Bool = false
    @State private var dragStartPosition: CGPoint = .zero
    
    var body: some View {
        let isFocused = vm.isFocused(doc)
        let currentPosition = doc.position
        
        // Use canvas size only when in canvas resize mode, otherwise use display size
        let frameSize = vm.canvasResizeMode ? (doc.canvasSize ?? doc.displaySize) : doc.displaySize
        
        // Debug logging
        if vm.canvasResizeMode {
            print("🔍 CANVAS SIZE DEBUG - Canvas: \(doc.canvasSize?.width ?? 0)x\(doc.canvasSize?.height ?? 0), Display: \(doc.displaySize.width)x\(doc.displaySize.height), Frame: \(frameSize.width)x\(frameSize.height)")
        }
        
        return ZStack(alignment: .topLeading) {
            // Background for the canvas - checkerboard pattern to show transparency
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(width: frameSize.width, height: frameSize.height)
            
            // The image, positioned within the canvas
            Image(nsImage: doc.original)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: doc.displaySize.width, height: doc.displaySize.height)
                .offset(x: doc.imageOffset.x, y: doc.imageOffset.y)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? Color.accentColor : 
                        (vm.showBorders ? doc.borderColor : .clear), 
                        lineWidth: 2
                    )
            )
            .overlay(
                // Resize handles - corners for normal mode, edges for canvas mode
                Group {
                    if isFocused && !isDragging {
                        if vm.canvasResizeMode {
                            // Edge handles for canvas resize mode
                            ForEach([ImageWorkbench.ResizeEdge.top, .bottom, .left, .right], id: \.self) { edge in
                                EdgeResizeHandle(edge: edge, onDragStart: {
                                    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                                    print("[\(timestamp)] 🔧 EDGE RESIZE START - Edge: \(edge)")
                                    isResizing = true
                                    resizeStartSize = doc.displaySize
                                }, onDragChanged: { translation in
                                    if isResizing {
                                        // Update asynchronously to avoid publishing during view updates
                                        Task { @MainActor in
                                            vm.edgeResize(for: doc.id, edge: edge, delta: translation)
                                        }
                                    }
                                }, onDragEnd: {
                                    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                                    print("[\(timestamp)] 🔧 EDGE RESIZE END - Edge: \(edge)")
                                    isResizing = false
                                })
                                .position(edgeHandlePosition(for: edge))
                            }
                        } else {
                            // Corner handles for normal resize mode
                            ForEach([ImageWorkbench.ResizeCorner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                                ResizeHandle(corner: corner, onDragStart: {
                                    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                                    print("[\(timestamp)] 🔧 RESIZE START - Corner: \(corner)")
                                    isResizing = true
                                    resizeCorner = corner
                                    resizeStartSize = doc.displaySize
                                }, onDragChanged: { translation in
                                    if isResizing {
                                        vm.cornerResize(for: doc.id, corner: corner, delta: translation)
                                    }
                                }, onDragEnd: {
                                    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                                    print("[\(timestamp)] 🔧 RESIZE END - Corner: \(corner)")
                                    isResizing = false
                                    resizeCorner = nil
                                })
                                .position(handlePosition(for: corner))
                            }
                        }
                    }
                }
            )
            .shadow(radius: isFocused ? 8 : 0)
            .onTapGesture { 
                let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("[\(timestamp)] 👆 TAP GESTURE - Image: \(doc.name), isDragging: \(isDragging), isResizing: \(isResizing)")
                vm.focus(doc.id) 
            }
            .onHover { isHovering in
                // Only handle hover when not dragging to prevent interference
                if !isDragging {
                    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                    print("[\(timestamp)] 🖱️ HOVER - Image: \(doc.name), isHovering: \(isHovering), isDragging: \(isDragging), isResizing: \(isResizing)")
                    if isHovering && isFocused {
                        // Set cursor to indicate draggable
                        NSCursor.openHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
            .gesture(
                // Only allow dragging if this image is focused and not resizing
                (isFocused && !isResizing) ? DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                            print("[\(timestamp)] 🖱️ DRAG START - Image: \(doc.name)")
                            print("[\(timestamp)]   Start location: \(value.startLocation)")
                            print("[\(timestamp)]   Current doc position: \(doc.position)")
                            isDragging = true
                            dragStartPosition = doc.position
                            NSCursor.closedHand.set()
                        }
                        
                        // Calculate new position from start position + translation
                        let newPosition = CGPoint(
                            x: dragStartPosition.x + value.translation.width,
                            y: dragStartPosition.y + value.translation.height
                        )
                        
                        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                        print("[\(timestamp)] 🖱️ DRAG CHANGED - Translation: \(value.translation), New pos: \(newPosition)")
                        
                        vm.updatePosition(for: doc.id, newPosition)
                        vm.updateDragState(offset: value.translation, isDragging: true)
                    }
                    .onEnded { value in
                        if isDragging {
                            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                            print("[\(timestamp)] 🖱️ DRAG END - Image: \(doc.name)")
                            print("[\(timestamp)]   Translation: \(value.translation)")
                            print("[\(timestamp)]   Final position: \(doc.position)")
                            vm.updateDragState(offset: .zero, isDragging: false)
                            isDragging = false
                            NSCursor.arrow.set()
                        }
                    } : nil
            )
            .contextMenu {
                Button("Focus") { vm.focus(doc.id) }
                Button("Reset Position") { vm.resetPosition(for: doc.id) }
                Button("Close") { vm.closeImage(doc.id) }
                Slider(value: Binding(
                    get: { doc.overlayOpacity },
                    set: { vm.setOpacity(for: doc.id, $0) }
                ), in: 0...1) {
                    Text("Opacity")
                }
            }
        .position(currentPosition)
    }
    
    private func handlePosition(for corner: ImageWorkbench.ResizeCorner) -> CGPoint {
        // Use canvas size if set, otherwise use display size
        let frameSize = doc.canvasSize ?? doc.displaySize
        
        // Position handles at the actual corners of the frame
        // Overlay coordinate system starts at (0,0) at top-left of frame
        let position: CGPoint
        switch corner {
        case .topLeft:
            position = CGPoint(x: 0, y: 0)
        case .topRight:
            position = CGPoint(x: frameSize.width, y: 0)
        case .bottomLeft:
            position = CGPoint(x: 0, y: frameSize.height)
        case .bottomRight:
            position = CGPoint(x: frameSize.width, y: frameSize.height)
        }
        
        return position
    }
    
    private func edgeHandlePosition(for edge: ImageWorkbench.ResizeEdge) -> CGPoint {
        // Use canvas size if set, otherwise use display size
        let frameSize = doc.canvasSize ?? doc.displaySize
        
        // Position handles at the midpoints of each edge
        let position: CGPoint
        switch edge {
        case .top:
            position = CGPoint(x: frameSize.width / 2, y: 0)
        case .bottom:
            position = CGPoint(x: frameSize.width / 2, y: frameSize.height)
        case .left:
            position = CGPoint(x: 0, y: frameSize.height / 2)
        case .right:
            position = CGPoint(x: frameSize.width, y: frameSize.height / 2)
        }
        
        return position
    }
}

// Resize handle view (for corners)
struct ResizeHandle: View {
    let corner: ImageWorkbench.ResizeCorner
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnd: () -> Void
    
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            )
            .shadow(radius: 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDragStart()
                        onDragChanged(value.translation)
                    }
                    .onEnded { _ in
                        onDragEnd()
                    }
            )
    }
}

// Edge resize handle view (for canvas resize mode)
struct EdgeResizeHandle: View {
    let edge: ImageWorkbench.ResizeEdge
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnd: () -> Void
    
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            )
            .shadow(radius: 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDragStart()
                        onDragChanged(value.translation)
                    }
                    .onEnded { _ in
                        onDragEnd()
                    }
            )
    }
}

// Inspector for focused image
struct Inspector: View {
    @EnvironmentObject var vm: ImageWorkbench
    var doc: ImageDoc
    
    @State private var width: String = ""
    @State private var height: String = ""
    @State private var format: ImageWorkbench.SaveFormat = .png
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Editable name field
            HStack {
                if vm.isRenaming && vm.focusedID == doc.id {
                    TextField("Image name", text: $vm.renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            vm.confirmRename()
                        }
                        .onExitCommand {
                            vm.cancelRename()
                        }
                } else {
                    Text(doc.name).font(.headline).lineLimit(2)
                    Spacer()
                    Button {
                        vm.startRenaming(doc)
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onKeyPress(.return) {
                if vm.isRenaming {
                    vm.confirmRename()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.escape) {
                if vm.isRenaming {
                    vm.cancelRename()
                    return .handled
                }
                return .ignored
            }
            
            LabeledContent("Original") {
                Text("\(Int(doc.original.size.width))×\(Int(doc.original.size.height))")
            }
            LabeledContent(vm.canvasResizeMode && vm.layout == .overlay ? "Canvas" : "Current") {
                if vm.canvasResizeMode && vm.layout == .overlay {
                    Text("\(Int(doc.canvasSize?.width ?? doc.displaySize.width))×\(Int(doc.canvasSize?.height ?? doc.displaySize.height))")
                } else {
                    Text("\(Int(doc.displaySize.width))×\(Int(doc.displaySize.height))")
                }
            }
            
            Toggle("Lock aspect", isOn: $vm.keepAspect)
            
            HStack {
                TextField("Width", text: Binding(
                    get: { width.isEmpty ? "\(Int(doc.displaySize.width))" : width },
                    set: { width = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                Text("×")
                TextField("Height", text: Binding(
                    get: { height.isEmpty ? "\(Int(doc.displaySize.height))" : height },
                    set: { height = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                Button("Apply") {
                    if let w = Double(width) {
                        vm.updateSize(for: doc.id, width: CGFloat(w))
                    } else if let h = Double(height) {
                        vm.updateSize(for: doc.id, height: CGFloat(h))
                    }
                    width = ""; height = ""
                }
            }
            
            // Canvas resize increment/decrement buttons
            if vm.canvasResizeMode && vm.layout == .overlay {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Canvas Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    // Top controls (+ on top, - below)
                    HStack(spacing: 4) {
                        Spacer()
                        VStack(spacing: 2) {
                            Button {
                                vm.incrementCanvasSize(for: doc.id, edge: .top)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Increase top by 1px")
                            
                            Button {
                                vm.decrementCanvasSize(for: doc.id, edge: .top)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Decrease top by 1px")
                        }
                        Spacer()
                    }
                    
                    // Middle row with left/right controls
                    HStack(spacing: 4) {
                        HStack(spacing: 2) {
                            Button {
                                vm.incrementCanvasSize(for: doc.id, edge: .left)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Increase left by 1px")
                            
                            Button {
                                vm.decrementCanvasSize(for: doc.id, edge: .left)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Decrease left by 1px")
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 2) {
                            Button {
                                vm.decrementCanvasSize(for: doc.id, edge: .right)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Decrease right by 1px")
                            
                            Button {
                                vm.incrementCanvasSize(for: doc.id, edge: .right)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Increase right by 1px")
                        }
                    }
                    
                    // Bottom controls (- on top, + below)
                    HStack(spacing: 4) {
                        Spacer()
                        VStack(spacing: 2) {
                            Button {
                                vm.decrementCanvasSize(for: doc.id, edge: .bottom)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Decrease bottom by 1px")
                            
                            Button {
                                vm.incrementCanvasSize(for: doc.id, edge: .bottom)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                            .help("Increase bottom by 1px")
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }
            
            if vm.layout == .overlay {
                HStack {
                    Text("Opacity")
                    Slider(value: Binding(
                        get: { doc.overlayOpacity },
                        set: { vm.setOpacity(for: doc.id, $0) }
                    ), in: 0...1)
                }
            }
            
            Divider()
            Picker("Save format", selection: $format) {
                ForEach(ImageWorkbench.SaveFormat.allCases) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }
            Button {
                vm.saveFocused(as: format)
            } label: {
                Label("Save Resized…", systemImage: "square.and.arrow.down")
            }
        }
        .onAppear {
            width = "\(Int(doc.displaySize.width))"
            height = "\(Int(doc.displaySize.height))"
        }
    }
}

// MARK: - NSImage utilities

extension NSImage {
    func resized(to target: CGSize, keepAspect: Bool) -> NSImage? {
        let finalSize: CGSize
        if keepAspect {
            let ar = size.height == 0 ? 1 : size.width / size.height
            if target.width / max(target.height, 1) > ar {
                finalSize = CGSize(width: target.height * ar, height: target.height)
            } else {
                finalSize = CGSize(width: target.width, height: target.width / max(ar, 0.0001))
            }
        } else {
            finalSize = target
        }
        let img = NSImage(size: finalSize)
        img.lockFocus()
        defer { img.unlockFocus() }
        let rect = CGRect(origin: .zero, size: finalSize)
        NSGraphicsContext.current?.imageInterpolation = .high
        self.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
        return img
    }
    
    func data(for format: ImageWorkbench.SaveFormat, compression: Double = 0.92) -> Data? {
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
        }
    }
}

// MARK: - Quality-of-life

extension UTType {
    static var webP: UTType { UTType(importedAs: "org.webmproject.webp") }
    static var rawImage: UTType { UTType(importedAs: "public.camera-raw-image") }
}

extension NSItemProvider {
    convenience init(object: NSItemProvider) { self.init() } // placeholder to satisfy onDrop mapping
}
