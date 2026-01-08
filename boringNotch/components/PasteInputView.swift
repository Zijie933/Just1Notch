//
//  PasteInputView.swift
//  boringNotch
//
//  Created on 2026-01-07.
//

import SwiftUI
import AppKit

struct PasteInputView: View {
    @State private var inputText: String = ""
    @State private var isHovering: Bool = false
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14))
                .foregroundColor(.gray)
            
            TextField("粘贴 JSON 后按 Enter...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($isFocused)
                .onSubmit {
                    handleSubmit()
                }
            
            if !inputText.isEmpty {
                Button(action: { inputText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isHovering ? 0.12 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isFocused ? 0.3 : 0.1), lineWidth: 1)
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
    
    private func handleSubmit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        // Open JSON viewer window
        Task { @MainActor in
            JSONViewerWindowController.shared.showWindow(with: text)
        }
        
        // Clear input
        inputText = ""
        isFocused = false
    }
}

#Preview {
    PasteInputView()
        .padding()
        .background(Color.black)
}
