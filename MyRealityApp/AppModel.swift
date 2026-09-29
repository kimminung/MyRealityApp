import SwiftUI
import RealityKit
import CoreGraphics

/// 앱 상태와 "사물 고르기 → 라이다 윤곽 분리 → 색·글자 판단 → 적용" 파이프라인을 조율한다.
@Observable
@MainActor
final class AppModel {
    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    /// 컬렉션에서 꺼내 공간에 다시 놓은 오브젝트.
    struct PlacedObject: Identifiable {
        let id: UUID
        let objectID: UUID
        var name: String
    }

    // 사용자 입력
    var requestText = ""
    /// 사물 인식이 켜져 있는지. 창의 버튼으로만 켠다.
    var isScanning = false
    /// 형상을 만드는 방식.
    var shapeMode: ShapeMode = .primitive

    /// 공간을 열 때마다 올라가는 번호.
    /// 뒤늦게 도착한 옛 공간의 정리 신호가 새로 시작한 세션을 끄지 못하게 막는다.
    private var sessionGeneration = 0

    /// 다음 핀치로 사물을 고를 준비가 됐는지.
    /// 한 번 고르면 꺼져서, 실수로 다른 사물이 계속 바뀌지 않는다.
    private(set) var isArmed = false

    // 진행 상태
    private(set) var isWorking = false
    private(set) var statusText = "준비 중…"
    private(set) var log: [LogEntry] = []
    private(set) var patches: [DesignPatch] = []
    private(set) var results: [DesignResult] = []
    private(set) var placedObjects: [PlacedObject] = []
    /// 창에서 조작 중인 디자인.
    private(set) var selectedPatchID: UUID?

    // 서비스
    let sceneUnderstanding = SceneUnderstanding()
    let brain = DesignBrain()
    let collection = ObjectCollection()

    /// 리스타일한 사물과 다시 놓은 오브젝트가 붙는 루트.
    let designRoot = Entity()

    private var patchEntities: [UUID: ModelEntity] = [:]
    private var patchHits: [UUID: SurfaceHit] = [:]
    private var patchResults: [UUID: DesignResult] = [:]
    private var placedEntities: [UUID: Entity] = [:]

    /// 요청 입력 예시.
    static let sampleRequests = [
        "네이비색으로 바꿔줘",
        "따뜻한 우드 톤으로",
        "무광 검정에 'MW' 글자",
        "파스텔 민트색 매트하게",
        "광택 있는 빨강으로",
    ]

    /// 창에서 조작 중인 디자인.
    var selectedPatch: DesignPatch? {
        guard let selectedPatchID else { return nil }
        return patches.first { $0.id == selectedPatchID }
    }

    var canSaveSelected: Bool {
        guard let selectedPatchID else { return false }
        return patchResults[selectedPatchID] != nil
    }

    // MARK: - 시작

    func bootstrap() {
        brain.refreshAvailability()
        collection.load()
        statusText = "사물 인식을 시작하세요"
        note("AI: \(brain.availabilityDescription)")
        note("컬렉션 \(collection.items.count)개 불러옴")
        if let issue = collection.lastIssue { note("컬렉션: \(issue)") }
    }

    /// 공간이 열릴 때 부여받는 번호.
    func beginSpatialSession() -> Int {
        sessionGeneration += 1
        return sessionGeneration
    }

    func spatialSessionDidStart(generation: Int) async {
        guard generation == sessionGeneration else { return }
        await sceneUnderstanding.start()
        guard generation == sessionGeneration else { return }
        note(sceneUnderstanding.statusDescription)
        if sceneUnderstanding.isRunning {
            isScanning = true
            isArmed = true
            statusText = "바꿀 사물을 보고 핀치하세요"
        }
    }

    /// 공간이 닫힐 때 호출된다. 시스템이 먼저 닫는 경우도 있어 여기서 상태를 맞춘다.
    /// 이미 새 공간이 열려 있으면(번호가 바뀌었으면) 아무것도 하지 않는다.
    func spatialSessionDidStop(generation: Int) {
        guard generation == sessionGeneration else { return }
        sceneUnderstanding.stop()
        isArmed = false
        isScanning = false
        statusText = "사물 인식이 꺼졌습니다"
    }

    func noteSpaceOpenFailed() {
        note("공간을 열 수 없었습니다. 잠시 후 다시 시도하세요")
        statusText = "공간을 열 수 없었습니다"
    }

    /// 다음 사물을 고를 수 있게 한다.
    func armForNextObject() {
        guard isScanning else {
            note("먼저 사물 인식을 시작해 주세요")
            return
        }
        isArmed = true
        statusText = "바꿀 사물을 보고 핀치하세요"
    }

    func disarm() {
        isArmed = false
        statusText = "사물 고르기를 멈췄습니다"
    }

    // MARK: - 사물 고르기

    /// 라이다 표면을 핀치했을 때만 호출된다. 라벨 버튼은 이 경로를 타지 않는다.
    func handleSurfaceTap(at worldPoint: SIMD3<Float>) async {
        guard isArmed else { return }
        guard !isWorking else {
            note("이전 작업이 아직 진행 중입니다")
            return
        }
        guard sceneUnderstanding.isRunning else {
            note("공간 인식이 아직 준비되지 않았습니다")
            return
        }
        // 한 번에 하나만 고르도록 즉시 잠근다.
        isArmed = false

        setStatus("라이다로 윤곽 뜨는 중…")
        let hit = await sceneUnderstanding.surface(at: worldPoint, mode: shapeMode)

        let patch = DesignPatch(
            id: UUID(),
            surface: hit.kind,
            center: hit.point,
            normal: hit.normal,
            target: hit.target,
            labelDistance: hit.region.labelOffset,
            title: "\(hit.kind.koreanName) 분석 중…",
            subtitle: "",
            state: .thinking
        )
        patches.append(patch)
        patchHits[patch.id] = hit
        selectedPatchID = patch.id

        guard let entity = makePatchEntity(for: patch, region: hit.region) else {
            patches.removeAll { $0.id == patch.id }
            patchHits[patch.id] = nil
            selectedPatchID = nil
            isArmed = true
            setStatus("형상을 만들 수 없습니다. 더 가까이서 둘러본 뒤 다시 핀치하세요")
            return
        }
        patchEntities[patch.id] = entity
        designRoot.addChild(entity)

        note("인식: \(hit.kind.koreanName) · \(hit.target.koreanName) · \(hit.region.source) · \(hit.region.sizeDescription)")
        if hit.target == .background {
            note("사물이 따로 잡히지 않아 바라본 표면의 일부만 골랐습니다. 사물에 더 가까이 가서 스캔해 보세요")
        }
        await runDesign(patchID: patch.id, hit: hit)
    }

    /// 같은 사물에 다른 색을 다시 뽑는다.
    func redesignSelected() async {
        guard let id = selectedPatchID else { return }
        guard !isWorking, let hit = patchHits[id], let index = patches.firstIndex(where: { $0.id == id }) else { return }
        patches[index].state = .thinking
        patches[index].title = "\(hit.kind.koreanName) 다시 판단 중…"
        patches[index].subtitle = ""
        patchEntities[id]?.model?.materials = [DesignMaterial.placeholder()]
        await runDesign(patchID: id, hit: hit)
    }

    func removeSelected() {
        guard let id = selectedPatchID else { return }
        removePatch(id)
    }

    func removePatch(_ id: UUID) {
        patches.removeAll { $0.id == id }
        patchEntities[id]?.removeFromParent()
        patchEntities[id] = nil
        patchHits[id] = nil
        patchResults[id] = nil
        if selectedPatchID == id { selectedPatchID = patches.last?.id }
    }

    func clearPatches() {
        for id in patchEntities.keys { patchEntities[id]?.removeFromParent() }
        patchEntities.removeAll()
        patchHits.removeAll()
        patchResults.removeAll()
        patches.removeAll()
        selectedPatchID = nil
        note("적용한 리스타일을 모두 지웠습니다")
    }

    // MARK: - 컬렉션

    /// 마음에 든 결과를 하나의 오브젝트로 컬렉션에 담는다.
    func saveSelectedToCollection() {
        guard let id = selectedPatchID, let result = patchResults[id], let hit = patchHits[id] else {
            note("아직 담을 결과가 없습니다")
            return
        }
        guard let object = collection.save(result: result, geometry: hit.region) else {
            note("컬렉션 저장 실패: \(collection.lastIssue ?? "알 수 없는 이유")")
            return
        }
        if let index = patches.firstIndex(where: { $0.id == id }) {
            patches[index].isSaved = true
        }
        note("컬렉션에 담았습니다: \(object.name)")
        setStatus("컬렉션에 담았습니다: \(object.name)")
    }

    /// 컬렉션 오브젝트를 눈앞에 다시 놓는다.
    func place(_ object: DesignObject) async {
        guard isScanning else {
            note("먼저 사물 인식을 시작해 주세요")
            return
        }
        guard let entity = await collection.makeEntity(for: object) else {
            note("오브젝트를 놓을 수 없습니다: \(collection.lastIssue ?? "알 수 없는 이유")")
            return
        }

        if let deviceTransform = sceneUnderstanding.deviceTransform {
            let devicePosition = SIMD3<Float>(deviceTransform.columns.3.x, deviceTransform.columns.3.y, deviceTransform.columns.3.z)
            let forward = -SIMD3<Float>(deviceTransform.columns.2.x, deviceTransform.columns.2.y, deviceTransform.columns.2.z)
            let position = devicePosition + simd_normalize(forward) * 0.8
            entity.position = position
            entity.orientation = Self.rotation(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(devicePosition - position))
        } else if let origin = object.originTransform {
            entity.setTransformMatrix(origin, relativeTo: nil)
        }

        designRoot.addChild(entity)
        let placed = PlacedObject(id: UUID(), objectID: object.id, name: object.name)
        placedEntities[placed.id] = entity
        placedObjects.append(placed)
        note("공간에 놓았습니다: \(object.name) · 손으로 집어 옮길 수 있습니다")
    }

    func clearPlaced() {
        for id in placedEntities.keys { placedEntities[id]?.removeFromParent() }
        placedEntities.removeAll()
        placedObjects.removeAll()
    }

    // MARK: - 파이프라인

    private func runDesign(patchID: UUID, hit: SurfaceHit) async {
        isWorking = true
        defer { isWorking = false }

        let trimmed = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = trimmed.isEmpty ? "이 사물에 어울리는 차분한 새 색" : trimmed

        setStatus("색과 글자 판단 중…")
        let (restyle, usedModel) = await brain.restyle(
            request: request,
            surface: hit.kind,
            sizeDescription: hit.region.sizeDescription,
            target: hit.target
        )

        setStatus("색 입히는 중…")
        guard let texture = await TextureFactory.render(restyle: restyle, isShell: hit.region.isShell) else {
            markFailed(patchID, reason: "텍스처 생성 실패")
            return
        }

        let result = DesignResult(
            surface: hit.kind,
            requestText: request,
            restyle: restyle,
            texture: texture,
            target: hit.target,
            geometrySource: hit.region.source,
            usedLanguageModel: usedModel
        )

        setStatus("사물에 적용 중…")
        await apply(result, to: patchID, isShell: hit.region.isShell)
    }

    private func apply(_ result: DesignResult, to patchID: UUID, isShell: Bool) async {
        guard let entity = patchEntities[patchID] else { return }
        do {
            let textureResource = try await TextureResource(image: result.texture, options: .init(semantic: .color))
            entity.model?.materials = [DesignMaterial.make(for: result.restyle, texture: textureResource, isShell: isShell)]
            entity.components.set(GroundingShadowComponent(castsShadow: true))
            patchResults[patchID] = result

            if let index = patches.firstIndex(where: { $0.id == patchID }) {
                patches[index].title = result.restyle.title
                patches[index].subtitle = result.restyle.rationale
                patches[index].state = .ready
                patches[index].isSaved = false
            }
            results.insert(result, at: 0)
            if results.count > 20 { results.removeLast() }

            let labelText = result.restyle.label.isEmpty ? "글자 없음" : "글자 \"\(result.restyle.label)\""
            note("적용: \(result.restyle.title) · \(result.restyle.baseColor) · \(result.restyle.finish.rawValue) · \(labelText)")
            setStatus("완료: \(result.restyle.title) · 창에서 다음 동작을 고르세요")
        } catch {
            markFailed(patchID, reason: error.localizedDescription)
        }
    }

    private func markFailed(_ patchID: UUID, reason: String) {
        isArmed = true
        if let index = patches.firstIndex(where: { $0.id == patchID }) {
            patches[index].title = "적용 실패"
            patches[index].subtitle = reason
            patches[index].state = .failed
        }
        setStatus("실패: \(reason)")
    }

    // MARK: - 엔티티

    /// 사물을 감싸는 기하를 그대로 쓰는 엔티티.
    /// 입력 대상으로 만들지 않는다. 그래야 다시 핀치해도 디자인이 멋대로 바뀌지 않는다.
    private func makePatchEntity(for patch: DesignPatch, region: RegionGeometry) -> ModelEntity? {
        guard let mesh = try? region.makeMesh() else { return nil }
        let entity = ModelEntity()
        entity.name = "patch:\(patch.id.uuidString)"
        entity.setTransformMatrix(region.transform, relativeTo: nil)
        entity.model = ModelComponent(mesh: mesh, materials: [DesignMaterial.placeholder()])
        entity.components.set(GroundingShadowComponent(castsShadow: true))
        return entity
    }

    /// 두 단위 벡터 사이의 회전. 정반대 방향이면 Y축 180도 회전으로 처리한다.
    private static func rotation(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let dot = simd_dot(from, to)
        if dot < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        }
        return simd_quatf(from: from, to: to)
    }

    // MARK: - 로그

    private func setStatus(_ text: String) {
        statusText = text
    }

    private func note(_ text: String) {
        log.insert(LogEntry(text: text), at: 0)
        if log.count > 60 { log.removeLast() }
    }
}
