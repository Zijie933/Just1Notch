//
//  JSONViewerWindow.swift
//  boringNotch
//
//  Created on 2026-01-07.
//

import SwiftUI
import AppKit

// MARK: - Local Key Monitor

struct LocalKeyEventMonitor: ViewModifier {
    let onCommandF: () -> Void
    let onEnter: () -> Void
    let onShiftEnter: () -> Void
    let onEscape: () -> Void
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if flags.contains(.command) && event.charactersIgnoringModifiers == "f" { onCommandF(); return nil }
                    if event.keyCode == 36 { if flags.contains(.shift) { onShiftEnter() } else { onEnter() }; return event }
                    if event.keyCode == 53 { onEscape(); return nil }
                    return event
                }
            }
            .onDisappear { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct CommandScrollZoomModifier: ViewModifier {
    @Binding var zoomScale: CGFloat
    @Binding var baseZoomScale: CGFloat
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    if event.modifierFlags.contains(.command) {
                        let delta = event.scrollingDeltaY
                        if abs(delta) > 0 {
                            let factor: CGFloat = delta > 0 ? 1.1 : 0.9
                            let newScale = min(max(zoomScale * factor, 0.5), 3.0)
                            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.86)) { zoomScale = newScale; baseZoomScale = newScale }
                        }
                        return nil
                    }
                    return event
                }
            }
            .onDisappear { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - IDE Theme Colors

private struct JSONFontSizeKey: EnvironmentKey { static let defaultValue: CGFloat = 12 }
extension EnvironmentValues { var jsonFontSize: CGFloat { get { self[JSONFontSizeKey.self] } set { self[JSONFontSizeKey.self] = newValue } } }

struct JSONIDETheme {
    static let editorBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let gutterBackground = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let keyColor = Color(red: 0.61, green: 0.86, blue: 0.99)
    static let stringColor = Color(red: 0.81, green: 0.56, blue: 0.47)
    static let numberColor = Color(red: 0.71, green: 0.89, blue: 0.62)
    static let boolColor = Color(red: 0.34, green: 0.61, blue: 0.84)
    static let nullColor = Color(red: 0.34, green: 0.61, blue: 0.84)
    static let bracketColor = Color(red: 0.86, green: 0.86, blue: 0.67)
    static let colonColor = Color(red: 0.82, green: 0.82, blue: 0.82)
    static let lineNumberColor = Color(red: 0.45, green: 0.45, blue: 0.45)
    static let indentGuideColor = Color.white.opacity(0.12)
    static let foldIndicatorColor = Color(red: 0.55, green: 0.55, blue: 0.55)
    static let searchHighlight = Color.yellow.opacity(0.35)
}

// MARK: - JSON Node Model

indirect enum BoringJSONNode: Equatable {
    case string(String); case number(Double); case bool(Bool); case null
    case array([BoringJSONNode], totalLines: Int); case object([(key: String, value: BoringJSONNode)], totalLines: Int)
    static func == (lhs: BoringJSONNode, rhs: BoringJSONNode) -> Bool {
        switch (lhs, rhs) {
        case (.string(let l), .string(let r)): return l == r
        case (.number(let l), .number(let r)): return l == r
        case (.bool(let l), .bool(let r)): return l == r
        case (.null, .null): return true
        case (.array(let l, _), .array(let r, _)): return l == r
        case (.object(let l, _), .object(let r, _)):
            guard l.count == r.count else { return false }
            for (i, item) in l.enumerated() { if item.key != r[i].key || item.value != r[i].value { return false } }
            return true
        default: return false
        }
    }
    static func parse(_ any: Any) -> BoringJSONNode {
        if let str = any as? String { return .string(str) }
        if let num = any as? NSNumber { if CFGetTypeID(num) == CFBooleanGetTypeID() { return .bool(num.boolValue) }; return .number(num.doubleValue) }
        if let arr = any as? [Any] { let children = arr.map { parse($0) }; return .array(children, totalLines: children.reduce(2) { $0 + $1.totalLinesCount }) }
        if let dict = any as? [String: Any] {
            // 去掉 .sorted，保持自然顺序
            let children = dict.map { (key: $0.key, value: parse($0.value)) }
            return .object(children, totalLines: children.reduce(2) { $0 + $1.value.totalLinesCount })
        }
        return .null
    }
    var totalLinesCount: Int { switch self { case .array(_, let t): return t; case .object(_, let t): return t; default: return 1 } }
    var childCount: Int { switch self { case .array(let a, _): return a.count; case .object(let o, _): return o.count; default: return 0 } }
}

struct JSONLine: Identifiable {
    let id: String; let depth: Int; let lineNumber: Int; let content: LineContent
    enum LineContent { case opening(key: String?, node: BoringJSONNode, bracket: String); case value(key: String?, node: BoringJSONNode, isLast: Bool); case closing(bracket: String, isLast: Bool) }
}

struct JSONHistoryItem: Identifiable, Codable {
    let id: UUID; let timestamp: Date; let content: String; let preview: String
    init(content: String) {
        self.id = UUID(); self.timestamp = Date(); self.content = content
        let clean = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        self.preview = String(clean.prefix(30))
    }
}

class JSONHistoryManager: ObservableObject {
    @Published var items: [JSONHistoryItem] = []
    private let storageKey = "boring.notch.json.history"
    init() { loadHistory(); cleanupOldItems() }
    func addEntry(_ content: String) {
        // 如果内容已存在，先移除旧的记录
        items.removeAll { $0.content == content }
        
        // 创建新记录（带最新时间戳）并插入顶部
        let newItem = JSONHistoryItem(content: content)
        items.insert(newItem, at: 0)
        
        // 最多保留 50 条
        if items.count > 50 { items.removeLast() }
        saveHistory()
    }
    func cleanupOldItems() { let now = Date(); items.removeAll { now.timeIntervalSince($0.timestamp) > 86400 }; saveHistory() }
    private func saveHistory() { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: storageKey) } }
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: storageKey), let decoded = try? JSONDecoder().decode([JSONHistoryItem].self, from: data) { self.items = decoded }
    }
}

@MainActor
class JSONViewerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = JSONViewerWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window); setupWindow()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func setupWindow() {
        guard let window = window else { return }
        window.title = "JSON Viewer"; window.backgroundColor = NSColor(JSONIDETheme.editorBackground)
        window.minSize = NSSize(width: 600, height: 400); window.delegate = self
    }
    func showWindow(with jsonText: String) {
        let hostingView = NSHostingView(rootView: JSONViewerContentView(jsonText: jsonText))
        window?.contentView = hostingView; NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); window?.center(); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { if !(SettingsWindowController.shared.window?.isVisible ?? false) { NSApp.setActivationPolicy(.accessory) } }
}

struct JSONViewerContentView: View {
    @State var jsonText: String
    @StateObject private var historyManager = JSONHistoryManager()
    @State private var showSidebar: Bool = true
    @State private var parsedJSON: BoringJSONNode?
    @State private var parseError: String?
    @State private var expandedPaths: Set<String> = ["root"]
    @State private var searchText: String = ""
    @State private var showRawText: Bool = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoomScale: CGFloat = 1.0
    @State private var searchMatches: [String] = []
    @State private var currentMatchIndex: Int = 0
    @FocusState private var searchFieldFocused: Bool
    @State private var formattedJSONLines: [String] = []
    
    var visibleLines: [JSONLine] {
        guard let json = parsedJSON else { return [] }
        var lines: [JSONLine] = []
        flatten(json, key: nil, path: "root", depth: 0, lineNumber: 1, isLast: true, into: &lines)
        return lines
    }
    
    var body: some View {
        HStack(spacing: 0) {
            if showSidebar { historySidebar.frame(width: 200).background(JSONIDETheme.gutterBackground); Divider().background(Color.white.opacity(0.1)) }
            VStack(spacing: 0) {
                toolbar; Divider().background(Color.white.opacity(0.1))
                if let error = parseError { errorView(error) }
                else if let json = parsedJSON { if showRawText { rawTextView } else { ideStyleTreeView(json) } }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .background(JSONIDETheme.editorBackground).preferredColorScheme(.dark)
        .onAppear { parseJSON(); historyManager.addEntry(jsonText) }
        .onChange(of: jsonText) { _, _ in parseJSON() } // 内容变化时重新解析
        .onChange(of: searchText) { _, newValue in updateSearchMatches(newValue) }
        .modifier(LocalKeyEventMonitor(onCommandF: { searchFieldFocused = true }, onEnter: { if searchFieldFocused && !searchMatches.isEmpty { navigateToNextMatch() } }, onShiftEnter: { if searchFieldFocused && !searchMatches.isEmpty { navigateToPreviousMatch() } }, onEscape: { if searchFieldFocused { searchFieldFocused = false; searchText = "" } }))
        .modifier(CommandScrollZoomModifier(zoomScale: $zoomScale, baseZoomScale: $baseZoomScale))
    }
    
    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HISTORY (24H)").font(.system(size: 10, weight: .bold)).foregroundColor(JSONIDETheme.lineNumberColor).padding(.horizontal, 12).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { ForEach(historyManager.items) { item in historyItemView(item) } }.padding(.horizontal, 8)
            }
        }
    }
    
    private func historyItemView(_ item: JSONHistoryItem) -> some View {
        let isSelected = item.content == jsonText
        return Button(action: {
            if !isSelected {
                withAnimation { jsonText = item.content }
                historyManager.addEntry(item.content) // 点击时主动激活该条记录
            }
        }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.timestamp, style: .time).font(.system(size: 10, weight: .medium)).foregroundColor(isSelected ? .white : JSONIDETheme.lineNumberColor)
                Text(item.preview).font(.system(size: 11)).foregroundColor(isSelected ? JSONIDETheme.keyColor : .white.opacity(0.6)).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(isSelected ? Color.white.opacity(0.1) : Color.clear).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: { withAnimation { showSidebar.toggle() } }) { Image(systemName: "sidebar.left").font(.system(size: 11)).foregroundColor(showSidebar ? .white : JSONIDETheme.lineNumberColor).frame(width: 24, height: 24) }.buttonStyle(.plain)
            Divider().frame(height: 16)
            HStack(spacing: 0) {
                toolbarButton(icon: "list.bullet.indent", isActive: !showRawText, action: { showRawText = false })
                toolbarButton(icon: "doc.plaintext", isActive: showRawText, action: { showRawText = true })
            }.background(Color.white.opacity(0.05)).cornerRadius(6)
            HStack(spacing: 4) { Image(systemName: "magnifyingglass").font(.system(size: 10)); Text("\(Int(zoomScale * 100))%").font(.system(size: 10, design: .monospaced)) }
                .foregroundColor(zoomScale == 1.0 ? JSONIDETheme.lineNumberColor : .white).padding(.horizontal, 8).padding(.vertical, 4).background(zoomScale == 1.0 ? Color.clear : Color.white.opacity(0.1)).cornerRadius(6)
                .onTapGesture { withAnimation { zoomScale = 1.0; baseZoomScale = 1.0 } }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(JSONIDETheme.lineNumberColor).font(.system(size: 11))
                TextField("搜索...", text: $searchText).textFieldStyle(.plain).font(.system(size: 12)).frame(minWidth: 120).focused($searchFieldFocused)
                if !searchText.isEmpty { Text("\(currentMatchIndex + 1)/\(searchMatches.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(JSONIDETheme.keyColor) }
            }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.white.opacity(0.06)).cornerRadius(6)
            Spacer(); toolbarIconButton(icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", tooltip: "展开", action: expandAll)
            toolbarIconButton(icon: "arrow.down.right.and.arrow.up.left", tooltip: "折叠", action: collapseAll)
            toolbarIconButton(icon: "doc.on.doc", tooltip: "复制", action: copyFormatted)
        }.padding(.horizontal, 14).padding(.vertical, 10).background(JSONIDETheme.gutterBackground)
    }
    
    private func toolbarButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundColor(isActive ? .white : JSONIDETheme.lineNumberColor).frame(width: 28, height: 24).background(isActive ? Color.white.opacity(0.1) : Color.clear) }.buttonStyle(.plain)
    }
    
    private func toolbarIconButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11)).foregroundColor(JSONIDETheme.lineNumberColor).frame(width: 24, height: 24) }.buttonStyle(.plain).help(tooltip)
    }
    
    private func ideStyleTreeView(_ json: BoringJSONNode) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleLines) { line in JSONLineRow(line: line, expandedPaths: $expandedPaths, searchText: searchText, currentMatchPath: searchMatches.isEmpty ? nil : searchMatches[currentMatchIndex]) }
                    }.padding(.vertical, 12).padding(.trailing, 12).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .id(jsonText.hashValue) // 强制刷新
                .onChange(of: currentMatchIndex) { _, idx in if !searchMatches.isEmpty { let p = searchMatches[idx]; expandToPath(p); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { scrollProxy.scrollTo(p, anchor: .center) } } } }
            }
            .gesture(MagnificationGesture().onChanged { zoomScale = min(max(baseZoomScale * $0, 0.5), 3.0) }.onEnded { _ in baseZoomScale = zoomScale })
        }.environment(\.jsonFontSize, 12 * zoomScale)
    }

    private var rawTextView: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) { ForEach(1...max(1, formattedJSONLines.count), id: \.self) { line in Text("\(line)").font(.system(size: 11, design: .monospaced)).foregroundColor(JSONIDETheme.lineNumberColor).frame(height: 18).padding(.trailing, 12) } }.frame(width: 50).padding(.vertical, 8).background(JSONIDETheme.gutterBackground)
                VStack(alignment: .leading, spacing: 0) { ForEach(Array(formattedJSONLines.enumerated()), id: \.offset) { _, line in Text(AttributedString(line)).font(.system(size: 12, design: .monospaced)).frame(height: 18) } }.padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private func errorView(_ error: String) -> some View { VStack { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundColor(.orange); Text(error) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    private func expandAll() { var all = Set<String>(); collectAllPathsInto(parsedJSON!, path: "root", paths: &all); withAnimation { expandedPaths = all } }
    private func collapseAll() { withAnimation { expandedPaths = ["root"] } }
    private func copyFormatted() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(formattedJSONLines.joined(separator: "\n"), forType: .string) }
    
    private func parseJSON() {
        guard let data = jsonText.data(using: .utf8) else { parseError = "无法编码文本"; return }
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let node = BoringJSONNode.parse(json)
            
            // 立即赋值，并在主线程完成后续工作
            self.parsedJSON = node
            
            // 重新计算路径
            var allPaths = Set<String>()
            collectAllPathsInto(node, path: "root", paths: &allPaths)
            self.expandedPaths = allPaths
            
            if let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { 
                self.formattedJSONLines = String(data: pretty, encoding: .utf8)?.components(separatedBy: "\n") ?? [] 
            }
            self.parseError = nil
        } catch { 
            parseError = "解析错误"
            formattedJSONLines = jsonText.components(separatedBy: "\n") 
        }
    }
    
    private func collectAllPathsInto(_ node: BoringJSONNode, path: String, paths: inout Set<String>) {
        paths.insert(path)
        switch node {
        case .array(let arr, _): for (i, v) in arr.enumerated() { collectAllPathsInto(v, path: "\(path)[\(i)]", paths: &paths) }
        case .object(let obj, _): for p in obj { collectAllPathsInto(p.value, path: "\(path).\(p.key)", paths: &paths) }
        default: break
        }
    }
    private func updateSearchMatches(_ q: String) {
        guard !q.isEmpty, let j = parsedJSON else { searchMatches = []; return }
        var m: [String] = []; collectSearchMatches(j, path: "root", query: q.lowercased(), matches: &m)
        searchMatches = m; currentMatchIndex = 0; if let f = m.first { expandToPath(f) }
    }
    private func collectSearchMatches(_ node: BoringJSONNode, path: String, query: String, matches: inout [String]) {
        switch node {
        case .string(let s): if s.lowercased().contains(query) { matches.append(path) }
        case .number(let n): if String(n).contains(query) { matches.append(path) }
        case .array(let a, _): for (i, v) in a.enumerated() { collectSearchMatches(v, path: "\(path)[\(i)]", query: query, matches: &matches) }
        case .object(let o, _): for p in o { if p.key.lowercased().contains(query) { matches.append("\(path).\(p.key)") } else { collectSearchMatches(p.value, path: "\(path).\(p.key)", query: query, matches: &matches) } }
        default: break
        }
    }
    private func expandToPath(_ path: String) {
        var curr = "root"; expandedPaths.insert(curr)
        let parts = path.replacingOccurrences(of: "root.", with: "").components(separatedBy: ".")
        for p in parts { if p == "root" { continue }; curr += "." + p; expandedPaths.insert(curr) }
    }
    private func navigateToNextMatch() { if !searchMatches.isEmpty { currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count; expandToPath(searchMatches[currentMatchIndex]) } }
    private func navigateToPreviousMatch() { if !searchMatches.isEmpty { currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count; expandToPath(searchMatches[currentMatchIndex]) } }
    private func flatten(_ node: BoringJSONNode, key: String?, path: String, depth: Int, lineNumber: Int, isLast: Bool, into lines: inout [JSONLine]) {
        switch node {
        case .array(let arr, _):
            let isExpanded = expandedPaths.contains(path)
            lines.append(JSONLine(id: path, depth: depth, lineNumber: lineNumber, content: .opening(key: key, node: node, bracket: "[")))
            if isExpanded {
                var currentLine = lineNumber + 1
                for (index, item) in arr.enumerated() { flatten(item, key: "[\(index)]", path: "\(path)[\(index)]", depth: depth + 1, lineNumber: currentLine, isLast: index == arr.count - 1, into: &lines); currentLine += item.totalLinesCount }
                lines.append(JSONLine(id: "\(path)_closing", depth: depth, lineNumber: lineNumber + node.totalLinesCount - 1, content: .closing(bracket: "]", isLast: isLast)))
            }
        case .object(let obj, _):
            let isExpanded = expandedPaths.contains(path)
            lines.append(JSONLine(id: path, depth: depth, lineNumber: lineNumber, content: .opening(key: key, node: node, bracket: "{")))
            if isExpanded {
                var currentLine = lineNumber + 1
                for (index, pair) in obj.enumerated() { flatten(pair.value, key: pair.key, path: "\(path).\(pair.key)", depth: depth + 1, lineNumber: currentLine, isLast: index == obj.count - 1, into: &lines); currentLine += pair.value.totalLinesCount }
                lines.append(JSONLine(id: "\(path)_closing", depth: depth, lineNumber: lineNumber + node.totalLinesCount - 1, content: .closing(bracket: "}", isLast: isLast)))
            }
        default: lines.append(JSONLine(id: path, depth: depth, lineNumber: lineNumber, content: .value(key: key, node: node, isLast: isLast)))
        }
    }
}

struct JSONLineRow: View {
    let line: JSONLine; @Binding var expandedPaths: Set<String>; let searchText: String; let currentMatchPath: String?
    @Environment(\.jsonFontSize) private var fontSize
    private var lineHeight: CGFloat { fontSize * 1.67 }; private var indentWidth: CGFloat { fontSize * 1.33 }; private var lineNumberWidth: CGFloat { fontSize * 3.5 }
    private var isExpanded: Bool { expandedPaths.contains(line.id) }
    private var isCurrentMatch: Bool { line.id == currentMatchPath }
    var body: some View {
        HStack(spacing: 0) {
            Text("\(line.lineNumber)").font(.system(size: fontSize * 0.9, design: .monospaced)).foregroundColor(JSONIDETheme.lineNumberColor).frame(width: lineNumberWidth, alignment: .trailing).padding(.trailing, 8)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            HStack(spacing: 0) { ForEach(0..<line.depth, id: \.self) { _ in ZStack(alignment: .center) { Color.clear.frame(width: indentWidth); Rectangle().fill(JSONIDETheme.indentGuideColor).frame(width: 1) } } }
            Group {
                if case .opening = line.content { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: fontSize * 0.75, weight: .medium)).foregroundColor(JSONIDETheme.foldIndicatorColor).frame(width: indentWidth, height: indentWidth).contentShape(Rectangle()).onTapGesture { toggleExpand() } }
                else { Color.clear.frame(width: indentWidth, height: indentWidth) }
            }
            HStack(spacing: 0) {
                switch line.content {
                case .opening(let key, let node, let bracket):
                    if let k = key { keyView(k); Text(": ").foregroundColor(JSONIDETheme.colonColor) }
                    if isExpanded { Text(bracket).foregroundColor(JSONIDETheme.bracketColor) }
                    else { collapsedPreview(node, bracket: bracket) }
                case .value(let key, let node, let isLast):
                    if let k = key { keyView(k); Text(": ").foregroundColor(JSONIDETheme.colonColor) }
                    valueView(node); if !isLast { Text(",").foregroundColor(JSONIDETheme.colonColor) }
                case .closing(let bracket, let isLast):
                    Text(bracket).foregroundColor(JSONIDETheme.bracketColor); if !isLast { Text(",").foregroundColor(JSONIDETheme.colonColor) }
                }
            }.font(.system(size: fontSize, design: .monospaced))
            Spacer(minLength: 0)
        }.frame(height: lineHeight).id(line.id)
    }
    @ViewBuilder private func keyView(_ k: String) -> some View { highlightedText("\"\(k)\"", in: k, baseColor: JSONIDETheme.keyColor) }
    private func collapsedPreview(_ n: BoringJSONNode, bracket: String) -> some View {
        let cb = bracket == "{" ? "}" : "]"; let label = bracket == "{" ? "\(n.childCount) keys" : "\(n.childCount) items"
        return HStack(spacing: 2) { Text(bracket); Text("..."); Text(cb); Text(" // \(label)").foregroundColor(JSONIDETheme.lineNumberColor).font(.system(size: fontSize * 0.85)) }.foregroundColor(JSONIDETheme.bracketColor).onTapGesture { toggleExpand() }
    }
    @ViewBuilder private func valueView(_ n: BoringJSONNode) -> some View {
        switch n {
        case .string(let s): highlightedText("\"\(s)\"", in: s, baseColor: JSONIDETheme.stringColor)
        case .number(let v): let s = String(v); highlightedText(s, in: s, baseColor: JSONIDETheme.numberColor)
        case .bool(let b): let s = b ? "true" : "false"; highlightedText(s, in: s, baseColor: JSONIDETheme.boolColor)
        case .null: highlightedText("null", in: "null", baseColor: JSONIDETheme.nullColor)
        default: Text("")
        }
    }
    @ViewBuilder private func highlightedText(_ displayText: String, in searchableText: String, baseColor: Color) -> some View {
        if !searchText.isEmpty && searchableText.localizedCaseInsensitiveContains(searchText) {
            let matches = findAllMatches(in: searchableText, searchText: searchText)
            if matches.isEmpty { Text(displayText).foregroundColor(baseColor) }
            else {
                let prefixLength = displayText.hasPrefix("\"") ? 1 : 0
                let highlightColor = isCurrentMatch ? Color.orange : JSONIDETheme.searchHighlight
                let textColor = isCurrentMatch ? Color.black : baseColor
                HStack(spacing: 0) {
                    let segments = buildSegments(displayText: displayText, searchableText: searchableText, matches: matches, prefixLength: prefixLength)
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.isMatch { Text(segment.text).foregroundColor(textColor).background(highlightColor).cornerRadius(2) }
                        else { Text(segment.text).foregroundColor(baseColor) }
                    }
                }
            }
        } else { Text(displayText).foregroundColor(baseColor) }
    }
    private func findAllMatches(in text: String, searchText: String) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []; var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: searchText, options: .caseInsensitive, range: start..<text.endIndex) { matches.append(range); start = range.upperBound }
        return matches
    }
    private struct TextSegment { let text: String; let isMatch: Bool }
    private func buildSegments(displayText: String, searchableText: String, matches: [Range<String.Index>], prefixLength: Int) -> [TextSegment] {
        var segments: [TextSegment] = []; var current = displayText.startIndex
        for match in matches {
            let lower = searchableText.distance(from: searchableText.startIndex, to: match.lowerBound)
            let upper = searchableText.distance(from: searchableText.startIndex, to: match.upperBound)
            let dLower = min(prefixLength + lower, displayText.count); let dUpper = min(prefixLength + upper, displayText.count)
            let mStart = displayText.index(displayText.startIndex, offsetBy: dLower); let mEnd = displayText.index(displayText.startIndex, offsetBy: dUpper)
            if current < mStart { segments.append(TextSegment(text: String(displayText[current..<mStart]), isMatch: false)) }
            if mStart < mEnd { segments.append(TextSegment(text: String(displayText[mStart..<mEnd]), isMatch: true)) }
            current = mEnd
        }
        if current < displayText.endIndex { segments.append(TextSegment(text: String(displayText[current..<displayText.endIndex]), isMatch: false)) }
        return segments
    }
    private func toggleExpand() { withAnimation(.easeOut(duration: 0.1)) { if expandedPaths.contains(line.id) { expandedPaths.remove(line.id) } else { expandedPaths.insert(line.id) } } }
}
