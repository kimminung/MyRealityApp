import Foundation
import ARKit
import RealityKit
import simd
import QuartzCore

/// 바라본 지점에서 알아낸 사물.
nonisolated struct SurfaceHit: Sendable {
    /// 무엇을 골랐는지.
    enum Target: String, Sendable {
        /// 벽·바닥에서 떼어낸 독립 사물.
        case object
        /// ARKit이 하나의 물건으로 인식한 평면(창문·문·테이블 등).
        case panel
        /// 벽·바닥·천장 같은 배경 표면의 일부.
        case background

        var koreanName: String {
            switch self {
            case .object: "독립 사물"
            case .panel: "평면 사물"
            case .background: "배경 표면"
            }
        }
    }

    var kind: SurfaceKind
    /// 사물 중심(월드)
    var point: SIMD3<Float>
    /// 사용자를 향하는 방향(월드)
    var normal: SIMD3<Float>
    /// 사물을 감싸는 기하. 디자인은 이 안에만 적용된다.
    var region: RegionGeometry
    var target: Target
}

/// 라이다 재구성 메시에만 붙는 표식.
/// 이 표식이 있는 엔티티에만 탭 제스처를 연결해, 떠 있는 라벨의 버튼을 탭이 가로채지 않게 한다.
struct ScanSurfaceComponent: Component {
    init() {}
}

/// ARKit 씬 재구성(분류 포함)과 평면 감지를 돌리며,
/// 시선+핀치 탭을 받을 수 있는 보이지 않는 충돌 메시를 유지한다.
@Observable
@MainActor
final class SceneUnderstanding {
    /// RealityView에 추가할 루트. 앵커별 충돌 엔티티가 자식으로 붙는다.
    let rootEntity = Entity()

    private(set) var isRunning = false
    private(set) var meshAnchorCount = 0
    private(set) var planeAnchorCount = 0
    private(set) var statusDescription = "대기 중"

    // ARKit 데이터 제공자는 한 번 멈추면 재사용할 수 없다. 켤 때마다 새로 만든다.
    private var session = ARKitSession()
    private var sceneReconstruction = SceneReconstructionProvider(modes: [.classification])
    private var planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
    private var worldTracking = WorldTrackingProvider()

    private var meshEntities: [UUID: Entity] = [:]
    private var meshRecords: [UUID: MeshRecord] = [:]
    private var planeRecords: [UUID: PlaneRecord] = [:]
    private var updateTasks: [Task<Void, Never>] = []

    var isSupported: Bool {
        SceneReconstructionProvider.isSupported && PlaneDetectionProvider.isSupported
    }

    /// 현재 기기(머리)의 위치·방향.
    var deviceTransform: simd_float4x4? {
        guard isRunning, worldTracking.state == .running,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return nil }
        return anchor.originFromAnchorTransform
    }

    var devicePosition: SIMD3<Float>? {
        guard let transform = deviceTransform else { return nil }
        let column = transform.columns.3
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    // MARK: - 세션

    func start() async {
        guard !isRunning else { return }
        guard isSupported else {
            statusDescription = "이 환경에서는 공간 인식을 지원하지 않습니다"
            return
        }
        resetProviders()

        let providers = [sceneReconstruction, planeDetection, worldTracking] as [any DataProvider]
        do {
            try await session.run(providers)
            isRunning = true
            statusDescription = "주변 사물 스캔 중"
            updateTasks.append(Task { await self.observeMeshes() })
            updateTasks.append(Task { await self.observePlanes() })
        } catch {
            statusDescription = "ARKit 세션 오류: \(error.localizedDescription)"
        }
    }

    func stop() {
        updateTasks.forEach { $0.cancel() }
        updateTasks.removeAll()
        session.stop()
        isRunning = false
        statusDescription = "중지됨"
    }

    private func resetProviders() {
        session = ARKitSession()
        sceneReconstruction = SceneReconstructionProvider(modes: [.classification])
        planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
        worldTracking = WorldTrackingProvider()

        for entity in meshEntities.values { entity.removeFromParent() }
        meshEntities.removeAll()
        meshRecords.removeAll()
        planeRecords.removeAll()
        meshAnchorCount = 0
        planeAnchorCount = 0
    }

    private func observeMeshes() async {
        for await update in sceneReconstruction.anchorUpdates {
            if Task.isCancelled { return }
            let anchor = update.anchor
            switch update.event {
            case .added, .updated:
                meshRecords[anchor.id] = MeshRecord(anchor: anchor)
                await upsertCollision(for: anchor)
            case .removed:
                meshRecords[anchor.id] = nil
                meshEntities[anchor.id]?.removeFromParent()
                meshEntities[anchor.id] = nil
            }
            meshAnchorCount = meshRecords.count
        }
    }

    private func observePlanes() async {
        for await update in planeDetection.anchorUpdates {
            if Task.isCancelled { return }
            let anchor = update.anchor
            switch update.event {
            case .added, .updated:
                planeRecords[anchor.id] = PlaneRecord(anchor: anchor)
            case .removed:
                planeRecords[anchor.id] = nil
            }
            planeAnchorCount = planeRecords.count
        }
    }

    /// 메시 앵커마다 정적 충돌 형상을 만들어 탭 대상이 되게 한다.
    private func upsertCollision(for anchor: MeshAnchor) async {
        guard let shape = try? await ShapeResource.generateStaticMesh(from: anchor) else { return }
        let entity = meshEntities[anchor.id] ?? {
            let entity = Entity()
            entity.name = "mesh:\(anchor.id.uuidString)"
            entity.components.set(InputTargetComponent())
            entity.components.set(ScanSurfaceComponent())
            rootEntity.addChild(entity)
            meshEntities[anchor.id] = entity
            return entity
        }()
        entity.setTransformMatrix(anchor.originFromAnchorTransform, relativeTo: nil)
        entity.components.set(CollisionComponent(shapes: [shape], isStatic: true))
    }

    // MARK: - 사물 조회

    /// 바라본 지점의 사물을 배경에서 떼어내고, 그 윤곽을 감싸는 입체를 즉석에서 만든다.
    func surface(at point: SIMD3<Float>, mode: ShapeMode) async -> SurfaceHit {
        let records = Array(meshRecords.values)
        let planes = Array(planeRecords.values)
        let viewer = devicePosition

        if let outcome = await ObjectIsolator.isolate(
            around: point,
            viewer: viewer,
            meshes: records,
            planes: planes,
            mode: mode
        ) {
            return SurfaceHit(
                kind: outcome.kind,
                point: outcome.region.worldCenter,
                normal: outcome.region.worldNormal,
                region: outcome.region,
                target: outcome.target
            )
        }

        let normal = viewer.map { simd_normalize($0 - point) } ?? SIMD3<Float>(0, 0, 1)
        return SurfaceHit(
            kind: .unknown,
            point: point,
            normal: normal,
            region: RegionBuilder.fallbackSlab(center: point, normal: normal, side: 0.25),
            target: .background
        )
    }
}

// MARK: - 메시/평면 스냅샷

/// 메시 앵커의 기하를 Sendable 배열로 복사한 스냅샷.
nonisolated struct MeshRecord: Sendable {
    let id: UUID
    let transform: simd_float4x4
    let vertices: [SIMD3<Float>]
    let faces: [UInt32]
    let classifications: [UInt8]

    init(anchor: MeshAnchor) {
        id = anchor.id
        transform = anchor.originFromAnchorTransform
        let geometry = anchor.geometry
        vertices = geometry.vertices.float3Array()
        faces = geometry.faces.uint32Array()
        classifications = geometry.classifications?.uint8Array() ?? []
    }

    /// 기하를 직접 넣어 만드는 초기화. 분리 로직을 확인할 때 쓴다.
    init(
        id: UUID = UUID(),
        transform: simd_float4x4 = matrix_identity_float4x4,
        vertices: [SIMD3<Float>],
        faces: [UInt32],
        classifications: [UInt8] = []
    ) {
        self.id = id
        self.transform = transform
        self.vertices = vertices
        self.faces = faces
        self.classifications = classifications
    }
}

/// 평면 앵커 스냅샷.
/// 유리창처럼 라이다가 제대로 읽지 못하는 대상은 ARKit이 이미 다듬어 놓은 이 폴리곤이 훨씬 정확하다.
nonisolated struct PlaneRecord: Sendable {
    let id: UUID
    let kind: SurfaceKind
    /// 원점 → 앵커 변환.
    let transform: simd_float4x4
    /// 앵커 로컬 좌표의 폴리곤 정점과 삼각형 인덱스.
    let vertices: [SIMD3<Float>]
    let faces: [UInt32]
    /// extent 중심 변환과 크기.
    let extentTransform: simd_float4x4
    let width: Float
    let height: Float

    init(anchor: PlaneAnchor) {
        id = anchor.id
        kind = SurfaceKind(surface: anchor.surfaceClassification)
        transform = anchor.originFromAnchorTransform
        let geometry = anchor.geometry
        vertices = geometry.meshVertices.float3Array()
        faces = geometry.meshFaces.uint32Array()
        let extent = geometry.extent
        extentTransform = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
        width = extent.width
        height = extent.height
    }

    /// 기하를 직접 넣어 만드는 초기화. 분리 로직을 확인할 때 쓴다.
    init(
        id: UUID = UUID(),
        kind: SurfaceKind,
        transform: simd_float4x4 = matrix_identity_float4x4,
        vertices: [SIMD3<Float>],
        faces: [UInt32],
        extentTransform: simd_float4x4,
        width: Float,
        height: Float
    ) {
        self.id = id
        self.kind = kind
        self.transform = transform
        self.vertices = vertices
        self.faces = faces
        self.extentTransform = extentTransform
        self.width = width
        self.height = height
    }

    var normal: SIMD3<Float> {
        let column = extentTransform.columns.1
        return simd_normalize(SIMD3<Float>(column.x, column.y, column.z))
    }

    /// 벽·바닥·천장처럼 방의 배경인지.
    var isBackgroundSurface: Bool {
        switch kind {
        case .wall, .floor, .ceiling, .unknown: true
        default: false
        }
    }

    /// 디자인을 입힐 반경. 배경은 바라본 부분만, 창문·문 같은 물건은 전체를 쓴다.
    var designRadius: Float {
        isBackgroundSurface ? 0.45 : min(max(width, height), 2.2)
    }

    /// 점에서 평면까지의 수직 거리. 평면 범위를 크게 벗어나면 nil.
    func perpendicularDistance(to point: SIMD3<Float>, margin: Float = 0.25) -> Float? {
        let local = extentTransform.inverse.transformPoint(point)
        guard abs(local.x) <= width / 2 + margin, abs(local.z) <= height / 2 + margin else { return nil }
        return abs(local.y)
    }

    /// 평면을 얇은 상자로 맞춘다. 반경을 넘지 않도록 자르고, 잘린 만큼 중심을 옮긴다.
    func panelFit(near point: SIMD3<Float>, radius: Float, thickness: Float) -> PrimitiveFitter.Fit {
        let local = extentTransform.inverse.transformPoint(point)
        // 평면 로컬 좌표는 X가 가로, Z가 세로.
        let lowX = max(-width / 2, local.x - radius)
        let highX = min(width / 2, local.x + radius)
        let lowZ = max(-height / 2, local.z - radius)
        let highZ = min(height / 2, local.z + radius)
        let boxWidth = max(highX - lowX, 0.05)
        let boxHeight = max(highZ - lowZ, 0.05)

        // 자른 영역의 중심으로 평면을 평행 이동한다.
        var shifted = extentTransform
        let offset = extentTransform.columns.0 * ((lowX + highX) / 2) + extentTransform.columns.2 * ((lowZ + highZ) / 2)
        shifted.columns.3 += SIMD4<Float>(offset.x, offset.y, offset.z, 0)

        return PrimitiveFitter.fitPanel(
            planeTransform: shifted,
            width: boxWidth,
            height: boxHeight,
            thickness: thickness,
            detail: String(format: "판 %.0f×%.0fcm", boxWidth * 100, boxHeight * 100)
        )
    }

    /// 폴리곤 삼각형을 월드 좌표로, 지정한 지점 주변만 돌려준다.
    func triangles(near point: SIMD3<Float>, radius: Float) -> [RegionBuilder.Triangle] {
        guard faces.count >= 3 else { return [] }
        var result: [RegionBuilder.Triangle] = []
        result.reserveCapacity(faces.count / 3)
        let radiusSquared = radius * radius
        for face in stride(from: 0, to: faces.count - 2, by: 3) {
            let i0 = Int(faces[face]), i1 = Int(faces[face + 1]), i2 = Int(faces[face + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let a = transform.transformPoint(vertices[i0])
            let b = transform.transformPoint(vertices[i1])
            let c = transform.transformPoint(vertices[i2])
            let center = (a + b + c) / 3
            guard simd_length_squared(center - point) <= radiusSquared else { continue }
            result.append(RegionBuilder.Triangle(a: a, b: b, c: c))
        }
        return result
    }
}

// MARK: - 사물 분리

/// 바라본 지점에서 대상을 골라 형상을 맞춘다. 아무것도 저장하지 않고 매번 즉석에서 계산한다.
nonisolated enum ObjectIsolator {
    struct Outcome: Sendable {
        var region: RegionGeometry
        var kind: SurfaceKind
        var target: SurfaceHit.Target
    }

    /// 사물을 찾을 반경.
    private static let searchRadius: Float = 0.45
    /// 배경 평면으로 볼 두께.
    private static let backgroundTolerance: Float = 0.025
    /// 면을 이어 붙일 최대 간격.
    private static let linkDistance: Float = 0.05
    /// 독립 사물로 인정할 최대 한 변 길이.
    private static let maximumObjectExtent: Float = 0.7
    /// 독립 사물로 인정할 최소 돌출 높이.
    private static let minimumProtrusion: Float = 0.02
    /// 배경만 잡혔을 때 잘라낼 조각의 반경.
    private static let patchRadius: Float = 0.22

    @concurrent
    static func isolate(
        around point: SIMD3<Float>,
        viewer: SIMD3<Float>?,
        meshes: [MeshRecord],
        planes: [PlaneRecord],
        mode: ShapeMode
    ) async -> Outcome? {
        let faces = collectFaces(around: point, radius: searchRadius, in: meshes)
        let viewDirection = viewer.map { point - $0 }

        // 주변 평면을 거리 순으로 모은다.
        let nearbyPlanes = planes.compactMap { plane -> (plane: PlaneRecord, distance: Float)? in
            guard let distance = plane.perpendicularDistance(to: point), distance < 0.6 else { return nil }
            return (plane, distance)
        }.sorted { $0.distance < $1.distance }

        var references = nearbyPlanes.map { entry in
            PlaneReference(normal: entry.plane.normal, origin: entry.plane.extentTransform.transformPoint(.zero))
        }
        if references.isEmpty, let estimated = estimateDominantPlane(faces) {
            references = [estimated]
        }

        // A. 배경에서 튀어나온 독립 사물.
        if let outcome = standaloneObject(
            around: point, viewer: viewer, viewDirection: viewDirection,
            faces: faces, references: references, mode: mode
        ) {
            return outcome
        }

        // B. 평면으로 인식된 대상(창문·문·테이블 등). 유리창은 이 경로가 가장 깔끔하다.
        if let entry = nearbyPlanes.first(where: { $0.distance < 0.06 }) {
            let plane = entry.plane
            let target: SurfaceHit.Target = plane.isBackgroundSurface ? .background : .panel
            switch mode {
            case .primitive:
                let fit = plane.panelFit(
                    near: point,
                    radius: plane.designRadius,
                    thickness: plane.isBackgroundSurface ? 0.02 : 0.04
                )
                return Outcome(
                    region: RegionGeometry(
                        shape: fit.shape, transform: fit.transform, extent: fit.extent,
                        source: (plane.isBackgroundSurface ? "평면 일부 · " : "평면 윤곽 · ") + fit.detail
                    ),
                    kind: plane.kind,
                    target: target
                )
            case .silhouette:
                let triangles = plane.triangles(near: point, radius: plane.designRadius)
                if let region = SilhouetteShell.build(
                    worldTriangles: triangles, anchor: point, viewer: viewer,
                    options: SilhouetteShell.Options(outward: 0.007, thickness: 0.012, maximumExtent: 2.6),
                    source: plane.isBackgroundSurface ? "평면 일부" : "평면 윤곽"
                ) {
                    return Outcome(region: region, kind: plane.kind, target: target)
                }
            }
        }

        // C. 마지막으로 바라본 표면에서 작은 조각만 잘라낸다.
        return flatPatch(around: point, viewer: viewer, faces: faces, mode: mode)
    }

    // MARK: 내부

    /// 배경 평면에서 떨어져 있고 크기·돌출이 그럴듯한 덩어리를 찾는다.
    private static func standaloneObject(
        around point: SIMD3<Float>,
        viewer: SIMD3<Float>?,
        viewDirection: SIMD3<Float>?,
        faces: [FaceEntry],
        references: [PlaneReference],
        mode: ShapeMode
    ) -> Outcome? {
        guard !faces.isEmpty else { return nil }

        let offPlane = faces.indices.filter { index in
            !references.contains { $0.contains(faces[index].center, tolerance: backgroundTolerance) }
        }
        guard !offPlane.isEmpty else { return nil }

        var seed: Int?
        var seedDistance = Float.greatestFiniteMagnitude
        for index in offPlane {
            let distance = simd_distance(faces[index].center, point)
            if distance < seedDistance {
                seedDistance = distance
                seed = index
            }
        }
        guard let seed, seedDistance < 0.08 else { return nil }

        let grown = growConnected(from: seed, allowed: Set(offPlane), faces: faces)
        guard grown.count >= 8 else { return nil }

        // 크기와 돌출을 검사해 라이다 잡음이 통째로 잡히는 것을 막는다.
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var protrusion: Float = 0
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(grown.count * 3)
        for index in grown {
            for vertex in [faces[index].a, faces[index].b, faces[index].c] {
                lower = simd_min(lower, vertex)
                upper = simd_max(upper, vertex)
                points.append(vertex)
            }
            for reference in references {
                protrusion = max(protrusion, abs(simd_dot(reference.normal, faces[index].center - reference.origin)))
            }
        }
        let size = upper - lower
        guard max(size.x, max(size.y, size.z)) <= maximumObjectExtent else { return nil }
        if !references.isEmpty, protrusion < minimumProtrusion { return nil }

        let kind = dominantKind(of: grown, faces: faces)

        switch mode {
        case .primitive:
            guard let fit = PrimitiveFitter.fit(points: points, viewDirection: viewDirection) else { return nil }
            return Outcome(
                region: RegionGeometry(
                    shape: fit.shape, transform: fit.transform, extent: fit.extent,
                    source: "사물 \(grown.count)면 · \(fit.detail)"
                ),
                kind: kind,
                target: .object
            )
        case .silhouette:
            let triangles = grown.map { index in
                RegionBuilder.Triangle(a: faces[index].a, b: faces[index].b, c: faces[index].c)
            }
            guard let region = SilhouetteShell.build(
                worldTriangles: triangles, anchor: point, viewer: viewer,
                options: SilhouetteShell.Options(outward: 0.006, thickness: 0.012, maximumExtent: maximumObjectExtent),
                source: "사물 윤곽 \(grown.count)면"
            ) else { return nil }
            return Outcome(region: region, kind: kind, target: .object)
        }
    }

    /// 배경을 바로 바라봤을 때 쓰는 작은 조각.
    private static func flatPatch(
        around point: SIMD3<Float>,
        viewer: SIMD3<Float>?,
        faces: [FaceEntry],
        mode: ShapeMode
    ) -> Outcome? {
        let nearby = faces.indices.filter { simd_distance(faces[$0].center, point) <= patchRadius }
        guard nearby.count >= 4 else { return nil }
        guard let seed = nearby.min(by: {
            simd_distance(faces[$0].center, point) < simd_distance(faces[$1].center, point)
        }) else { return nil }

        let seedNormal = faces[seed].normal
        let coplanar = nearby.filter { simd_dot(faces[$0].normal, seedNormal) > 0.6 }
        let selected = coplanar.count >= 4 ? coplanar : nearby
        let kind = dominantKind(of: selected, faces: faces)

        switch mode {
        case .primitive:
            // 바라본 면에 맞춘 얇은 판을 놓는다.
            var normal = seedNormal
            if let viewer, simd_dot(normal, viewer - faces[seed].center) < 0 { normal = -normal }
            var center = SIMD3<Float>(repeating: 0)
            for index in selected { center += faces[index].center }
            center /= Float(selected.count)
            let region = RegionBuilder.fallbackSlab(
                center: center + normal * 0.012,
                normal: normal,
                side: patchRadius * 1.6
            )
            return Outcome(
                region: RegionGeometry(
                    shape: region.shape, transform: region.transform, extent: region.extent,
                    source: "표면 판 \(selected.count)면"
                ),
                kind: kind,
                target: .background
            )
        case .silhouette:
            let triangles = selected.map { index in
                RegionBuilder.Triangle(a: faces[index].a, b: faces[index].b, c: faces[index].c)
            }
            guard let region = SilhouetteShell.build(
                worldTriangles: triangles, anchor: point, viewer: viewer,
                options: SilhouetteShell.Options(outward: 0.007, thickness: 0.01, maximumExtent: 1.0),
                source: "표면 조각 \(selected.count)면"
            ) else { return nil }
            return Outcome(region: region, kind: kind, target: .background)
        }
    }

    /// 씨앗 면에서 인접한 면으로 넓혀 간다.
    private static func growConnected(from seed: Int, allowed: Set<Int>, faces: [FaceEntry]) -> [Int] {
        let cellSize: Float = 0.06
        var grid: [CellKey: [Int]] = [:]
        for index in allowed {
            grid[CellKey(faces[index].center, cellSize), default: []].append(index)
        }

        var visited: Set<Int> = [seed]
        var queue = [seed]
        var accepted = [seed]
        let limit = 4000

        while let current = queue.popLast(), accepted.count < limit {
            let center = faces[current].center
            for cell in CellKey(center, cellSize).neighbors {
                guard let bucket = grid[cell] else { continue }
                for index in bucket where !visited.contains(index) {
                    guard simd_distance(faces[index].center, center) <= linkDistance else { continue }
                    visited.insert(index)
                    queue.append(index)
                    accepted.append(index)
                    if accepted.count >= limit { break }
                }
                if accepted.count >= limit { break }
            }
        }
        return accepted
    }

    /// 면 분류 중 가장 많은 종류.
    private static func dominantKind(of indices: [Int], faces: [FaceEntry]) -> SurfaceKind {
        var counts: [SurfaceKind: Int] = [:]
        for index in indices { counts[faces[index].kind, default: 0] += 1 }
        let known = counts.filter { $0.key != .unknown }
        if let best = known.max(by: { $0.value < $1.value }), best.value * 3 >= indices.count {
            return best.key
        }
        return .unknown
    }

    /// 평면 앵커가 없을 때 법선 다수결로 배경면을 추정한다.
    private static func estimateDominantPlane(_ faces: [FaceEntry]) -> PlaneReference? {
        guard !faces.isEmpty else { return nil }
        var clusters: [SIMD3<Int32>: [Int]] = [:]
        for (index, face) in faces.enumerated() {
            let key = SIMD3<Int32>(
                Int32((face.normal.x * 4).rounded()),
                Int32((face.normal.y * 4).rounded()),
                Int32((face.normal.z * 4).rounded())
            )
            clusters[key, default: []].append(index)
        }
        guard let biggest = clusters.max(by: { $0.value.count < $1.value.count }),
              biggest.value.count * 2 >= faces.count else { return nil }

        var normalSum = SIMD3<Float>(repeating: 0)
        var originSum = SIMD3<Float>(repeating: 0)
        for index in biggest.value {
            normalSum += faces[index].normal
            originSum += faces[index].center
        }
        let normal = simd_length(normalSum) > 1e-5 ? simd_normalize(normalSum) : SIMD3<Float>(0, 1, 0)
        return PlaneReference(normal: normal, origin: originSum / Float(biggest.value.count))
    }

    /// 배경 기준면.
    struct PlaneReference: Sendable {
        var normal: SIMD3<Float>
        var origin: SIMD3<Float>

        func contains(_ point: SIMD3<Float>, tolerance: Float) -> Bool {
            abs(simd_dot(normal, point - origin)) <= tolerance
        }
    }

    /// 월드 좌표 면 하나.
    struct FaceEntry: Sendable {
        var kind: SurfaceKind
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var c: SIMD3<Float>
        var center: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    /// 지정한 지점 주변 면만 모은다.
    static func collectFaces(
        around point: SIMD3<Float>,
        radius: Float,
        in records: [MeshRecord]
    ) -> [FaceEntry] {
        var result: [FaceEntry] = []
        let radiusSquared = radius * radius

        for record in records {
            let localPoint = record.transform.inverse.transformPoint(point)
            let faceCount = record.faces.count / 3
            for face in 0..<faceCount {
                let i0 = Int(record.faces[face * 3])
                let i1 = Int(record.faces[face * 3 + 1])
                let i2 = Int(record.faces[face * 3 + 2])
                guard i0 < record.vertices.count, i1 < record.vertices.count, i2 < record.vertices.count else { continue }
                let v0 = record.vertices[i0], v1 = record.vertices[i1], v2 = record.vertices[i2]
                let localCenter = (v0 + v1 + v2) / 3
                guard simd_length_squared(localCenter - localPoint) <= radiusSquared else { continue }

                let a = record.transform.transformPoint(v0)
                let b = record.transform.transformPoint(v1)
                let c = record.transform.transformPoint(v2)
                let raw = simd_cross(b - a, c - a)
                let length = simd_length(raw)
                guard length > 1e-8 else { continue }
                let classificationRaw = face < record.classifications.count ? record.classifications[face] : 0
                result.append(FaceEntry(
                    kind: SurfaceKind(meshClassificationRaw: classificationRaw),
                    a: a, b: b, c: c,
                    center: (a + b + c) / 3,
                    normal: raw / length
                ))
            }
        }
        return result
    }

    /// 면 중심을 담는 격자 칸.
    private struct CellKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32

        init(_ position: SIMD3<Float>, _ size: Float) {
            x = Int32((position.x / size).rounded(.down))
            y = Int32((position.y / size).rounded(.down))
            z = Int32((position.z / size).rounded(.down))
        }

        private init(x: Int32, y: Int32, z: Int32) {
            self.x = x
            self.y = y
            self.z = z
        }

        var neighbors: [CellKey] {
            var result: [CellKey] = []
            result.reserveCapacity(27)
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        result.append(CellKey(x: x + Int32(dx), y: y + Int32(dy), z: z + Int32(dz)))
                    }
                }
            }
            return result
        }
    }
}

// MARK: - ARKit 분류 → SurfaceKind

nonisolated extension SurfaceKind {
    /// 메시 면 분류 원시값(UInt8)에서 변환.
    init(meshClassificationRaw raw: UInt8) {
        self.init(surface: SurfaceClassification(rawValue: Int(raw)))
    }

    /// visionOS 26+ 공통 표면 분류에서 변환.
    init(surface classification: SurfaceClassification?) {
        guard let classification else {
            self = .unknown
            return
        }
        switch classification {
        case .wall: self = .wall
        case .floor: self = .floor
        case .ceiling: self = .ceiling
        case .table: self = .table
        case .seat: self = .seat
        case .window: self = .window
        case .door: self = .door
        case .stairs: self = .stairs
        case .bed: self = .bed
        case .cabinet: self = .cabinet
        case .homeAppliance: self = .homeAppliance
        case .tv: self = .tv
        case .plant: self = .plant
        default: self = .unknown
        }
    }
}

// MARK: - 행렬·기하 소스 도우미

nonisolated extension simd_float4x4 {
    /// 점을 이 변환으로 옮긴다.
    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let result = self * SIMD4<Float>(point, 1)
        return SIMD3<Float>(result.x, result.y, result.z)
    }
}

nonisolated extension GeometrySource {
    /// float3 버텍스 버퍼를 배열로 복사.
    func float3Array() -> [SIMD3<Float>] {
        guard format == .float3 else { return [] }
        var result = [SIMD3<Float>](repeating: .zero, count: count)
        let base = buffer.contents().advanced(by: offset)
        for index in 0..<count {
            let pointer = base.advanced(by: index * stride).assumingMemoryBound(to: (Float, Float, Float).self)
            let value = pointer.pointee
            result[index] = SIMD3<Float>(value.0, value.1, value.2)
        }
        return result
    }

    /// 면 분류(uchar) 버퍼를 배열로 복사.
    func uint8Array() -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        let base = buffer.contents().advanced(by: offset)
        for index in 0..<count {
            result[index] = base.advanced(by: index * stride).assumingMemoryBound(to: UInt8.self).pointee
        }
        return result
    }
}

nonisolated extension GeometryElement {
    /// 삼각형 인덱스 버퍼를 UInt32 배열로 복사.
    func uint32Array() -> [UInt32] {
        let indexCount = count * primitive.indexCount
        var result = [UInt32](repeating: 0, count: indexCount)
        let base = buffer.contents()
        if bytesPerIndex == 4 {
            for index in 0..<indexCount {
                result[index] = base.advanced(by: index * 4).assumingMemoryBound(to: UInt32.self).pointee
            }
        } else if bytesPerIndex == 2 {
            for index in 0..<indexCount {
                result[index] = UInt32(base.advanced(by: index * 2).assumingMemoryBound(to: UInt16.self).pointee)
            }
        }
        return result
    }
}
