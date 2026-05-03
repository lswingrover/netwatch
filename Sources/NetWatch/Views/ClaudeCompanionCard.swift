/// ClaudeCompanionCard.swift — Reusable "Ask Claude" call-to-action component
///
/// Appears at the bottom of every device overview tab and on Stack Health.
/// Clicking the button:
///   1. Copies a pre-formatted context string to the clipboard
///   2. Opens Claude (tries claude:// URL scheme first, falls back to claude.ai/new in browser)
///
/// Usage:
///   ClaudeCompanionCard(context: buildContext())
///
/// The `context` string should be a compact, readable summary of the current
/// device/network state — headings, bullet points, and key numbers. The card
/// adds a standard preamble and prompt footer automatically.

import SwiftUI

// MARK: - Shared helpers

/// Formats a full Claude prompt from a data snapshot and optional question.
func buildClaudePrompt(context: String, hint: String) -> String {
    let question = hint.isEmpty
        ? "What does this tell me about my network health, and is there anything I should act on?"
        : hint
    return """
    You are NetWatch, an expert network diagnostics assistant. \
    I'm sharing a live snapshot of my home network from the NetWatch macOS app. \
    Please interpret the data and answer my question.

    --- CURRENT NETWORK STATE ---
    \(context)
    --- END OF SNAPSHOT ---

    My question: \(question)

    Please:
    1. Interpret the key metrics in plain English.
    2. Flag anything that looks abnormal or worth investigating.
    3. Give me concrete next steps if any action is needed.
    """
}

/// Copies prompt to clipboard and launches Claude Desktop (or claude.ai as fallback).
func launchClaude(context: String, hint: String = "") {
    let prompt = buildClaudePrompt(context: context, hint: hint)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)

    // Try Claude Desktop deep-link first
    let claudeApp  = URL(string: "claude://")!
    let claudeWeb  = URL(string: "https://claude.ai/new")!
    if !NSWorkspace.shared.open(claudeApp) {
        NSWorkspace.shared.open(claudeWeb)
    }
}

// MARK: - Full card (bottom of overview tabs)

struct ClaudeCompanionCard: View {

    let context:    String
    var promptHint: String = ""

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                claudeIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask Claude")
                        .font(.subheadline.bold())
                    Text("Get an expert read on what this data means for your network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    launchClaude(context: context, hint: promptHint)
                    flashCopied()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "arrow.up.right.square")
                            .font(.caption)
                        Text(copied ? "Copied!" : "Open Claude")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(claudeOrange)
                .controlSize(.small)
            }

            if !promptHint.isEmpty {
                Text("\u{201C}\(promptHint)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .padding(.leading, 38)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(claudeOrange.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(claudeOrange.opacity(0.18), lineWidth: 1))
        )
    }

    private func flashCopied() {
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { withAnimation { copied = false } }
        }
    }
}

// MARK: - Compact button variant (for headers)

struct ClaudeCompanionButton: View {

    let context:    String
    var label:      String = "Ask Claude"
    var promptHint: String = ""

    @State private var copied = false

    var body: some View {
        Button {
            launchClaude(context: context, hint: promptHint)
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run { withAnimation { copied = false } }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "sparkles")
                    .font(.caption)
                Text(copied ? "Copied!" : label)
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .help("Copy network context to clipboard and open Claude for expert analysis")
    }
}

// MARK: - Shared styling

private let claudeOrange = Color(red: 0.93, green: 0.45, blue: 0.32)

private var claudeIcon: some View {
    ZStack {
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(
                colors: [Color(red: 0.87, green: 0.60, blue: 0.38),
                         claudeOrange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 28, height: 28)
        Text("C")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
    }
}
