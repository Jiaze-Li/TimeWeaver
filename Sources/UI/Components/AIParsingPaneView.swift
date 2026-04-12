import SwiftUI
import AppKit

struct AIParsingPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(
                title: "AI Parsing",
                subtitle: "For most customers, setup is just: choose a supported AI platform, paste the API key, and let the app fill the endpoint and default model."
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    FieldLabel(title: "Parser Mode")
                    Text("(\(model.ui.parserMode.inlineSummary))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: deferredBinding(model: model, \.parserMode)) {
                    ForEach(ParserMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: model.ui.parserMode) { _ in
                    model.parserSettingsChanged()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "AI Platform")
                HStack(spacing: 10) {
                    Picker("", selection: deferredBinding(model: model, \.aiProvider)) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.pickerTitle).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
                    .onChange(of: model.ui.aiProvider) { _ in
                        model.aiProviderChanged()
                    }
                    Spacer(minLength: 0)
                }
                Text(model.ui.aiProvider.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "API Key")
                SecureField("Stored in macOS Keychain", text: deferredBinding(model: model, \.aiAPIKey))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onChange(of: model.ui.aiAPIKey) { _ in
                        model.parserSettingsChanged()
                    }
            }

            DisclosureGroup(isExpanded: deferredBinding(model: model, \.showAdvancedAISettings)) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            aiEndpointField
                            aiModelField
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            aiEndpointField
                            aiModelField
                        }
                    }
                    Text("Supported platforms auto-fill the endpoint and default model. Custom mode keeps the endpoint editable for providers or gateways outside the preset list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Leave Model Override blank to use the app's recommended model automatically. Image sources may use a different built-in model than sheet sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                Text("Advanced AI Settings")
                    .font(.subheadline.weight(.medium))
            }

            Text("Approved AI layouts stored: \(model.ui.aiApprovals.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var aiEndpointField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "API Endpoint")
            TextField(model.ui.aiProvider.defaultEndpointURL.isEmpty ? "Enter provider endpoint" : model.ui.aiProvider.defaultEndpointURL, text: deferredBinding(model: model, \.aiEndpointURL))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.ui.aiEndpointURL) { _ in
                    model.parserSettingsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiModelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Model Override")
            TextField(model.ui.aiProvider == .custom ? "Enter model name" : "Auto (\(model.ui.aiProvider.automaticModelSummary))", text: deferredBinding(model: model, \.aiModel))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.ui.aiModel) { _ in
                    model.parserSettingsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
