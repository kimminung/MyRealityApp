import SwiftUI
import RealityKit

/// 패스스루 위에 라이다 메시(보이지 않음)와 리스타일한 사물, 안내 라벨을 띄우는 공간.
/// 조작 버튼은 모두 제어 창에 있다. 이 공간의 탭은 라이다 표면에만 연결해
/// 떠 있는 라벨이나 창의 버튼을 탭이 가로채지 않게 한다.
struct DesignSpaceView: View {
    @Environment(AppModel.self) private var model
    /// 이 공간 인스턴스의 번호. 뒤늦은 정리 신호가 새 세션을 끄지 못하게 한다.
    @State private var generation: Int?

    var body: some View {
        RealityView { content, _ in
            ScanSurfaceComponent.registerComponent()
            content.add(model.sceneUnderstanding.rootEntity)
            content.add(model.designRoot)
        } update: { _, attachments in
            for patch in model.patches {
                guard let label = attachments.entity(for: patch.id) else { continue }
                if label.parent == nil {
                    label.components.set(BillboardComponent())
                    model.designRoot.addChild(label)
                }
                label.setPosition(patch.labelPosition, relativeTo: nil)
            }
            // 지운 사물의 라벨 정리.
            let liveIDs = Set(model.patches.map(\.id))
            for child in model.designRoot.children where child is ViewAttachmentEntity {
                if let id = UUID(uuidString: child.name), !liveIDs.contains(id) {
                    child.removeFromParent()
                }
            }
        } attachments: {
            ForEach(model.patches) { patch in
                Attachment(id: patch.id) {
                    PatchLabel(patch: patch, isSelected: model.selectedPatchID == patch.id)
                }
            }
        }
        // 라이다 표면에만 탭을 연결한다. 라벨과 놓아둔 오브젝트는 이 제스처를 받지 않는다.
        .gesture(
            SpatialTapGesture()
                .targetedToEntity(where: .has(ScanSurfaceComponent.self))
                .onEnded { value in
                    let worldPoint = value.convert(value.location3D, from: .local, to: .scene)
                    Task { await model.handleSurfaceTap(at: worldPoint) }
                }
        )
        .task {
            let current = model.beginSpatialSession()
            generation = current
            await model.spatialSessionDidStart(generation: current)
        }
        .onDisappear {
            if let generation { model.spatialSessionDidStop(generation: generation) }
        }
    }
}

/// 사물 위에 떠 있는 정보 라벨. 버튼은 두지 않는다.
private struct PatchLabel: View {
    let patch: DesignPatch
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: patch.surface.symbolName)
                    .font(.caption)
                Text(patch.surface.koreanName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if patch.target == .background {
                    Text("배경 표면")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if patch.state == .thinking {
                    ProgressView().controlSize(.small)
                } else if patch.isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Text(patch.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            if isSelected, patch.state == .ready {
                Text("창에서 색을 다시 뽑거나 컬렉션에 담으세요")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .glassBackgroundEffect()
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
    }
}
