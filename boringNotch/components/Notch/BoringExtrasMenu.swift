//
//  BoringExtrasMenu.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import SwiftUI
import Defaults

struct BoringLargeButtons: View {
    var action: () -> Void
    var icon: Image
    var title: String
    var body: some View {
        Button (
            action:action,
            label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12.0).fill(.black).frame(width: 70, height: 70)
                    VStack(spacing: 8) {
                        icon.resizable()
                            .aspectRatio(contentMode: .fit).frame(width:20)
                        Text(title).font(.body)
                    }
                }
            }).buttonStyle(PlainButtonStyle()).shadow(color: .black.opacity(0.5), radius: 10)
    }
}

struct BoringExtrasMenu : View {
    @ObservedObject var vm: BoringViewModel
    @Default(.showJSONViewer) var showJSONViewer
    
    var body: some View {
        VStack{
            HStack(spacing: 20)  {
                if showJSONViewer {
                    jsonViewer
                }
                settings
                close
            }
        }
    }
    
    var jsonViewer: some View {
        BoringLargeButtons(
            action: {
                // 从剪贴板获取文本并打开 JSON 查看器
                let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
                Task { @MainActor in
                    if clipboardText.isEmpty {
                        JSONViewerWindowController.shared.showWindow(with: "剪贴板为空，请先复制 JSON 文本")
                    } else {
                        JSONViewerWindowController.shared.showWindow(with: clipboardText)
                    }
                }
            },
            icon: Image(systemName: "doc.text.magnifyingglass"),
            title: "JSON"
        )
    }
    
    var github: some View {
        BoringLargeButtons(
            action: {
                if let url = URL(string: "https://github.com/Zijie933") {
                    NSWorkspace.shared.open(url)
                }
            },
            icon: Image(.github),
            title: "Checkout"
        )
    }
    
    var settings: some View {
        Button(action: {
            SettingsWindowController.shared.showWindow()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12.0).fill(.black).frame(width: 70, height: 70)
                VStack(spacing: 8) {
                    Image(systemName: "gear").resizable()
                        .aspectRatio(contentMode: .fit).frame(width:20)
                    Text("Settings").font(.body)
                }
            }
        }
        .buttonStyle(PlainButtonStyle()).shadow(color: .black.opacity(0.5), radius: 10)
    }
    
    var hide: some View {
        BoringLargeButtons(
            action: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    //vm.openMusic()
                }
            },
            icon: Image(systemName: "arrow.down.forward.and.arrow.up.backward"),
            title: "Hide"
        )
    }
    
    var close: some View {
        BoringLargeButtons(
            action: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NSApp.terminate(nil)
                    }
                }
            },
            icon: Image(systemName: "xmark"),
            title: "Exit"
        )
    }
}


#Preview {
    BoringExtrasMenu(vm: .init())
}
