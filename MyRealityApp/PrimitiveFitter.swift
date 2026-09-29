import Foundation
import simd

/// 라이다 점들에 가장 잘 맞는 프리미티브를 찾는다.
///
/// 라이다 메시는 거칠고 사물의 앞면만 보이기 때문에 표면을 그대로 따라가면 모양이 어설퍼진다.
/// 대신 중력 방향을 기준으로 주축을 구해 상자·원기둥·공·원뿔 중 하나로 맞춰 넣는다.
/// 결과는 Reality Composer Pro에서 만든 오브젝트처럼 면이 매끄럽고 UV가 정돈되어 있다.
nonisolated enum PrimitiveFitter {
    struct Fit: Sendable {
        var shape: DesignShape
        var transform: simd_float4x4
        /// 가로·세로 크기(미터). 화면 표시와 텍스처 비율에 쓴다.
        var extent: SIMD2<Float>
        /// 어떻게 맞췄는지 사람이 읽을 설명.
        var detail: String
    }

    /// 점 구름에 프리미티브를 맞춘다.
    /// - Parameter viewDirection: 사용자 → 사물 방향. 보이지 않는 뒷면 깊이를 보정할 때 쓴다.
    static func fit(
        points rawPoints: [SIMD3<Float>],
        viewDirection: SIMD3<Float>?
    ) -> Fit? {
        let points = downsample(rawPoints, cell: 0.012)
        guard points.count >= 8 else { return nil }

        let centroid = points.reduce(SIMD3<Float>(repeating: 0), +) / Float(points.count)
        let up = SIMD3<Float>(0, 1, 0)

        // 1. 수평면에서 2차 모멘트로 주축을 구한다. 중력 방향은 고정해 기울어짐을 막는다.
        var covXX: Float = 0, covXZ: Float = 0, covZZ: Float = 0
        for point in points {
            let delta = point - centroid
            let x = delta.x, z = delta.z
            covXX += x * x
            covXZ += x * z
            covZZ += z * z
        }
        let count = Float(points.count)
        covXX /= count; covXZ /= count; covZZ /= count

        var major = SIMD3<Float>(1, 0, 0)
        let trace = covXX + covZZ
        let determinant = covXX * covZZ - covXZ * covXZ
        let discriminant = max(trace * trace / 4 - determinant, 0)
        if discriminant > 1e-12 || abs(covXZ) > 1e-9 {
            let eigenvalue = trace / 2 + discriminant.squareRoot()
            var direction = SIMD2<Float>(covXZ, eigenvalue - covXX)
            if simd_length(direction) < 1e-6 {
                direction = SIMD2<Float>(eigenvalue - covZZ, covXZ)
            }
            if simd_length(direction) > 1e-6 {
                direction = simd_normalize(direction)
                major = SIMD3<Float>(direction.x, 0, direction.y)
            }
        }
        let minor = simd_normalize(simd_cross(up, major))

        // 2. 각 축의 범위를 구한다.
        func range(_ axis: SIMD3<Float>) -> (low: Float, high: Float) {
            var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
            for point in points {
                let value = simd_dot(point - centroid, axis)
                low = min(low, value); high = max(high, value)
            }
            return (low, high)
        }
        let majorRange = range(major)
        let upRange = range(up)
        let minorRange = range(minor)

        var majorSize = majorRange.high - majorRange.low
        var upSize = upRange.high - upRange.low
        var minorSize = minorRange.high - minorRange.low
        guard majorSize > 0.01 || upSize > 0.01 || minorSize > 0.01 else { return nil }

        var center = centroid
            + major * ((majorRange.low + majorRange.high) / 2)
            + up * ((upRange.low + upRange.high) / 2)
            + minor * ((minorRange.low + minorRange.high) / 2)

        // 3. 라이다는 앞면만 본다. 시선 방향 축이 지나치게 얇으면 반대편이 있다고 보고 늘린다.
        var depthNote = ""
        if let viewDirection, simd_length(viewDirection) > 1e-5 {
            let direction = simd_normalize(viewDirection)
            let alongMajor = abs(simd_dot(direction, major))
            let alongMinor = abs(simd_dot(direction, minor))
            let widest = max(majorSize, minorSize)

            if alongMinor >= alongMajor, minorSize < widest * 0.7 {
                let expanded = min(widest, max(minorSize * 2, minorSize))
                center += minor * (simd_dot(direction, minor) > 0 ? (expanded - minorSize) / 2 : -(expanded - minorSize) / 2)
                minorSize = expanded
                depthNote = " · 뒷면 보정"
            } else if alongMajor > alongMinor, majorSize < widest * 0.7 {
                let expanded = min(widest, max(majorSize * 2, majorSize))
                center += major * (simd_dot(direction, major) > 0 ? (expanded - majorSize) / 2 : -(expanded - majorSize) / 2)
                majorSize = expanded
                depthNote = " · 뒷면 보정"
            }
        }

        majorSize = max(majorSize, 0.015)
        upSize = max(upSize, 0.015)
        minorSize = max(minorSize, 0.015)

        // 4. 단면이 얼마나 둥근지 본다.
        let horizontalRadius = points.map { point -> Float in
            let delta = point - center
            return simd_length(SIMD2<Float>(simd_dot(delta, major), simd_dot(delta, minor)))
        }
        let meanRadius = horizontalRadius.reduce(0, +) / count
        let radiusDeviation = meanRadius > 1e-5
            ? (horizontalRadius.map { ($0 - meanRadius) * ($0 - meanRadius) }.reduce(0, +) / count).squareRoot() / meanRadius
            : 1
        let squareness = abs(majorSize - minorSize) / max(majorSize, minorSize)

        // 공 판정: 세 축이 비슷하고 중심에서의 거리가 고르다.
        let spatialRadius = points.map { simd_length($0 - center) }
        let meanSpatial = spatialRadius.reduce(0, +) / count
        let spatialDeviation = meanSpatial > 1e-5
            ? (spatialRadius.map { ($0 - meanSpatial) * ($0 - meanSpatial) }.reduce(0, +) / count).squareRoot() / meanSpatial
            : 1

        let rotation = simd_float4x4(
            SIMD4<Float>(major, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(minor, 0),
            SIMD4<Float>(center, 1)
        )
        let planarExtent = SIMD2<Float>(max(majorSize, minorSize), upSize)

        // 5. 형상을 고른다.
        let widest = max(majorSize, minorSize)
        let widestRadius = widest / 2

        // 공: 세 축이 거의 같고 중심에서의 거리가 고르다.
        let axisRatio = max(majorSize, max(upSize, minorSize)) / min(majorSize, min(upSize, minorSize))
        if axisRatio < 1.2, spatialDeviation < 0.15 {
            let radius = max(majorSize, max(upSize, minorSize)) / 2
            return Fit(
                shape: .sphere(radius: radius),
                transform: rotation,
                extent: planarExtent,
                detail: String(format: "공 지름 %.0fcm", radius * 200) + depthNote
            )
        }

        // 원기둥·원뿔: 수평 단면이 둥글고 위아래로 서 있다.
        if radiusDeviation < 0.32, squareness < 0.35, upSize > widest * 0.35 {
            // 위쪽 반이 아래쪽 반보다 확실히 좁으면 원뿔로 본다.
            var topSum: Float = 0, topCount: Float = 0
            var bottomSum: Float = 0, bottomCount: Float = 0
            for (index, point) in points.enumerated() {
                if simd_dot(point - center, up) > 0 {
                    topSum += horizontalRadius[index]; topCount += 1
                } else {
                    bottomSum += horizontalRadius[index]; bottomCount += 1
                }
            }
            let topRadius = topCount > 0 ? topSum / topCount : meanRadius
            let bottomRadius = bottomCount > 0 ? bottomSum / bottomCount : meanRadius

            if topRadius < bottomRadius * 0.62 {
                return Fit(
                    shape: .cone(height: upSize, radius: widestRadius),
                    transform: rotation,
                    extent: planarExtent,
                    detail: String(format: "원뿔 지름 %.0fcm 높이 %.0fcm", widestRadius * 200, upSize * 100) + depthNote
                )
            }
            return Fit(
                shape: .cylinder(height: upSize, radius: max(widestRadius, meanRadius)),
                transform: rotation,
                extent: planarExtent,
                detail: String(format: "원기둥 지름 %.0fcm 높이 %.0fcm", max(widestRadius, meanRadius) * 200, upSize * 100) + depthNote
            )
        }

        // 그 밖에는 둥근 모서리 상자.
        let size = SIMD3<Float>(majorSize, upSize, minorSize)
        let cornerRadius = min(size.x, min(size.y, size.z)) * 0.12
        return Fit(
            shape: .box(size: size, cornerRadius: cornerRadius),
            transform: rotation,
            extent: planarExtent,
            detail: String(format: "상자 %.0f×%.0f×%.0fcm", size.x * 100, size.y * 100, size.z * 100) + depthNote
        )
    }

    /// 평면으로 인식된 대상(창문·문·테이블 등)은 ARKit이 준 사각형을 그대로 얇은 상자로 만든다.
    /// 유리창처럼 라이다가 못 읽는 대상에서 가장 깔끔한 결과가 나온다.
    static func fitPanel(
        planeTransform: simd_float4x4,
        width: Float,
        height: Float,
        thickness: Float,
        detail: String
    ) -> Fit {
        // 평면 앵커의 로컬 좌표는 XZ가 평면이고 +Y가 법선이다.
        // 상자는 X가 가로, Y가 세로, Z가 두께이므로 축을 바꿔 끼운다.
        let right = SIMD3<Float>(planeTransform.columns.0.x, planeTransform.columns.0.y, planeTransform.columns.0.z)
        let normal = SIMD3<Float>(planeTransform.columns.1.x, planeTransform.columns.1.y, planeTransform.columns.1.z)
        let inPlaneUp = SIMD3<Float>(planeTransform.columns.2.x, planeTransform.columns.2.y, planeTransform.columns.2.z)
        let origin = SIMD3<Float>(planeTransform.columns.3.x, planeTransform.columns.3.y, planeTransform.columns.3.z)

        let transform = simd_float4x4(
            SIMD4<Float>(simd_normalize(right), 0),
            SIMD4<Float>(simd_normalize(inPlaneUp), 0),
            SIMD4<Float>(simd_normalize(normal), 0),
            SIMD4<Float>(origin, 1)
        )
        let size = SIMD3<Float>(max(width, 0.05), max(height, 0.05), max(thickness, 0.01))
        return Fit(
            shape: .box(size: size, cornerRadius: min(size.x, size.y) * 0.04),
            transform: transform,
            extent: SIMD2<Float>(size.x, size.y),
            detail: detail
        )
    }

    /// 점을 격자로 솎아 밀집한 곳이 결과를 끌어당기지 않게 한다.
    private static func downsample(_ points: [SIMD3<Float>], cell: Float) -> [SIMD3<Float>] {
        var seen = Set<SIMD3<Int32>>()
        var result: [SIMD3<Float>] = []
        for point in points {
            let key = SIMD3<Int32>(
                Int32((point.x / cell).rounded()),
                Int32((point.y / cell).rounded()),
                Int32((point.z / cell).rounded())
            )
            if seen.insert(key).inserted { result.append(point) }
        }
        return result
    }
}
