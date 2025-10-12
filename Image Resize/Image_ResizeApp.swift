//
//  Image_ResizeApp.swift
//  Image Resize
//
//  Created by Angel Rodriguez on 10/12/25.
//

import SwiftUI

@main
struct Image_ResizeApp: App {
    @StateObject private var vm = ImageWorkbench()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 900, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    vm.cleanupHistory()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open…", action: vm.openImages)
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Picker("Layout", selection: $vm.layout) {
                    ForEach(ImageWorkbench.LayoutMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .keyboardShortcut("1", modifiers: .command)
                Divider()
                Button("Save Focused as PNG") { vm.saveFocused(as: .png) }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save Focused as JPEG") { vm.saveFocused(as: .jpeg) }
            }
        }
    }
}
