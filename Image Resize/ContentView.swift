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
    
    var aspectRatio: CGFloat {
        let s = original.size
        return s.height == 0 ? 1 : s.width / s.height
    }
}

// MARK: - ViewModel

@MainActor
final class ImageWorkbench: ObservableObject {
    @Published var docs: [ImageDoc] = []
    @Published var focusedID: ImageDoc.ID? = nil
    @Published var layout: LayoutMode = .sideBySide
    @Published var keepAspect = true
    
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
                newDocs.append(ImageDoc(url: url, name: url.lastPathComponent, original: img, displaySize: start))
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
                        let doc = ImageDoc(url: nil, name: "Dropped Image", original: img, displaySize: start)
                        self.docs.append(doc)
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
        let base = (focused.url?.deletingPathExtension().lastPathComponent ?? focused.name)
        panel.nameFieldStringValue = base + format.suggestedExtension
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            let target = focused.displaySize
            guard let resized = focused.original.resized(to: target, keepAspect: self.keepAspect),
                  let data = resized.data(for: format) else { return }
            try? data.write(to: dest)
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
                            Text("\(Int(doc.original.size.width))×\(Int(doc.original.size.height))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(doc.id)
                    .contentShape(Rectangle())
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
            if vm.focusedID != nil {
                Menu {
                    Button("PNG") { vm.saveFocused(as: .png) }
                    Button("JPEG") { vm.saveFocused(as: .jpeg) }
                } label: {
                    Label("Save Focused", systemImage: "square.and.arrow.down")
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
                        ForEach(vm.docs) { doc in
                            FocusableImage(doc: doc, maxSize: geo.size)
                                .opacity(doc.overlayOpacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .animation(.default, value: vm.layout)
    }
}

// Side-by-side flow layout
struct FlowGrid: View {
    @EnvironmentObject var vm: ImageWorkbench
    let docs: [ImageDoc]
    
    var body: some View {
        let columns = [
            GridItem(.adaptive(minimum: 260), spacing: 16)
        ]
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(docs) { doc in
                VStack {
                    FocusableImage(doc: doc, maxSize: CGSize(width: 600, height: 600))
                    HStack {
                        Text(doc.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(Int(doc.displaySize.width))×\(Int(doc.displaySize.height))")
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

// Inspector for focused image
struct Inspector: View {
    @EnvironmentObject var vm: ImageWorkbench
    var doc: ImageDoc
    
    @State private var width: String = ""
    @State private var height: String = ""
    @State private var format: ImageWorkbench.SaveFormat = .png
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(doc.name).font(.headline).lineLimit(2)
            
            LabeledContent("Original") {
                Text("\(Int(doc.original.size.width))×\(Int(doc.original.size.height))")
            }
            LabeledContent("Current") {
                Text("\(Int(doc.displaySize.width))×\(Int(doc.displaySize.height))")
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
