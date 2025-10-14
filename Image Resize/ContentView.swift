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

enum AnchorPoint: String, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topCenter = "Top Center"
    case topRight = "Top Right"
    case centerLeft = "Center Left"
    case center = "Center"
    case centerRight = "Center Right"
    case bottomLeft = "Bottom Left"
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"
    
    var id: String { rawValue }
    
    var offset: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topCenter: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .centerLeft: return CGPoint(x: 0, y: 0.5)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .centerRight: return CGPoint(x: 1, y: 0.5)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomCenter: return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

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
    /// Whether the image is visible in the canvas
    var isVisible: Bool = true
    /// Frame duration for animation (in seconds)
    var frameDuration: Double = 0.5
    /// Animation order index (for reordering frames)
    var animationOrder: Int = 0
    /// Anchor point for placement mode (where the position refers to on the image)
    var anchorPoint: AnchorPoint = .center
    /// Whether the image is flipped horizontally
    var flipX: Bool = false
    /// Whether the image is flipped vertically
    var flipY: Bool = false
    
    var aspectRatio: CGFloat {
        let s = original.size
        return s.height == 0 ? 1 : s.width / s.height
    }
    
    /// Returns the image resized to the current display size
    var resizedImage: NSImage {
        let resized = original.resized(to: displaySize, keepAspect: true) ?? original
        
        // Apply flip transformations if needed
        if flipX || flipY {
            return resized.flipped(horizontal: flipX, vertical: flipY) ?? resized
        }
        
        return resized
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
        
        // Check if image has been flipped
        let flipChanged = flipX || flipY
        
        return sizeChanged || positionChanged || opacityChanged || canvasChanged || flipChanged
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
    let isVisible: Bool
    let frameDuration: Double
    let animationOrder: Int
    
    init(from doc: ImageDoc) {
        self.url = doc.url
        self.name = doc.name
        self.displaySize = doc.displaySize
        self.originalSize = doc.originalSize
        self.lastAccessed = Date()
        self.isVisible = doc.isVisible
        self.frameDuration = doc.frameDuration
        self.animationOrder = doc.animationOrder
        
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
            borderColor: borderColor,
            isVisible: isVisible,
            frameDuration: frameDuration,
            animationOrder: animationOrder
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
    @Published var showAsTemplate = false
    @Published var baseImageID: ImageDoc.ID? = nil
    @Published var showCoordinates = true
    @Published var history: [ImageDoc] = []
    @Published var dragOffset: CGSize = .zero
    @Published var isDragging: Bool = false
    @Published var isRenaming: Bool = false
    @Published var renameText: String = ""
    @Published var canvasSize: CGSize = .zero // Store canvas size for placement mode calculations
    @Published var baseFrameSize: CGSize = .zero // Store actual rendered base frame size
    
    // Animation state
    @Published var isAnimating: Bool = false
    @Published var currentFrameIndex: Int = 0
    @Published var animationTimer: Timer?
    
    init() {
        loadHistory()
    }
    
    enum LayoutMode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by side"
        case overlay = "Overlay"
        case animation = "Animation"
        case placement = "Placement"
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
                let animationOrder = docs.count + newDocs.count // Set animation order based on total count
                let doc = ImageDoc(url: url, name: url.lastPathComponent, original: img, displaySize: start, position: centerPosition, originalSize: s, borderColor: borderColor, frameDuration: 0.5, animationOrder: animationOrder)
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
                        let animationOrder = self.docs.count
                        let doc = ImageDoc(url: nil, name: "Dropped Image", original: img, displaySize: start, position: centerPosition, originalSize: s, borderColor: borderColor, frameDuration: 0.5, animationOrder: animationOrder)
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
    
    // MARK: Visibility functionality
    func toggleVisibility(for id: ImageDoc.ID) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].isVisible.toggle()
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
    
    func flipX(for id: ImageDoc.ID) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].flipX.toggle()
    }
    
    func flipY(for id: ImageDoc.ID) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].flipY.toggle()
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
                borderColor: borderColor,
                frameDuration: doc.frameDuration,
                animationOrder: doc.animationOrder
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
    
    // MARK: Animation functionality
    func startAnimation() {
        guard !docs.isEmpty else { return }
        stopAnimation() // Stop any existing animation
        
        isAnimating = true
        currentFrameIndex = 0
        updateAnimationTimer()
    }
    
    func stopAnimation() {
        isAnimating = false
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    func toggleAnimation() {
        if isAnimating {
            stopAnimation()
        } else {
            startAnimation()
        }
    }
    
    private func updateAnimationTimer() {
        guard isAnimating && !docs.isEmpty else { return }
        
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        guard !visibleDocs.isEmpty else { return }
        
        let currentDoc = visibleDocs[currentFrameIndex % visibleDocs.count]
        let duration = currentDoc.frameDuration
        
        animationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.advanceToNextFrame()
            }
        }
    }
    
    private func advanceToNextFrame() {
        guard isAnimating else { return }
        
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        guard !visibleDocs.isEmpty else { return }
        
        currentFrameIndex = (currentFrameIndex + 1) % visibleDocs.count
        updateAnimationTimer()
    }
    
    func goToFrame(_ index: Int) {
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        guard !visibleDocs.isEmpty && index >= 0 && index < visibleDocs.count else { return }
        
        currentFrameIndex = index
        if isAnimating {
            updateAnimationTimer()
        }
    }
    
    func previousFrame() {
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        guard !visibleDocs.isEmpty else { return }
        
        currentFrameIndex = (currentFrameIndex - 1 + visibleDocs.count) % visibleDocs.count
        if isAnimating {
            updateAnimationTimer()
        }
    }
    
    func nextFrame() {
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        guard !visibleDocs.isEmpty else { return }
        
        currentFrameIndex = (currentFrameIndex + 1) % visibleDocs.count
        if isAnimating {
            updateAnimationTimer()
        }
    }
    
    func setFrameDuration(for id: ImageDoc.ID, duration: Double) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].frameDuration = max(0.1, duration) // Minimum 0.1 seconds
    }
    
    func reorderFrames(from source: IndexSet, to destination: Int) {
        // Get visible docs sorted by animation order
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        
        // Create a mapping of animation order to actual doc index
        var orderToIndex: [Int: Int] = [:]
        for (index, doc) in docs.enumerated() {
            if doc.isVisible {
                orderToIndex[doc.animationOrder] = index
            }
        }
        
        // Reorder the animation orders
        var newOrders = visibleDocs.map { $0.animationOrder }
        newOrders.move(fromOffsets: source, toOffset: destination)
        
        // Apply new orders to docs
        for (i, doc) in visibleDocs.enumerated() {
            if let docIndex = orderToIndex[doc.animationOrder] {
                docs[docIndex].animationOrder = newOrders[i]
            }
        }
    }
    
    func reorderFrame(from sourceIndex: Int, to targetIndex: Int) {
        print("🔧 REORDER DEBUG:")
        print("  Input: sourceIndex=\(sourceIndex), targetIndex=\(targetIndex)")
        
        // Get visible docs sorted by animation order
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        print("  Visible docs count: \(visibleDocs.count)")
        
        // Print current order before reorder
        print("  Current order before reorder:")
        for (i, doc) in visibleDocs.enumerated() {
            print("    [\(i)] \(doc.name) (order: \(doc.animationOrder))")
        }
        
        guard sourceIndex >= 0 && sourceIndex < visibleDocs.count &&
              targetIndex >= 0 && targetIndex < visibleDocs.count &&
              sourceIndex != targetIndex else { 
            print("  ❌ Guard failed - invalid indices")
            return 
        }
        
        // Get the source doc
        let sourceDoc = visibleDocs[sourceIndex]
        print("  Source doc: \(sourceDoc.name) (order: \(sourceDoc.animationOrder))")
        
        // Find the actual index of the source doc in the main docs array
        guard let sourceDocIndex = docs.firstIndex(where: { $0.id == sourceDoc.id }) else { 
            print("  ❌ Could not find source doc in main docs array")
            return 
        }
        print("  Source doc index in main array: \(sourceDocIndex)")
        
        // Calculate new animation order
        let newAnimationOrder: Int
        if targetIndex == 0 {
            // Moving to the beginning
            newAnimationOrder = visibleDocs[0].animationOrder - 1
            print("  Moving to beginning, new order: \(newAnimationOrder)")
        } else if targetIndex >= visibleDocs.count - 1 {
            // Moving to the end
            newAnimationOrder = visibleDocs[visibleDocs.count - 1].animationOrder + 1
            print("  Moving to end, new order: \(newAnimationOrder)")
        } else {
            // Moving to middle - place between two frames
            let prevOrder = visibleDocs[targetIndex - 1].animationOrder
            let nextOrder = visibleDocs[targetIndex].animationOrder
            newAnimationOrder = (prevOrder + nextOrder) / 2
            print("  Moving to middle, prev: \(prevOrder), next: \(nextOrder), new: \(newAnimationOrder)")
        }
        
        // Update the animation order
        let oldOrder = docs[sourceDocIndex].animationOrder
        docs[sourceDocIndex].animationOrder = newAnimationOrder
        print("  Updated animation order: \(oldOrder) -> \(newAnimationOrder)")
        
        // If we're currently viewing this frame, update the current frame index
        if currentFrameIndex == sourceIndex {
            currentFrameIndex = targetIndex
            print("  Updated current frame index: \(sourceIndex) -> \(targetIndex)")
        } else if currentFrameIndex > sourceIndex && currentFrameIndex <= targetIndex {
            currentFrameIndex -= 1
            print("  Adjusted current frame index: \(currentFrameIndex + 1) -> \(currentFrameIndex)")
        } else if currentFrameIndex < sourceIndex && currentFrameIndex >= targetIndex {
            currentFrameIndex += 1
            print("  Adjusted current frame index: \(currentFrameIndex - 1) -> \(currentFrameIndex)")
        }
        
        // Print order after reorder
        let newVisibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        print("  Order after reorder:")
        for (i, doc) in newVisibleDocs.enumerated() {
            print("    [\(i)] \(doc.name) (order: \(doc.animationOrder))")
        }
        
        print("  ✅ Reorder completed successfully")
    }
    
    func getCurrentFrame() -> ImageDoc? {
        let visibleDocs = docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
        guard !visibleDocs.isEmpty else { return nil }
        return visibleDocs[currentFrameIndex % visibleDocs.count]
    }
    
    func getVisibleFrames() -> [ImageDoc] {
        return docs.filter { $0.isVisible }.sorted { $0.animationOrder < $1.animationOrder }
    }
    
    // MARK: Placement mode functionality
    func setBaseImage(_ id: ImageDoc.ID) {
        baseImageID = id
    }
    
    func getBaseImage() -> ImageDoc? {
        guard let baseID = baseImageID else { return nil }
        return docs.first { $0.id == baseID }
    }
    
    func getOverlayImages() -> [ImageDoc] {
        guard let baseID = baseImageID else { return docs.filter { $0.isVisible } }
        return docs.filter { $0.id != baseID && $0.isVisible }
    }
    
    func setAnchorPoint(for id: ImageDoc.ID, anchor: AnchorPoint) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        docs[idx].anchorPoint = anchor
    }
    
    func moveLayerUp(_ id: ImageDoc.ID) {
        guard let currentIndex = docs.firstIndex(where: { $0.id == id }),
              currentIndex < docs.count - 1 else { return }
        docs.swapAt(currentIndex, currentIndex + 1)
    }
    
    func moveLayerDown(_ id: ImageDoc.ID) {
        guard let currentIndex = docs.firstIndex(where: { $0.id == id }),
              currentIndex > 0 else { return }
        docs.swapAt(currentIndex, currentIndex - 1)
    }
    
    func getRelativePosition(for doc: ImageDoc, baseFrameSize: CGSize? = nil, baseCenter: CGPoint? = nil) -> CGPoint {
        guard let baseImage = getBaseImage() else { return doc.position }
        
        // Use provided frame size, or stored frame size, or fall back to display size
        let baseFrameSize = baseFrameSize ?? (self.baseFrameSize != .zero ? self.baseFrameSize : baseImage.displaySize)
        
        // Calculate the anchor point position of the overlay image
        let overlayAnchor = CGPoint(
            x: doc.position.x + doc.displaySize.width * (doc.anchorPoint.offset.x - 0.5),
            y: doc.position.y + doc.displaySize.height * (doc.anchorPoint.offset.y - 0.5)
        )
        
        // Calculate the base image's anchor point position
        let baseAnchorPoint: CGPoint
        if let providedCenter = baseCenter {
            // The provided center is the actual center of the rendered image
            // Calculate top-left corner from center, then add anchor offset
            let baseTopLeft = CGPoint(
                x: providedCenter.x - baseFrameSize.width / 2,
                y: providedCenter.y - baseFrameSize.height / 2
            )
            baseAnchorPoint = CGPoint(
                x: baseTopLeft.x + baseFrameSize.width * baseImage.anchorPoint.offset.x,
                y: baseTopLeft.y + baseFrameSize.height * baseImage.anchorPoint.offset.y
            )
        } else if layout == .placement && canvasSize != .zero {
            // In placement mode, use the stored canvas size to calculate the center
            let calculatedCenter = CGPoint(
                x: canvasSize.width / 2,
                y: canvasSize.height / 2
            )
            let baseTopLeft = CGPoint(
                x: calculatedCenter.x - baseFrameSize.width / 2,
                y: calculatedCenter.y - baseFrameSize.height / 2
            )
            baseAnchorPoint = CGPoint(
                x: baseTopLeft.x + baseFrameSize.width * baseImage.anchorPoint.offset.x,
                y: baseTopLeft.y + baseFrameSize.height * baseImage.anchorPoint.offset.y
            )
        } else {
            // Fallback to stored position
            baseAnchorPoint = CGPoint(
                x: baseImage.position.x + baseFrameSize.width * (baseImage.anchorPoint.offset.x - 0.5),
                y: baseImage.position.y + baseFrameSize.height * (baseImage.anchorPoint.offset.y - 0.5)
            )
        }
        
        // Return the difference between the anchor points
        return CGPoint(
            x: overlayAnchor.x - baseAnchorPoint.x,
            y: overlayAnchor.y - baseAnchorPoint.y
        )
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
                            vm.toggleVisibility(for: doc.id)
                        } label: {
                            Image(systemName: doc.isVisible ? "eye.fill" : "eye.slash.fill")
                                .foregroundStyle(doc.isVisible ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        .opacity(0.7)
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
            
            // Bottom row: Mode-specific controls
            if vm.layout == .overlay {
                HStack(spacing: 12) {
                    Toggle("Canvas Resize", isOn: $vm.canvasResizeMode)
                        .toggleStyle(.switch)
                    Toggle("Show Borders", isOn: $vm.showBorders)
                        .toggleStyle(.switch)
                    Toggle("Show as Template", isOn: $vm.showAsTemplate)
                        .toggleStyle(.switch)
                    Button {
                        vm.restackImages()
                    } label: {
                        Label("Restack", systemImage: "square.stack.3d.up")
                    }
                    Spacer()
                }
            } else if vm.layout == .animation {
                HStack(spacing: 12) {
                    Button {
                        vm.toggleAnimation()
                    } label: {
                        Label(vm.isAnimating ? "Pause" : "Play", systemImage: vm.isAnimating ? "pause.fill" : "play.fill")
                    }
                    .disabled(vm.docs.filter { $0.isVisible }.isEmpty)
                    
                    Button {
                        vm.previousFrame()
                    } label: {
                        Label("Previous", systemImage: "backward.fill")
                    }
                    .disabled(vm.docs.filter { $0.isVisible }.isEmpty)
                    
                    Button {
                        vm.nextFrame()
                    } label: {
                        Label("Next", systemImage: "forward.fill")
                    }
                    .disabled(vm.docs.filter { $0.isVisible }.isEmpty)
                    
                    if !vm.docs.filter { $0.isVisible }.isEmpty {
                        let visibleFrames = vm.getVisibleFrames()
                        Text("Frame \(vm.currentFrameIndex + 1) of \(visibleFrames.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
            } else if vm.layout == .placement {
                HStack(spacing: 12) {
                    if !vm.docs.isEmpty {
                        Picker("Base Image", selection: Binding(
                            get: { vm.baseImageID ?? vm.docs.first?.id ?? UUID() },
                            set: { vm.setBaseImage($0) }
                        )) {
                            ForEach(vm.docs) { doc in
                                Text(doc.name).tag(doc.id)
                            }
                        }
                        .frame(width: 200)
                        
                        // Base image anchor point picker
                        if let baseImage = vm.getBaseImage() {
                            HStack(spacing: 4) {
                                Text("Anchor:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("Base Anchor", selection: Binding(
                                    get: { baseImage.anchorPoint },
                                    set: { vm.setAnchorPoint(for: baseImage.id, anchor: $0) }
                                )) {
                                    ForEach(AnchorPoint.allCases) { anchor in
                                        Text(anchor.rawValue).tag(anchor)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 100)
                            }
                        }
                    }
                    Toggle("Show Coordinates", isOn: $vm.showCoordinates)
                        .toggleStyle(.switch)
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
                        ForEach(vm.docs.filter { $0.isVisible }.sorted { doc1, doc2 in
                            // Put focused image last (on top)
                            if vm.isFocused(doc1) { return false }
                            if vm.isFocused(doc2) { return true }
                            return false
                        }) { doc in
                            DraggableResizableImage(doc: doc, maxSize: geo.size)
                                .opacity(doc.overlayOpacity)
                        }
                        
                        // Position display for focused image
                        if let focusedDoc = vm.docs.first(where: { vm.isFocused($0) && $0.isVisible }) {
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
            case .animation:
                AnimationCanvas()
            case .placement:
                PlacementCanvas()
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
            ForEach(docs.filter { $0.isVisible }) { doc in
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
        
        return Image(nsImage: doc.resizedImage)
            .renderingMode(vm.showAsTemplate ? .template : .original)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .foregroundColor(vm.showAsTemplate ? doc.borderColor : nil)
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
        
        // Get the appropriate image (template or original with transformations)
        let displayImage = doc.resizedImage
        
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
            Image(nsImage: displayImage)
                .renderingMode(vm.showAsTemplate ? .template : .original)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: doc.displaySize.width, height: doc.displaySize.height)
                .offset(x: doc.imageOffset.x, y: doc.imageOffset.y)
                .foregroundColor(vm.showAsTemplate ? doc.borderColor : nil)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
            .overlay(
                // Frame border (only when showBorders is enabled and showAsTemplate is disabled, or when focused)
                (!vm.showAsTemplate && vm.showBorders) || isFocused ? 
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? Color.accentColor : doc.borderColor, 
                        lineWidth: 2
                    )
                : nil
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
            
            // Flip controls
            VStack(alignment: .leading, spacing: 8) {
                Text("Flip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 8) {
                    Button {
                        vm.flipX(for: doc.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left.and.right")
                            Text("Flip X")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(doc.flipX ? Color.accentColor : .primary)
                    
                    Button {
                        vm.flipY(for: doc.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.and.down")
                            Text("Flip Y")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(doc.flipY ? Color.accentColor : .primary)
                }
            }
            .padding(.vertical, 4)
            
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
            
            if vm.layout == .placement {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Anchor Point")
                        Spacer()
                        Picker("Anchor", selection: Binding(
                            get: { doc.anchorPoint },
                            set: { vm.setAnchorPoint(for: doc.id, anchor: $0) }
                        )) {
                            ForEach(AnchorPoint.allCases) { anchor in
                                Text(anchor.rawValue).tag(anchor)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    
                    if let baseImage = vm.getBaseImage() {
                        let relativePos = vm.getRelativePosition(for: doc)
                        LabeledContent("Base Image") {
                            Text(baseImage.name)
                        }
                        LabeledContent("Relative Position") {
                            Text("(\(Int(relativePos.x)), \(Int(relativePos.y)))")
                        }
                    }
                    
                    HStack {
                        Button("Move Up") { vm.moveLayerUp(doc.id) }
                        Button("Move Down") { vm.moveLayerDown(doc.id) }
                    }
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

// MARK: - Animation Views

struct AnimationCanvas: View {
    @EnvironmentObject var vm: ImageWorkbench
    
    var body: some View {
        HStack(spacing: 0) {
            // Main animation display area
            GeometryReader { geo in
                ZStack {
                    // Background
                    Color(nsColor: .underPageBackgroundColor)
                    
                    // Current frame
                    if let currentFrame = vm.getCurrentFrame() {
                        ZStack {
                            // Image with proper frame border
                            Image(nsImage: currentFrame.resizedImage)
                                .renderingMode(vm.showAsTemplate ? .template : .original)
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: geo.size.width * 0.8, maxHeight: geo.size.height * 0.8)
                                .foregroundColor(vm.showAsTemplate ? currentFrame.borderColor : nil)
                                .overlay(
                                    // Frame border that matches the actual image dimensions
                                    Rectangle()
                                        .stroke(Color.accentColor, lineWidth: 3)
                                        .frame(
                                            width: min(geo.size.width * 0.8, currentFrame.resizedImage.size.width * (geo.size.height * 0.8 / currentFrame.resizedImage.size.height)),
                                            height: min(geo.size.height * 0.8, currentFrame.resizedImage.size.height * (geo.size.width * 0.8 / currentFrame.resizedImage.size.width))
                                        )
                                )
                                .overlay(
                                    // Corner indicators for frame boundaries
                                    VStack {
                                        HStack {
                                            FrameCornerIndicator()
                                            Spacer()
                                            FrameCornerIndicator()
                                        }
                                        Spacer()
                                        HStack {
                                            FrameCornerIndicator()
                                            Spacer()
                                            FrameCornerIndicator()
                                        }
                                    }
                                    .frame(
                                        width: min(geo.size.width * 0.8, currentFrame.resizedImage.size.width * (geo.size.height * 0.8 / currentFrame.resizedImage.size.height)),
                                        height: min(geo.size.height * 0.8, currentFrame.resizedImage.size.height * (geo.size.width * 0.8 / currentFrame.resizedImage.size.width))
                                    )
                                )
                                .shadow(radius: 8)
                                
                                // Frame information overlay
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text("Frame \(vm.currentFrameIndex + 1) of \(vm.getVisibleFrames().count)")
                                                .font(.caption)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                            
                                            Text("\(Int(currentFrame.resizedImage.size.width))×\(Int(currentFrame.resizedImage.size.height))")
                                                .font(.caption2)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                            
                                            Text("\(Int(currentFrame.frameDuration * 1000))ms")
                                                .font(.caption2)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                        }
                                        .padding(.trailing, 16)
                                        .padding(.bottom, 16)
                                    }
                                }
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("No frames to animate")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Load some images and make them visible to start animating")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            
            // Timeline panel
            AnimationTimeline()
                .frame(width: 300)
        }
    }
}

struct AnimationTimeline: View {
    @EnvironmentObject var vm: ImageWorkbench
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Animation Timeline")
                        .font(.headline)
                    Spacer()
                    if !vm.docs.filter { $0.isVisible }.isEmpty {
                        Text("\(vm.getVisibleFrames().count) frames")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if !vm.getVisibleFrames().isEmpty {
                    Text("Drag frames to reorder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Divider()
            
            // Timeline list
            if vm.getVisibleFrames().isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No visible frames")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Toggle visibility on images to add them to the animation")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(vm.getVisibleFrames().enumerated()), id: \.element.id) { index, doc in
                            AnimationFrameRow(
                                doc: doc,
                                index: index,
                                isCurrentFrame: index == vm.currentFrameIndex
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct AnimationFrameRow: View {
    @EnvironmentObject var vm: ImageWorkbench
    let doc: ImageDoc
    let index: Int
    let isCurrentFrame: Bool
    
    @State private var durationText: String = ""
    @State private var isDragging: Bool = false
    @State private var dragOffset: CGSize = .zero
    
    var body: some View {
        HStack(spacing: 8) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            
            // Frame thumbnail with proper frame border
            Image(nsImage: doc.resizedImage)
                .renderingMode(vm.showAsTemplate ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .foregroundColor(vm.showAsTemplate ? doc.borderColor : nil)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isCurrentFrame ? Color.accentColor : Color.secondary.opacity(0.3), 
                            lineWidth: isCurrentFrame ? 3 : 1
                        )
                )
            
            // Frame info
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(Int(doc.resizedImage.size.width))×\(Int(doc.resizedImage.size.height))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(Int(doc.frameDuration * 1000))ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            // Duration control
            HStack(spacing: 4) {
                Button {
                    let newDuration = max(0.1, doc.frameDuration - 0.1)
                    vm.setFrameDuration(for: doc.id, duration: newDuration)
                } label: {
                    Image(systemName: "minus")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .frame(width: 20, height: 20)
                
                TextField("Duration", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .font(.caption2)
                    .onSubmit {
                        if let duration = Double(durationText) {
                            vm.setFrameDuration(for: doc.id, duration: max(0.1, duration))
                        }
                    }
                
                Button {
                    let newDuration = doc.frameDuration + 0.1
                    vm.setFrameDuration(for: doc.id, duration: newDuration)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .frame(width: 20, height: 20)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentFrame ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrentFrame ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onTapGesture {
            vm.goToFrame(index)
        }
        .onAppear {
            durationText = String(format: "%.1f", doc.frameDuration)
        }
        .onChange(of: doc.frameDuration) { _, newValue in
            durationText = String(format: "%.1f", newValue)
        }
        .offset(dragOffset)
        .scaleEffect(isDragging ? 1.05 : 1.0)
        .opacity(isDragging ? 0.8 : 1.0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                    }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    isDragging = false
                    dragOffset = .zero
                    
                    // Calculate which frame to swap with based on drag distance
                    let dragDistance = value.translation.height
                    let frameHeight: CGFloat = 80 // More accurate height of each frame row (including spacing)
                    let targetIndex = index + Int(round(dragDistance / frameHeight))
                    
                    print("🔄 DRAG DEBUG:")
                    print("  Source index: \(index)")
                    print("  Drag distance: \(dragDistance)")
                    print("  Frame height: \(frameHeight)")
                    print("  Calculated target index: \(targetIndex)")
                    
                    // Ensure target index is within bounds
                    let visibleFrames = vm.getVisibleFrames()
                    print("  Visible frames count: \(visibleFrames.count)")
                    
                    // Clamp target index to valid range
                    let clampedTargetIndex = max(0, min(targetIndex, visibleFrames.count - 1))
                    print("  Clamped target index: \(targetIndex) -> \(clampedTargetIndex)")
                    print("  Target index valid: \(clampedTargetIndex != index)")
                    
                    if clampedTargetIndex != index {
                        print("  ✅ Calling reorderFrame(from: \(index), to: \(clampedTargetIndex))")
                        // Perform the reorder using a simpler approach
                        vm.reorderFrame(from: index, to: clampedTargetIndex)
                        print("  ✅ Reorder completed")
                    } else {
                        print("  ❌ Reorder skipped - same position")
                    }
                }
        )
    }
}

// MARK: - Animation Support Views


struct FrameCornerIndicator: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 1)
            )
    }
}

// MARK: - Placement Views

struct PlacementCanvas: View {
    @EnvironmentObject var vm: ImageWorkbench
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                Color(nsColor: .underPageBackgroundColor)
                
                if let baseImage = vm.getBaseImage() {
                    // Calculate the actual rendered frame size
                    let baseFrameSize = CGSize(
                        width: min(geo.size.width * 0.8, baseImage.resizedImage.size.width * (geo.size.height * 0.8 / baseImage.resizedImage.size.height)),
                        height: min(geo.size.height * 0.8, baseImage.resizedImage.size.height * (geo.size.width * 0.8 / baseImage.resizedImage.size.width))
                    )
                    
                    // Store canvas size and base frame size in view model for relative position calculations
                    let _ = DispatchQueue.main.async {
                        if vm.canvasSize != geo.size {
                            vm.canvasSize = geo.size
                        }
                        if vm.baseFrameSize != baseFrameSize {
                            vm.baseFrameSize = baseFrameSize
                        }
                    }
                    
                    // Calculate the actual center position of the base image (it's centered in the view)
                    let baseActualCenter = CGPoint(
                        x: geo.size.width / 2,
                        y: geo.size.height / 2
                    )
                    
                    // Base image (background)
                    Image(nsImage: baseImage.resizedImage)
                        .renderingMode(vm.showAsTemplate ? .template : .original)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geo.size.width * 0.8, maxHeight: geo.size.height * 0.8)
                        .foregroundColor(vm.showAsTemplate ? baseImage.borderColor : nil)
                        .overlay(
                            // Frame border that matches the actual rendered image dimensions
                            Rectangle()
                                .stroke(Color.blue, lineWidth: 3)
                                .frame(width: baseFrameSize.width, height: baseFrameSize.height)
                        )
                        .overlay(
                            // Corner indicators for frame boundaries
                            VStack {
                                HStack {
                                    FrameCornerIndicator()
                                    Spacer()
                                    FrameCornerIndicator()
                                }
                                Spacer()
                                HStack {
                                    FrameCornerIndicator()
                                    Spacer()
                                    FrameCornerIndicator()
                                }
                            }
                            .frame(width: baseFrameSize.width, height: baseFrameSize.height)
                        )
                        .overlay(
                            // Anchor point indicator
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                )
                                .offset(
                                    x: (baseImage.anchorPoint.offset.x - 0.5) * baseFrameSize.width,
                                    y: (baseImage.anchorPoint.offset.y - 0.5) * baseFrameSize.height
                                )
                        )
                        .overlay(
                            // Coordinate text overlays (relative to anchor point)
                            VStack {
                                HStack {
                                    // Top-left corner coordinates (relative to anchor)
                                    VStack {
                                        let anchorX = baseImage.anchorPoint.offset.x * baseFrameSize.width
                                        let anchorY = baseImage.anchorPoint.offset.y * baseFrameSize.height
                                        let topLeftX = -anchorX
                                        let topLeftY = -anchorY
                                        
                                        Text("(\(Int(topLeftX)), \(Int(topLeftY)))")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.blue)
                                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                            .padding(2)
                                        Spacer()
                                    }
                                    Spacer()
                                    // Top-right corner coordinates (relative to anchor)
                                    VStack {
                                        let anchorX = baseImage.anchorPoint.offset.x * baseFrameSize.width
                                        let anchorY = baseImage.anchorPoint.offset.y * baseFrameSize.height
                                        let topRightX = baseFrameSize.width - anchorX
                                        let topRightY = -anchorY
                                        
                                        Text("(\(Int(topRightX)), \(Int(topRightY)))")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.blue)
                                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                            .padding(2)
                                        Spacer()
                                    }
                                }
                                Spacer()
                                HStack {
                                    // Bottom-left corner coordinates (relative to anchor)
                                    VStack {
                                        Spacer()
                                        let anchorX = baseImage.anchorPoint.offset.x * baseFrameSize.width
                                        let anchorY = baseImage.anchorPoint.offset.y * baseFrameSize.height
                                        let bottomLeftX = -anchorX
                                        let bottomLeftY = baseFrameSize.height - anchorY
                                        
                                        Text("(\(Int(bottomLeftX)), \(Int(bottomLeftY)))")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.blue)
                                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                            .padding(2)
                                    }
                                    Spacer()
                                    // Bottom-right corner coordinates (relative to anchor)
                                    VStack {
                                        Spacer()
                                        let anchorX = baseImage.anchorPoint.offset.x * baseFrameSize.width
                                        let anchorY = baseImage.anchorPoint.offset.y * baseFrameSize.height
                                        let bottomRightX = baseFrameSize.width - anchorX
                                        let bottomRightY = baseFrameSize.height - anchorY
                                        
                                        Text("(\(Int(bottomRightX)), \(Int(bottomRightY)))")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.blue)
                                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                            .padding(2)
                                    }
                                }
                            }
                            .frame(width: baseFrameSize.width, height: baseFrameSize.height)
                        )
                        .overlay(
                            VStack {
                                HStack {
                                    Text("BASE: \(baseImage.name)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.blue, lineWidth: 1)
                                        )
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(8)
                        )
                    
                    // Overlay images (sprites/assets)
                    ForEach(vm.getOverlayImages()) { doc in
                        PlacementImage(doc: doc, baseImage: baseImage, baseFrameSize: baseFrameSize, baseActualCenter: baseActualCenter)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Base Image Selected")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Select a base image from the dropdown above")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PlacementImage: View {
    @EnvironmentObject var vm: ImageWorkbench
    let doc: ImageDoc
    let baseImage: ImageDoc
    let baseFrameSize: CGSize
    let baseActualCenter: CGPoint
    
    @State private var isDragging: Bool = false
    @State private var dragStartPosition: CGPoint = .zero
    
    var body: some View {
        let isFocused = vm.isFocused(doc)
        let currentPosition = doc.position
        let relativePosition = vm.getRelativePosition(for: doc, baseFrameSize: baseFrameSize, baseCenter: baseActualCenter)
        
        return Image(nsImage: doc.resizedImage)
            .renderingMode(vm.showAsTemplate ? .template : .original)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: doc.displaySize.width, height: doc.displaySize.height)
            .foregroundColor(vm.showAsTemplate ? doc.borderColor : nil)
            .overlay(
                // Anchor point indicator
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .offset(
                        x: (doc.anchorPoint.offset.x - 0.5) * doc.displaySize.width,
                        y: (doc.anchorPoint.offset.y - 0.5) * doc.displaySize.height
                    )
            )
            .overlay(
                // Selection border
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isFocused ? Color.accentColor : doc.borderColor, lineWidth: isFocused ? 3 : 2)
            )
            .overlay(
                // Position info
                VStack {
                    HStack {
                        if vm.showCoordinates {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(doc.name)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .lineLimit(1)
                                Text("Rel: (\(Int(relativePosition.x)), \(Int(relativePosition.y)))")
                                    .font(.caption2)
                                Text("Abs: (\(Int(currentPosition.x)), \(Int(currentPosition.y)))")
                                    .font(.caption2)
                                Text("Anchor: \(doc.anchorPoint.rawValue)")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .padding(3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: 120)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(2)
            )
            .shadow(radius: isFocused ? 8 : 4)
            .onTapGesture { vm.focus(doc.id) }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartPosition = doc.position
                            vm.focus(doc.id) // Focus the image when starting to drag
                        }
                        
                        let newPosition = CGPoint(
                            x: dragStartPosition.x + value.translation.width,
                            y: dragStartPosition.y + value.translation.height
                        )
                        
                        vm.updatePosition(for: doc.id, newPosition)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .contextMenu {
                Button("Focus") { vm.focus(doc.id) }
                Button("Move Up") { vm.moveLayerUp(doc.id) }
                Button("Move Down") { vm.moveLayerDown(doc.id) }
                Divider()
                Menu("Anchor Point") {
                    ForEach(AnchorPoint.allCases) { anchor in
                        Button(anchor.rawValue) {
                            vm.setAnchorPoint(for: doc.id, anchor: anchor)
                        }
                    }
                }
                Divider()
                Button("Close") { vm.closeImage(doc.id) }
            }
            .position(currentPosition)
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
    
    func flipped(horizontal: Bool, vertical: Bool) -> NSImage? {
        guard horizontal || vertical else { return self }
        
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        
        let context = NSGraphicsContext.current!
        context.saveGraphicsState()
        
        // Apply transformations
        var transform = NSAffineTransform()
        
        // Handle both flips together
        if horizontal && vertical {
            // Flip both: translate to corner, then scale both axes
            transform.translateX(by: size.width, yBy: size.height)
            transform.scaleX(by: -1, yBy: -1)
        } else if horizontal {
            // Flip horizontally: translate right, then scale X
            transform.translateX(by: size.width, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
        } else if vertical {
            // Flip vertically: translate up, then scale Y
            transform.translateX(by: 0, yBy: size.height)
            transform.scaleX(by: 1, yBy: -1)
        }
        
        transform.concat()
        
        // Draw the image
        let rect = CGRect(origin: .zero, size: size)
        self.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
        
        context.restoreGraphicsState()
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
