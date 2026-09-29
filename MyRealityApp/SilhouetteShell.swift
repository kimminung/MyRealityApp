import Foundation
import simd

/// 라이다 삼각형을 사용자 시점의 격자에 즉석에서 투영해 사물 윤곽을 뜨고 다듬는다.
///
/// 원본 삼각형 테두리를 그대로 쓰면 톱니처럼 찢어진 모양이 나온다.
/// 여기서는 덮인 칸을 구한 뒤 구멍을 메우고 돌기를 깎고, 탭한 지점이 속한 덩어리만 남기고,
/// 깊이를 부드럽게 만들고 테두리를 둥글린다. 모든 계산은 그때그때 하며 아무것도 저장하지 않는다.
nonisolated enum SilhouetteShell {
    /// 한 변을 나눌 목표 칸 수. 대상 크기에 맞춰 칸 크기를 정한다.
    static let targetCellsPerSide = 60
    /// 칸 크기의 하한. 작은 사물을 지나치게 잘게 나누지 않는다.
    static let minimumCell: Float = 0.006
    /// 칸 크기의 상한. 큰 면에서 삼각형이 폭발하지 않게 한다.
    static let maximumCell: Float = 0.03

    struct Options: Sendable {
        /// 표면에서 바깥으로 띄우는 거리.
        var outward: Float = 0.006
        /// 껍질 두께.
        var thickness: Float = 0.01
        /// 테두리를 둥글리는 반복 횟수.
        var boundarySmoothing: Int = 4
        /// 깊이를 부드럽게 만드는 반복 횟수.
        var depthSmoothing: Int = 2
        /// 윤곽의 최대 한 변 길이(미터). 이보다 크면 만들지 않는다.
        var maximumExtent: Float = 3.0
    }

    /// 윤곽을 떠서 닫힌 껍질 기하를 만든다.
    /// - Parameters:
    ///   - anchor: 사용자가 탭한 월드 지점. 여러 덩어리 중 이 지점이 속한 것만 남긴다.
    static func build(
        worldTriangles triangles: [RegionBuilder.Triangle],
        anchor: SIMD3<Float>,
        viewer: SIMD3<Float>?,
        options: Options = Options(),
        source: String
    ) -> RegionGeometry? {
        guard !triangles.isEmpty else { return nil }

        // 1. 사용자를 바라보는 로컬 기저. +Z가 사용자 쪽, +Y가 위쪽.
        var averageNormal = SIMD3<Float>(repeating: 0)
        var centroid = SIMD3<Float>(repeating: 0)
        var vertexCount = 0
        for triangle in triangles {
            averageNormal += triangle.normal
            centroid += triangle.a + triangle.b + triangle.c
            vertexCount += 3
        }
        guard vertexCount > 0 else { return nil }
        centroid /= Float(vertexCount)

        var forward = simd_length(averageNormal) > 1e-5 ? simd_normalize(averageNormal) : SIMD3<Float>(0, 0, 1)
        if let viewer {
            let toViewer = viewer - centroid
            if simd_length(toViewer) > 1e-4 { forward = simd_normalize(toViewer) }
        }
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(worldUp, forward)
        if simd_length(right) < 1e-4 { right = SIMD3<Float>(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(forward, right))

        func toLocal(_ world: SIMD3<Float>) -> SIMD3<Float> {
            let delta = world - centroid
            return SIMD3<Float>(simd_dot(delta, right), simd_dot(delta, up), simd_dot(delta, forward))
        }

        // 2. 격자 크기 결정.
        var localTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        localTriangles.reserveCapacity(triangles.count)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for triangle in triangles {
            let a = toLocal(triangle.a), b = toLocal(triangle.b), c = toLocal(triangle.c)
            localTriangles.append((a, b, c))
            for point in [a, b, c] {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
        }
        let spanX = maxX - minX, spanY = maxY - minY
        guard spanX > 0.005, spanY > 0.005 else { return nil }
        guard spanX <= options.maximumExtent, spanY <= options.maximumExtent else { return nil }

        // 칸 수를 대상 크기와 무관하게 비슷하게 유지한다.
        // 작은 사물은 촘촘하게, 창문처럼 큰 면은 성글게 떠서 정밀도와 속도를 함께 맞춘다.
        let cell = min(max(max(spanX, spanY) / Float(targetCellsPerSide), minimumCell), maximumCell)
        let columns = max(Int((spanX / cell).rounded(.up)), 2)
        let rows = max(Int((spanY / cell).rounded(.up)), 2)

        // 3. 삼각형을 격자에 투영한다. 같은 칸이 겹치면 사용자에 가까운 깊이를 남긴다.
        var covered = [Bool](repeating: false, count: columns * rows)
        var depth = [Float](repeating: -.greatestFiniteMagnitude, count: columns * rows)

        func mark(_ column: Int, _ row: Int, _ value: Float) {
            guard column >= 0, column < columns, row >= 0, row < rows else { return }
            let index = row * columns + column
            covered[index] = true
            if value > depth[index] { depth[index] = value }
        }

        for (a, b, c) in localTriangles {
            // 정점이 놓인 칸은 항상 표시해 아주 작은 삼각형도 놓치지 않는다.
            for point in [a, b, c] {
                mark(Int((point.x - minX) / cell), Int((point.y - minY) / cell), point.z)
            }
            let loColumn = Int((min(a.x, b.x, c.x) - minX) / cell)
            let hiColumn = Int((max(a.x, b.x, c.x) - minX) / cell)
            let loRow = Int((min(a.y, b.y, c.y) - minY) / cell)
            let hiRow = Int((max(a.y, b.y, c.y) - minY) / cell)
            guard hiColumn >= loColumn, hiRow >= loRow else { continue }

            let edge1 = SIMD2<Float>(b.x - a.x, b.y - a.y)
            let edge2 = SIMD2<Float>(c.x - a.x, c.y - a.y)
            let area = edge1.x * edge2.y - edge1.y * edge2.x
            guard abs(area) > 1e-9 else { continue }

            for row in max(loRow, 0)...min(hiRow, rows - 1) {
                for column in max(loColumn, 0)...min(hiColumn, columns - 1) {
                    let centerX = minX + (Float(column) + 0.5) * cell
                    let centerY = minY + (Float(row) + 0.5) * cell
                    let offset = SIMD2<Float>(centerX - a.x, centerY - a.y)
                    // 무게중심 좌표로 삼각형 내부인지 판정한다.
                    let weight2 = (offset.x * edge2.y - offset.y * edge2.x) / area
                    let weight3 = (edge1.x * offset.y - edge1.y * offset.x) / area
                    guard weight2 >= -0.001, weight3 >= -0.001, weight2 + weight3 <= 1.001 else { continue }
                    let interpolated = a.z + (b.z - a.z) * weight2 + (c.z - a.z) * weight3
                    mark(column, row, interpolated)
                }
            }
        }

        // 4. 구멍을 메우고(닫기) 가느다란 돌기를 깎는다(열기).
        covered = dilate(covered, columns: columns, rows: rows)
        covered = erode(covered, columns: columns, rows: rows)
        covered = erode(covered, columns: columns, rows: rows)
        covered = dilate(covered, columns: columns, rows: rows)

        // 5. 탭한 지점이 속한 덩어리만 남긴다.
        let anchorLocal = toLocal(anchor)
        let anchorColumn = min(max(Int((anchorLocal.x - minX) / cell), 0), columns - 1)
        let anchorRow = min(max(Int((anchorLocal.y - minY) / cell), 0), rows - 1)
        guard let component = largestComponent(
            covered, columns: columns, rows: rows,
            preferredColumn: anchorColumn, preferredRow: anchorRow
        ) else { return nil }
        covered = component

        let coveredCount = covered.filter { $0 }.count
        guard coveredCount >= 6 else { return nil }

        // 6. 깊이가 없는 칸을 이웃 평균으로 채우고 전체를 부드럽게 만든다.
        fillMissingDepth(&depth, covered: covered, columns: columns, rows: rows)
        for _ in 0..<options.depthSmoothing {
            depth = smoothDepth(depth, covered: covered, columns: columns, rows: rows)
        }

        // 7. 칸 모퉁이를 정점으로 삼는다.
        let cornerColumns = columns + 1, cornerRows = rows + 1
        var cornerIndex = [Int](repeating: -1, count: cornerColumns * cornerRows)
        var cornerX: [Float] = [], cornerY: [Float] = [], cornerZ: [Float] = []
        var isBoundaryCorner: [Bool] = []

        func cellCovered(_ column: Int, _ row: Int) -> Bool {
            guard column >= 0, column < columns, row >= 0, row < rows else { return false }
            return covered[row * columns + column]
        }

        for row in 0..<cornerRows {
            for column in 0..<cornerColumns {
                let touching = [(column - 1, row - 1), (column, row - 1), (column - 1, row), (column, row)]
                let occupied = touching.filter { cellCovered($0.0, $0.1) }
                guard !occupied.isEmpty else { continue }
                var sum: Float = 0
                for cellPosition in occupied { sum += depth[cellPosition.1 * columns + cellPosition.0] }
                cornerIndex[row * cornerColumns + column] = cornerX.count
                cornerX.append(minX + Float(column) * cell)
                cornerY.append(minY + Float(row) * cell)
                cornerZ.append(sum / Float(occupied.count))
                // 네 칸이 모두 덮이지 않았으면 테두리 모퉁이다.
                isBoundaryCorner.append(occupied.count < 4)
            }
        }
        guard cornerX.count >= 4 else { return nil }

        // 8. 테두리 모퉁이를 이웃 쪽으로 당겨 계단 모양을 둥글린다.
        var neighbors = [[Int]](repeating: [], count: cornerX.count)
        for row in 0..<cornerRows {
            for column in 0..<cornerColumns {
                let index = cornerIndex[row * cornerColumns + column]
                guard index >= 0 else { continue }
                for offset in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nc = column + offset.0, nr = row + offset.1
                    guard nc >= 0, nc < cornerColumns, nr >= 0, nr < cornerRows else { continue }
                    let neighbor = cornerIndex[nr * cornerColumns + nc]
                    if neighbor >= 0 { neighbors[index].append(neighbor) }
                }
            }
        }
        for _ in 0..<options.boundarySmoothing {
            var nextX = cornerX, nextY = cornerY, nextZ = cornerZ
            for index in 0..<cornerX.count where isBoundaryCorner[index] {
                let linked = neighbors[index]
                guard !linked.isEmpty else { continue }
                var sumX: Float = 0, sumY: Float = 0, sumZ: Float = 0
                for neighbor in linked {
                    sumX += cornerX[neighbor]; sumY += cornerY[neighbor]; sumZ += cornerZ[neighbor]
                }
                let count = Float(linked.count)
                nextX[index] = cornerX[index] * 0.45 + (sumX / count) * 0.55
                nextY[index] = cornerY[index] * 0.45 + (sumY / count) * 0.55
                nextZ[index] = cornerZ[index] * 0.6 + (sumZ / count) * 0.4
            }
            cornerX = nextX; cornerY = nextY; cornerZ = nextZ
        }

        // 9. 앞면·뒷면 정점과 삼각형을 만든다.
        let frontCount = cornerX.count
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(frontCount * 2)
        for index in 0..<frontCount {
            positions.append(SIMD3<Float>(cornerX[index], cornerY[index], cornerZ[index] + options.outward))
        }
        for index in 0..<frontCount {
            positions.append(SIMD3<Float>(cornerX[index], cornerY[index], cornerZ[index] - options.thickness))
        }

        var frontIndices: [UInt32] = []
        for row in 0..<rows {
            for column in 0..<columns where covered[row * columns + column] {
                let c00 = cornerIndex[row * cornerColumns + column]
                let c10 = cornerIndex[row * cornerColumns + column + 1]
                let c11 = cornerIndex[(row + 1) * cornerColumns + column + 1]
                let c01 = cornerIndex[(row + 1) * cornerColumns + column]
                guard c00 >= 0, c10 >= 0, c11 >= 0, c01 >= 0 else { continue }
                frontIndices += [UInt32(c00), UInt32(c10), UInt32(c11)]
                frontIndices += [UInt32(c00), UInt32(c11), UInt32(c01)]
            }
        }
        guard frontIndices.count >= 6 else { return nil }

        var indices = frontIndices
        // 뒷면은 감기를 뒤집어 안쪽을 보게 한다.
        let backBase = UInt32(frontCount)
        for triangle in stride(from: 0, to: frontIndices.count - 2, by: 3) {
            indices.append(backBase + frontIndices[triangle])
            indices.append(backBase + frontIndices[triangle + 2])
            indices.append(backBase + frontIndices[triangle + 1])
        }

        // 10. 한 번만 쓰인 테두리 간선을 옆면으로 이어 닫는다.
        var edgeCounts: [UInt64: Int] = [:]
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            let low = UInt64(min(a, b)), high = UInt64(max(a, b))
            return low << 32 | high
        }
        for triangle in stride(from: 0, to: frontIndices.count - 2, by: 3) {
            let a = frontIndices[triangle], b = frontIndices[triangle + 1], c = frontIndices[triangle + 2]
            edgeCounts[key(a, b), default: 0] += 1
            edgeCounts[key(b, c), default: 0] += 1
            edgeCounts[key(c, a), default: 0] += 1
        }
        for triangle in stride(from: 0, to: frontIndices.count - 2, by: 3) {
            let a = frontIndices[triangle], b = frontIndices[triangle + 1], c = frontIndices[triangle + 2]
            for edge in [(a, b), (b, c), (c, a)] {
                guard edgeCounts[key(edge.0, edge.1)] == 1 else { continue }
                let outerA = edge.0, outerB = edge.1
                let innerA = outerA + backBase, innerB = outerB + backBase
                indices += [outerA, innerB, outerB]
                indices += [outerA, innerA, innerB]
            }
        }

        // 11. 법선은 기하에서 구해 앞면·옆면 경계가 부드럽게 이어지게 한다.
        let normals = smoothNormals(positions: positions, indices: indices)

        // 12. 정면에서 본 평면 투영 UV. 글자가 사물 앞면 가운데에 놓인다.
        let usedMinX = cornerX.min() ?? minX, usedMaxX = cornerX.max() ?? maxX
        let usedMinY = cornerY.min() ?? minY, usedMaxY = cornerY.max() ?? maxY
        let width = max(usedMaxX - usedMinX, 0.001)
        let height = max(usedMaxY - usedMinY, 0.001)
        let uvs = positions.map { position in
            SIMD2<Float>(
                min(max((position.x - usedMinX) / width, 0), 1),
                min(max(1 - (position.y - usedMinY) / height, 0), 1)
            )
        }

        return RegionGeometry(
            shape: .mesh(DesignShape.MeshPayload(
                positions: positions,
                normals: normals,
                uvs: uvs,
                indices: indices
            )),
            transform: simd_float4x4(
                SIMD4<Float>(right, 0),
                SIMD4<Float>(up, 0),
                SIMD4<Float>(forward, 0),
                SIMD4<Float>(centroid, 1)
            ),
            extent: SIMD2<Float>(width, height),
            source: "\(source) · 칸 \(String(format: "%.0f", cell * 1000))mm \(coveredCount)칸"
        )
    }

    // MARK: - 격자 도우미

    private static func dilate(_ mask: [Bool], columns: Int, rows: Int) -> [Bool] {
        var result = mask
        for row in 0..<rows {
            for column in 0..<columns where !mask[row * columns + column] {
                for offset in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nc = column + offset.0, nr = row + offset.1
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    if mask[nr * columns + nc] {
                        result[row * columns + column] = true
                        break
                    }
                }
            }
        }
        return result
    }

    private static func erode(_ mask: [Bool], columns: Int, rows: Int) -> [Bool] {
        var result = mask
        for row in 0..<rows {
            for column in 0..<columns where mask[row * columns + column] {
                for offset in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nc = column + offset.0, nr = row + offset.1
                    // 바깥 경계에 닿은 칸은 유지해 영역이 통째로 사라지지 않게 한다.
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    if !mask[nr * columns + nc] {
                        result[row * columns + column] = false
                        break
                    }
                }
            }
        }
        return result
    }

    /// 탭한 칸이 속한 덩어리를 우선 반환하고, 없으면 가장 큰 덩어리를 반환한다.
    private static func largestComponent(
        _ mask: [Bool], columns: Int, rows: Int,
        preferredColumn: Int, preferredRow: Int
    ) -> [Bool]? {
        var visited = [Bool](repeating: false, count: mask.count)
        var best: [Bool]?
        var bestScore = -1
        var preferred: [Bool]?

        for startRow in 0..<rows {
            for startColumn in 0..<columns {
                let startIndex = startRow * columns + startColumn
                guard mask[startIndex], !visited[startIndex] else { continue }

                var component = [Bool](repeating: false, count: mask.count)
                var queue = [startIndex]
                visited[startIndex] = true
                component[startIndex] = true
                var count = 0
                var containsPreferred = false

                while let current = queue.popLast() {
                    count += 1
                    let column = current % columns, row = current / columns
                    if column == preferredColumn, row == preferredRow { containsPreferred = true }
                    for offset in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nc = column + offset.0, nr = row + offset.1
                        guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                        let neighbor = nr * columns + nc
                        guard mask[neighbor], !visited[neighbor] else { continue }
                        visited[neighbor] = true
                        component[neighbor] = true
                        queue.append(neighbor)
                    }
                }
                if containsPreferred { preferred = component }
                if count > bestScore {
                    bestScore = count
                    best = component
                }
            }
        }
        return preferred ?? best
    }

    /// 닫기 연산으로 새로 생긴 칸의 깊이를 이웃 평균으로 채운다.
    private static func fillMissingDepth(_ depth: inout [Float], covered: [Bool], columns: Int, rows: Int) {
        let missing = -Float.greatestFiniteMagnitude
        for _ in 0..<6 {
            var changed = false
            var next = depth
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard covered[index], depth[index] == missing else { continue }
                    var sum: Float = 0
                    var count = 0
                    for offset in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nc = column + offset.0, nr = row + offset.1
                        guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                        let neighbor = nr * columns + nc
                        if covered[neighbor], depth[neighbor] != missing {
                            sum += depth[neighbor]
                            count += 1
                        }
                    }
                    if count > 0 {
                        next[index] = sum / Float(count)
                        changed = true
                    }
                }
            }
            depth = next
            if !changed { break }
        }
        // 그래도 값이 없으면 평균으로 채운다.
        let valid = zip(covered, depth).filter { $0.0 && $0.1 != missing }.map(\.1)
        let average = valid.isEmpty ? 0 : valid.reduce(0, +) / Float(valid.count)
        for index in depth.indices where covered[index] && depth[index] == missing {
            depth[index] = average
        }
    }

    private static func smoothDepth(_ depth: [Float], covered: [Bool], columns: Int, rows: Int) -> [Float] {
        var result = depth
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard covered[index] else { continue }
                var sum = depth[index]
                var count = 1
                for offset in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nc = column + offset.0, nr = row + offset.1
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let neighbor = nr * columns + nc
                    if covered[neighbor] {
                        sum += depth[neighbor]
                        count += 1
                    }
                }
                result[index] = sum / Float(count)
            }
        }
        return result
    }

    private static func smoothNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var accumulated = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
            let i0 = Int(indices[triangle]), i1 = Int(indices[triangle + 1]), i2 = Int(indices[triangle + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let raw = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            accumulated[i0] += raw
            accumulated[i1] += raw
            accumulated[i2] += raw
        }
        return accumulated.map { value in
            let length = simd_length(value)
            return length > 1e-6 ? value / length : SIMD3<Float>(0, 0, 1)
        }
    }
}
