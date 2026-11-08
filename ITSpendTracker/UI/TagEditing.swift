import SwiftUI

extension TagTarget {
    /// What kind of thing the target is, for the editor and the Tags view.
    var typeTitle: LocalizedStringKey {
        switch kind {
        case .service: "Service"
        case .key: "Key"
        case .usageProject: "Project"
        case .breakdownItem:
            switch dimension {
            case .account: "Account"
            case .lineItem: "Model / line item"
            case .project, .none: "Project"
            }
        }
    }
}

/// Edits the user's tags of one target: a service, a key, a breakdown item or a Neon project (REQ-017, DEC-036).
/// Tags are comma-separated; existing tags of every target type can be tapped to add.
struct TagsForm: View {
    @Environment(AppModel.self) private var model
    let service: TrackedService
    let target: TagTarget
    /// What the target is called now. It is stored with the tags so the target can still be named once the provider
    /// stops listing it (DEC-037).
    let name: String
    @State private var text = ""

    private var entered: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        FormSheet(title: "Tags", canSave: true) {
            try model.store.setTags(entered, for: target, displayName: name, of: service)
        } content: {
            LabeledContent(target.typeTitle, value: name)
            if target.kind != .service {
                LabeledContent("Service", value: service.name)
            }
            TextField("Tags", text: $text, prompt: Text("e.g. ci-bot, client X"))
            Text("Separate tags with commas. Tags group services, keys and items across services on the Tags tab.")
                .font(.caption).foregroundStyle(.secondary)
            let suggestions = model.store.allTags.filter { tag in !entered.contains { $0.lowercased() == tag.lowercased() } }
            if !suggestions.isEmpty {
                TagSuggestions(tags: suggestions) { text = (entered + [$0]).joined(separator: ", ") }
            }
        }
        .onAppear { text = service.tags(for: target).joined(separator: ", ") }
    }
}

/// Existing tags the user can tap to add; they wrap onto further lines instead of being squeezed.
struct TagSuggestions: View {
    let tags: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Existing tags")
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button { pick(tag) } label: { TagChip(tag: tag) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The tags of one target as small chips that wrap onto further lines.
struct TagChips: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { TagChip(tag: $0) }
        }
    }
}

/// Places its children left to right and starts a new line when the next one does not fit. Every child keeps its natural
/// size, so chips are never squeezed or broken inside; a child wider than the line gets a line of its own.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// Offsets of the children and the size of the whole, for the sizes the children want and the width on offer.
    static func arrange(_ sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (offsets, CGSize(width: widest, height: sizes.isEmpty ? 0 : y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.arrange(sizes, maxWidth: proposal.width ?? .infinity, spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let arranged = Self.arrange(sizes, maxWidth: bounds.width, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let offset = arranged.offsets[index]
            subview.place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: min(sizes[index].width, bounds.width), height: sizes[index].height))
        }
    }
}

/// A tag icon that opens the editor of one target; filled while the target has tags (REQ-017).
struct TagButton: View {
    let service: TrackedService
    let target: TagTarget
    let name: String
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Image(systemName: service.tags(for: target).isEmpty ? "tag" : "tag.fill")
        }
        .buttonStyle(.borderless)
        .help(Text("Edit tags…"))
        .accessibilityLabel(Text("Edit tags…"))
        .sheet(isPresented: $editing) { TagsForm(service: service, target: target, name: name) }
    }
}

/// A "Tags" line for one target: its chips and the button that opens the editor.
struct TagRow: View {
    let service: TrackedService
    let target: TagTarget
    let name: String

    var body: some View {
        LabeledContent("Tags") {
            HStack {
                let tags = service.tags(for: target)
                if tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                } else {
                    TagChips(tags: tags)
                }
                TagButton(service: service, target: target, name: name)
            }
        }
    }
}
