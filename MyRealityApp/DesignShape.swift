import Foundation
import RealityKit
import simd

/// 형상을 만드는 방식.
nonisolated enum ShapeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 상자·원기둥·공·원뿔 중 가장 맞는 것으로 맞춰 넣는다. 면이 매끄럽고 라이다 잡음에 강하다.
    case primitive
    /// 라이다 표면 윤곽을 그대로 딴다. 스캔이 좋을 때 가장 정확하지만 거칠 수 있다.
    case silhouette

    var id: String { rawValue }

    var koreanName: String {
        switch self {
        case .primitive: "자동 입체"
        case .silhouette: "라이다 윤곽"
        }
    }

    var explanation: String {
        switch self {
        case .primitive: "상자·원기둥·공 중 가장 맞는 형태로 사물을 감쌉니다. 면이 매끄럽습니다."
        case .silhouette: "라이다가 읽은 표면을 그대로 따릅니다. 스캔이 거칠면 모양도 거칠어집니다."
        }
    }
}

/// 사물에 씌울 형상.
/// 프리미티브는 Reality Composer Pro에서 만든 오브젝트처럼 면이 매끄럽고 UV가 정돈되어 있다.
/// 라이다 윤곽(mesh)은 실제 표면을 그대로 따르지만 스캔 품질에 좌우된다.
nonisolated enum DesignShape: Codable, Sendable, Equatable {
    /// 둥근 모서리 상자. 창문·모니터·책처럼 각진 사물에 쓴다.
    case box(size: SIMD3<Float>, cornerRadius: Float)
    /// 공. 화분·조명갓처럼 둥근 사물에 쓴다.
    case sphere(radius: Float)
    /// 원기둥. 컵·병·캔에 쓴다.
    case cylinder(height: Float, radius: Float)
    /// 원뿔. 아래가 넓은 화분·갓에 쓴다.
    case cone(height: Float, radius: Float)
    /// 라이다 윤곽을 그대로 딴 메시.
    case mesh(MeshPayload)

    /// 메시 정점 모음. 컬렉션에 저장할 수 있도록 Codable로 둔다.
    struct MeshPayload: Codable, Sendable, Equatable {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var indices: [UInt32]

        var triangleCount: Int { indices.count / 3 }
    }

    /// 사람이 읽을 형상 이름.
    var koreanName: String {
        switch self {
        case .box: "상자"
        case .sphere: "공"
        case .cylinder: "원기둥"
        case .cone: "원뿔"
        case .mesh(let payload): "라이다 메시 \(payload.triangleCount)면"
        }
    }

    /// 닫힌 입체인지. 프리미티브는 모두 닫혀 있어 뒷면을 잘라내도 안전하다.
    var isClosedVolume: Bool { true }

    /// 형상을 감싸는 크기(미터).
    var boundingSize: SIMD3<Float> {
        switch self {
        case .box(let size, _):
            size
        case .sphere(let radius):
            SIMD3<Float>(repeating: radius * 2)
        case .cylinder(let height, let radius), .cone(let height, let radius):
            SIMD3<Float>(radius * 2, height, radius * 2)
        case .mesh(let payload):
            payload.positions.isEmpty ? SIMD3<Float>(repeating: 0.1) : {
                var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for point in payload.positions {
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
                return upper - lower
            }()
        }
    }

    @MainActor
    func makeMesh() throws -> MeshResource {
        switch self {
        case .box(let size, let cornerRadius):
            let clamped = simd_max(size, SIMD3<Float>(repeating: 0.01))
            let radius = min(cornerRadius, min(clamped.x, min(clamped.y, clamped.z)) * 0.49)
            return .generateBox(size: clamped, cornerRadius: max(radius, 0))
        case .sphere(let radius):
            return .generateSphere(radius: max(radius, 0.005))
        case .cylinder(let height, let radius):
            return .generateCylinder(height: max(height, 0.01), radius: max(radius, 0.005))
        case .cone(let height, let radius):
            return .generateCone(height: max(height, 0.01), radius: max(radius, 0.005))
        case .mesh(let payload):
            var descriptor = MeshDescriptor(name: "designRegion")
            descriptor.positions = MeshBuffers.Positions(payload.positions)
            descriptor.normals = MeshBuffers.Normals(payload.normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(payload.uvs)
            descriptor.primitives = .triangles(payload.indices)
            return try MeshResource.generate(from: [descriptor])
        }
    }

    @MainActor
    func makeCollisionShape() -> ShapeResource {
        switch self {
        case .sphere(let radius):
            .generateSphere(radius: max(radius, 0.01))
        default:
            .generateBox(size: simd_max(boundingSize, SIMD3<Float>(repeating: 0.02)))
        }
    }
}
