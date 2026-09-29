import Foundation
import RealityKit
import simd

/// 사물에 씌울 형상과 그 배치.
/// 로컬 좌표는 사물 중심이 원점이고, 형상에 따라 축 의미가 다르다(`DesignShape` 참고).
nonisolated struct RegionGeometry: Codable, Sendable, Equatable {
    var shape: DesignShape
    /// 로컬 → 월드 변환. 열 우선 16개 값으로 저장해 Codable을 만족시킨다.
    var transformValues: [Float]
    /// 가로·세로 크기(미터).
    var extent: SIMD2<Float>
    /// 어떻게 만든 형상인지. 진행 기록에 표시한다.
    var source: String

    init(shape: DesignShape, transform: simd_float4x4, extent: SIMD2<Float>, source: String) {
        self.shape = shape
        self.transformValues = []
        self.extent = extent
        self.source = source
        self.transform = transform
    }

    var transform: simd_float4x4 {
        get {
            guard transformValues.count == 16 else { return matrix_identity_float4x4 }
            return simd_float4x4(
                SIMD4<Float>(transformValues[0], transformValues[1], transformValues[2], transformValues[3]),
                SIMD4<Float>(transformValues[4], transformValues[5], transformValues[6], transformValues[7]),
                SIMD4<Float>(transformValues[8], transformValues[9], transformValues[10], transformValues[11]),
                SIMD4<Float>(transformValues[12], transformValues[13], transformValues[14], transformValues[15])
            )
        }
        set {
            transformValues = (0..<4).flatMap { index -> [Float] in
                let column = newValue[index]
                return [column.x, column.y, column.z, column.w]
            }
        }
    }

    /// 닫힌 입체인지. 참이면 뒷면을 잘라내 조명이 제대로 계산된다.
    var isShell: Bool { shape.isClosedVolume }

    var worldCenter: SIMD3<Float> {
        let column = transform.columns.3
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    /// 형상의 앞쪽 방향(월드). 라벨을 띄우는 기준으로 쓴다.
    var worldNormal: SIMD3<Float> {
        let column = transform.columns.2
        return simd_normalize(SIMD3<Float>(column.x, column.y, column.z))
    }

    var sizeDescription: String {
        String(format: "%.2f m × %.2f m", extent.x, extent.y)
    }

    /// 라벨을 띄울 거리. 형상 크기에 맞춰 사물에서 충분히 떨어뜨린다.
    var labelOffset: Float {
        let size = shape.boundingSize
        return max(max(size.x, max(size.y, size.z)) * 0.6, 0.16)
    }

    @MainActor
    func makeMesh() throws -> MeshResource {
        try shape.makeMesh()
    }

    @MainActor
    func makeCollisionShape() -> ShapeResource {
        shape.makeCollisionShape()
    }
}

// MARK: - 기하 도우미

nonisolated enum RegionBuilder {
    /// 월드 좌표 삼각형.
    struct Triangle: Sendable {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var c: SIMD3<Float>

        var normal: SIMD3<Float> {
            let raw = simd_cross(b - a, c - a)
            let length = simd_length(raw)
            return length < 1e-8 ? .zero : raw / length
        }

        var center: SIMD3<Float> { (a + b + c) / 3 }
    }

    /// 아무것도 잡히지 않을 때 쓰는 얇은 상자.
    static func fallbackSlab(center: SIMD3<Float>, normal: SIMD3<Float>, side: Float) -> RegionGeometry {
        let forward = simd_normalize(normal)
        let reference: SIMD3<Float> = abs(forward.y) > 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        var right = simd_cross(reference, forward)
        if simd_length(right) < 1e-5 { right = SIMD3<Float>(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(forward, right))

        return RegionGeometry(
            shape: .box(size: SIMD3<Float>(side, side, 0.02), cornerRadius: side * 0.08),
            transform: simd_float4x4(
                SIMD4<Float>(right, 0),
                SIMD4<Float>(up, 0),
                SIMD4<Float>(forward, 0),
                SIMD4<Float>(center, 1)
            ),
            extent: SIMD2<Float>(side, side),
            source: "기본 판"
        )
    }
}
