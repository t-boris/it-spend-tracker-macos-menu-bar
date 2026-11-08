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
                LabeledContent("Existing tags") {
                    HStack {
                        ForEach(suggestions.prefix(8), id: \.self) { tag in
                            Button { text = (entered + [tag]).joined(separator: ", ") } label: { TagChip(tag: tag) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { text = service.tags(for: target).joined(separator: ", ") }
    }
}

/// The tags of one target as small chips.
struct TagChips: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { TagChip(tag: $0) }
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
