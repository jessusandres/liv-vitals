import SwiftUI

struct Sidebar: View {
    @Binding var selection: AppModule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Liv Vitals")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 44)
                .padding(.bottom, 12)

            ForEach(AppModule.Section.allCases, id: \.self) { section in
                if !section.rawValue.isEmpty {
                    Text(section.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                }
                ForEach(AppModule.allCases.filter { $0.section == section }) { module in
                    row(module)
                }
            }

            Spacer()
            row(.settings)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
    }

    private func row(_ module: AppModule) -> some View {
        let isSelected = module == selection
        return Button {
            selection = module
        } label: {
            HStack(spacing: 10) {
                ModuleIcon(module: module, size: 24)
                Text(module.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.09))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
