import SwiftUI
import MeetsCore

struct MeetingTemplatesManagerView: View {
    let appState: AppState
    let controller: MeetsController
    let onClose: () -> Void

    @State private var isCreatingTemplate = false
    @State private var editingTemplateID: String?
    @State private var draftTemplateName = ""
    @State private var draftTemplatePrompt = ""
    @State private var draftTemplateIcon = MeetingTemplates.customIconFallback
    @State private var showNameValidationError = false
    @State private var showPromptValidationError = false
    @State private var templateToDelete: CustomMeetingTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manage Templates")
                        .font(MeetsTheme.title2())
                        .foregroundStyle(MeetsTheme.textPrimary)
                    Text("Create reusable prompt-based note formats for meetings.")
                        .font(MeetsTheme.callout())
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                HStack(spacing: MeetsTheme.spacing8) {
                    if isCreatingTemplate || editingTemplateID != nil {
                        actionButton("Cancel", systemImage: "xmark") {
                            resetTemplateEditor()
                        }
                    } else {
                        actionButton("New template", systemImage: "plus") {
                            beginCreatingTemplate()
                        }
                    }

                    actionButton("Done", systemImage: "checkmark") {
                        onClose()
                    }
                    .disabled(isEditingTemplateInProgress)
                    .opacity(isEditingTemplateInProgress ? 0.55 : 1)
                    .help(isEditingTemplateInProgress ? "Finish or cancel template editing before closing." : "Close template manager")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: MeetsTheme.spacing16) {
                    templateSection(title: "Built-in Templates") {
                        VStack(spacing: MeetsTheme.spacing8) {
                            ForEach(controller.builtInMeetingTemplates()) { template in
                                builtInTemplateRow(template)
                            }
                        }
                    }

                    templateSection(title: "Custom Templates") {
                        if controller.customMeetingTemplates().isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: MeetsTheme.spacing8) {
                                ForEach(controller.customMeetingTemplates()) { template in
                                    customTemplateRow(template)
                                }
                            }
                        }
                    }

                    if isCreatingTemplate || editingTemplateID != nil {
                        customTemplateEditor
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, MeetsTheme.spacing4)
            }
        }
        .padding(MeetsTheme.spacing24)
        .frame(width: 820, height: 620)
        .background(MeetsTheme.backgroundBase)
        .alert(
            "Delete \"\(templateToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { templateToDelete != nil },
                set: { if !$0 { templateToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                templateToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let template = templateToDelete else { return }
                controller.deleteCustomMeetingTemplate(id: template.id)
                if editingTemplateID == template.id {
                    resetTemplateEditor()
                }
                templateToDelete = nil
            }
        } message: {
            Text("This template will be permanently removed. Existing meetings will keep their saved template snapshot.")
        }
    }

    private func templateSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            Text(title.uppercased())
                .font(MeetsTheme.captionMedium())
                .foregroundStyle(MeetsTheme.textTertiary)
            content()
        }
    }

    @ViewBuilder
    private func builtInTemplateRow(_ template: MeetingTemplateDefinition) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            HStack(alignment: .top, spacing: MeetsTheme.spacing12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: template.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(MeetsTheme.accent)
                        Text(template.title)
                            .font(MeetsTheme.captionMedium())
                            .foregroundStyle(MeetsTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(template.promptBody)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: MeetsTheme.spacing8) {
                    actionButton("Duplicate", systemImage: "doc.on.doc") {
                        beginDuplicatingTemplate(template)
                    }
                }
                .fixedSize()
            }
        }
        .padding(MeetsTheme.spacing12)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func beginDuplicatingTemplate(_ template: MeetingTemplateDefinition) {
        isCreatingTemplate = true
        editingTemplateID = nil
        draftTemplateName = "\(template.title) Copy"
        draftTemplatePrompt = template.promptBody
        draftTemplateIcon = MeetingTemplates.normalizedCustomIcon(named: template.icon)
        clearValidationErrors()
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: MeetsTheme.spacing8) {
            Image(systemName: MeetingTemplates.customIconFallback)
                .font(.system(size: 11))
                .foregroundStyle(MeetsTheme.textTertiary)
            Text("No custom templates yet.")
                .font(MeetsTheme.callout())
                .foregroundStyle(MeetsTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, MeetsTheme.spacing12)
        .padding(.vertical, 10)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func customTemplateRow(_ template: CustomMeetingTemplate) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            HStack(alignment: .top, spacing: MeetsTheme.spacing12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: template.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(MeetsTheme.accent)
                        Text(template.name)
                            .font(MeetsTheme.captionMedium())
                            .foregroundStyle(MeetsTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(template.prompt)
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: MeetsTheme.spacing8) {
                    actionButton("Edit", systemImage: "pencil") {
                        beginEditingTemplate(template)
                    }
                    actionButton("Delete", systemImage: "trash", role: .destructive) {
                        templateToDelete = template
                    }
                }
                .fixedSize()
            }
        }
        .padding(MeetsTheme.spacing12)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var customTemplateEditor: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
            Text(isCreatingTemplate ? "New template" : "Edit template")
                .font(MeetsTheme.captionMedium())
                .foregroundStyle(MeetsTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                TextField("Customer follow-up", text: $draftTemplateName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                showNameValidationError ? MeetsTheme.recording.opacity(0.75) : .clear,
                                lineWidth: 1
                            )
                    }
                    .onChange(of: draftTemplateName) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showNameValidationError = false
                        }
                    }
                if showNameValidationError {
                    Text("Enter a template name.")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.recording)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                customIconPicker
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                TextEditor(text: $draftTemplatePrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(MeetsTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160, maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .padding(MeetsTheme.spacing8)
                    .background(MeetsTheme.backgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                            .strokeBorder(
                                showPromptValidationError ? MeetsTheme.recording.opacity(0.75) : MeetsTheme.surfaceBorder,
                                lineWidth: 1
                            )
                    )
                    .onChange(of: draftTemplatePrompt) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showPromptValidationError = false
                        }
                    }
                if showPromptValidationError {
                    Text("Enter the prompt instructions for this template.")
                        .font(MeetsTheme.caption())
                        .foregroundStyle(MeetsTheme.recording)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                actionButton(
                    isCreatingTemplate ? "Create template" : "Save changes",
                    systemImage: isCreatingTemplate ? "plus.circle" : "checkmark.circle"
                ) {
                    saveTemplateEditor()
                }
            }
        }
        .padding(MeetsTheme.spacing12)
        .frame(maxWidth: .infinity)
        .background(MeetsTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func beginCreatingTemplate() {
        isCreatingTemplate = true
        editingTemplateID = nil
        draftTemplateName = ""
        draftTemplatePrompt = ""
        draftTemplateIcon = MeetingTemplates.customIconFallback
        clearValidationErrors()
    }

    private func beginEditingTemplate(_ template: CustomMeetingTemplate) {
        isCreatingTemplate = false
        editingTemplateID = template.id
        draftTemplateName = template.name
        draftTemplatePrompt = template.prompt
        draftTemplateIcon = MeetingTemplates.normalizedCustomIcon(named: template.icon)
        clearValidationErrors()
    }

    private func resetTemplateEditor() {
        isCreatingTemplate = false
        editingTemplateID = nil
        draftTemplateName = ""
        draftTemplatePrompt = ""
        draftTemplateIcon = MeetingTemplates.customIconFallback
        clearValidationErrors()
    }

    private func saveTemplateEditor() {
        let trimmedName = draftTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = draftTemplatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        showNameValidationError = trimmedName.isEmpty
        showPromptValidationError = trimmedPrompt.isEmpty
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }

        if let editingTemplateID {
            controller.updateCustomMeetingTemplate(
                id: editingTemplateID,
                name: trimmedName,
                prompt: trimmedPrompt,
                icon: draftTemplateIcon
            )
        } else {
            controller.createCustomMeetingTemplate(
                name: trimmedName,
                prompt: trimmedPrompt,
                icon: draftTemplateIcon
            )
        }
        resetTemplateEditor()
    }

    private var isEditingTemplateInProgress: Bool {
        isCreatingTemplate || editingTemplateID != nil
    }

    private func clearValidationErrors() {
        showNameValidationError = false
        showPromptValidationError = false
    }

    @ViewBuilder
    private var customIconPicker: some View {
        let columns = [
            GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 6)
        ]

        VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
            HStack(spacing: MeetsTheme.spacing8) {
                Image(systemName: draftTemplateIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MeetsTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(MeetsTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                Text(selectedIconLabel)
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(MeetingTemplates.customIconOptions) { icon in
                    Button {
                        draftTemplateIcon = icon.symbolName
                    } label: {
                        Image(systemName: icon.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(
                                draftTemplateIcon == icon.symbolName
                                    ? MeetsTheme.accent
                                    : MeetsTheme.textSecondary
                            )
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(
                                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                                    .fill(
                                        draftTemplateIcon == icon.symbolName
                                            ? MeetsTheme.accent.opacity(0.12)
                                            : MeetsTheme.backgroundRaised
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                                    .strokeBorder(
                                        draftTemplateIcon == icon.symbolName
                                            ? MeetsTheme.accent.opacity(0.35)
                                            : MeetsTheme.surfaceBorder,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(icon.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedIconLabel: String {
        MeetingTemplates.customIconOptions.first(where: { $0.symbolName == draftTemplateIcon })?.label ?? "Custom"
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isDestructive ? MeetsTheme.recording : MeetsTheme.textPrimary)
            .padding(.horizontal, MeetsTheme.spacing12)
            .padding(.vertical, 7)
            .background(isDestructive ? MeetsTheme.recording.opacity(0.1) : MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(
                        isDestructive ? MeetsTheme.recording.opacity(0.2) : MeetsTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
