import SwiftUI

struct WorkdayHoursEditor: View {
    @Binding var start: String
    @Binding var end: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                startField
                endField
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                startField
                endField
            }
        }
        .controlSize(.small)
    }

    private var startField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Start")
            TextField("10:00", text: $start)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 88, idealWidth: 96, maxWidth: 120, alignment: .leading)
        }
    }

    private var endField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "End")
            TextField("20:00", text: $end)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 88, idealWidth: 96, maxWidth: 120, alignment: .leading)
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
        }
        .frame(minWidth: 88, idealWidth: 94, maxWidth: 100, alignment: .leading)
        .frame(minHeight: 56, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct PaneHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

struct SourceDropZone: View {
    let dropAction: ([URL]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop an image for instant import")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("The current Booking ID, Event Title, and Calendar will be used. Drop .xlsx files here only if you want to replace the saved source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isTargeted ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .dropDestination(for: URL.self) { items, _ in
            dropAction(items)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

