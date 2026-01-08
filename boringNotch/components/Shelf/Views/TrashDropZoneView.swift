//
//  TrashDropZoneView.swift
//  boringNotch
//
//  Created on 2025-01-06.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct TrashDropZoneView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @State private var isTargeted = false
    @State private var isProcessing = false
    @Default(.trashDeletesOriginalFile) var trashDeletesOriginalFile

    var body: some View {
        dropArea
            .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $isTargeted) { providers in
                vm.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            isTargeted ? Color.red.opacity(0.3) : Color.black.opacity(0.35),
                            isTargeted ? Color.red.opacity(0.2) : Color.black.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isTargeted
                                ? Color.red.opacity(0.9)
                                : Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)

            // Content
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(
                            isTargeted ? 0.11 : 0.09
                        ))
                        .frame(width: 55, height: 55)
                    
                    Image(systemName: isTargeted ? "trash.fill" : "trash")
                        .font(.system(size: 28))
                        .foregroundStyle(
                            isTargeted ? Color.red : Color.gray
                        )
                        .scaleEffect(
                            isTargeted ? 1.1 : 1.0
                        )
                        .animation(.spring(response: 0.36, dampingFraction: 0.7), value: isTargeted)
                }

                Text(trashDeletesOriginalFile ? "垃圾桶" : "移除")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(18)
            
            // Loading overlay
            if isProcessing {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        
        print("🗑️ TrashDropZone: Handling \(providers.count) items")
        
        // 并行处理所有拖入的项目
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask {
                    // 尝试作为文件处理
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        do {
                            if let url = try await loadFileURL(from: provider) {
                                print("🗑️ TrashDropZone: Processing file URL: \(url.path)")
                                await handleFile(url: url)
                                return
                            }
                        } catch {
                            print("🗑️ TrashDropZone: Failed to load file URL: \(error.localizedDescription)")
                        }
                    }
                    
                    // 尝试作为纯文本（可能是路径）处理
                    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ||
                       provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                        if let url = await loadFileURLFromText(provider: provider) {
                            print("🗑️ TrashDropZone: Processing text path: \(url.path)")
                            await handleFile(url: url)
                        } else {
                            print("🗑️ TrashDropZone: Item is text but not a valid file path")
                        }
                    }
                }
            }
        }
    }
    
    private func loadFileURLFromText(provider: NSItemProvider) async -> URL? {
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                guard let text = item as? String else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Parse the text as a file path
                let lines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                
                guard lines.count == 1 else {
                    continuation.resume(returning: nil)
                    return
                }
                
                var path = lines[0]
                
                // Handle file:// URLs
                if path.hasPrefix("file://") {
                    if let url = URL(string: path), url.isFileURL {
                        path = url.path
                    }
                }
                
                // Check if it looks like an absolute path
                guard path.hasPrefix("/") || path.hasPrefix("~") else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Expand tilde if needed
                let expandedPath = (path as NSString).expandingTildeInPath
                
                // Check if file exists
                guard FileManager.default.fileExists(atPath: expandedPath) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                continuation.resume(returning: URL(fileURLWithPath: expandedPath))
            }
        }
    }
    
    private func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let urlItem = item as? URL {
                    url = urlItem
                } else if let string = item as? String {
                    url = URL(string: string)
                }
                
                continuation.resume(returning: url)
            }
        }
    }
    
    private func handleFile(url: URL) async {
        // 在后台线程查找匹配项
        let shelfItems = await MainActor.run { ShelfStateViewModel.shared.items }
        
        // 快速过滤：查找该文件是否已经在寄存区中
        let targetPath = url.path
        let matchingItem = shelfItems.first { item in
            if let itemURL = item.fileURL, itemURL.path == targetPath {
                return true
            }
            return false
        }
        
        if let item = matchingItem {
            print("🗑️ TrashDropZone: Item found in shelf, removing from shelf only")
            // 情况 A：文件来自寄存区 -> 仅从寄存区移除（清理暂存），不删除原文件
            await MainActor.run {
                ShelfActionService.remove(item)
            }
        } else {
            print("🗑️ TrashDropZone: Item not in shelf. trashDeletesOriginalFile is \(trashDeletesOriginalFile)")
            if trashDeletesOriginalFile {
                // 情况 B：文件来自外部 -> 将原文件移至垃圾桶
                do {
                    // 外部文件通常需要开启安全访问权限
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    print("🗑️ TrashDropZone: Successfully moved external file to trash")
                } catch {
                    print("🗑️ TrashDropZone: Failed to move to trash: \(error.localizedDescription)")
                }
            } else {
                print("🗑️ TrashDropZone: Action ignored because 'trashDeletesOriginalFile' is false")
            }
        }
    }
}
