import SwiftUI

struct ConnectionRail: View {
    struct Stage: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let tone: StatusTone
    }

    let stages: [Stage]

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 2)
                    .padding(.horizontal, 46)

                HStack(spacing: 0) {
                    ForEach(stages) { stage in
                        Circle()
                            .fill(stage.tone.color)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                            )
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 14)

            HStack(alignment: .top, spacing: 0) {
                ForEach(stages) { stage in
                    VStack(spacing: 3) {
                        Label(stage.title, systemImage: stage.icon)
                            .labelStyle(.titleOnly)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)

                        Text(stage.detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(stage.title): \(stage.detail), \(stage.tone.accessibilityDescription)"
                    )
                }
            }
        }
    }
}
