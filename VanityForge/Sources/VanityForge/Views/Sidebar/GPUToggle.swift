import SwiftUI

/// Переключатель «Считать на видеокарте» — общий для кошельков и контрактов.
struct GPUToggle: View {
    @Environment(SessionViewModel.self) private var session
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { session.useGPU }, set: {
                session.useGPU = $0
                session.saveCreate2Settings()
            })) {
                Label(session.t(.useGPU), systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(session.isRunning)
            if session.useGPU {
                HStack(spacing: 6) {
                    Text(session.t(.gpuLoadLabel))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        ForEach(SessionViewModel.gpuLoadSteps, id: \.self) { step in
                            Button {
                                session.gpuLoad = step
                                session.saveCreate2Settings()
                            } label: {
                                Text("\(step)%")
                                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(session.gpuLoad == step ? Color.white.opacity(0.13) : Color.white.opacity(0.03)))
                                    .foregroundStyle(session.gpuLoad == step ? .primary : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .disabled(session.isRunning)
            }
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
