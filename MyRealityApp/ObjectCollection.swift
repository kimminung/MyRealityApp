import Foundation
import CoreGraphics
import ImageIO
import UIKit
import RealityKit

/// 마음에 든 리스타일을 사물 모양 그대로 저장한 항목.
struct DesignObject: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var surface: SurfaceKind
    var restyle: ObjectRestyle
    /// 사물을 감싸는 기하. 로컬 좌표로 저장해 어디에나 다시 놓을 수 있다.
    var geometry: RegionGeometry
    var textureFileName: String
    /// 원래 있던 자리(월드).
    var originTransformValues: [Float]
    let createdAt: Date

    var originTransform: simd_float4x4? {
        guard originTransformValues.count == 16 else { return nil }
        return simd_float4x4(
            SIMD4<Float>(originTransformValues[0], originTransformValues[1], originTransformValues[2], originTransformValues[3]),
            SIMD4<Float>(originTransformValues[4], originTransformValues[5], originTransformValues[6], originTransformValues[7]),
            SIMD4<Float>(originTransformValues[8], originTransformValues[9], originTransformValues[10], originTransformValues[11]),
            SIMD4<Float>(originTransformValues[12], originTransformValues[13], originTransformValues[14], originTransformValues[15])
        )
    }
}

/// 저장한 디자인 오브젝트를 보관하고 다시 엔티티로 만들어 주는 컬렉션.
/// Application Support/Collection 안에 `<id>.json`(기하·사양)과 `<id>.png`(텍스처)로 저장한다.
@Observable
@MainActor
final class ObjectCollection {
    private(set) var items: [DesignObject] = []
    private(set) var lastIssue: String?

    private var textureCache: [UUID: CGImage] = [:]

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Collection", isDirectory: true)
    }

    // MARK: - 로드·저장

    func load() {
        ensureFolder()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        var loaded: [DesignObject] = []
        var skipped = 0
        for name in names where name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONDecoder().decode(DesignObject.self, from: data) else {
                skipped += 1
                continue
            }
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(object.textureFileName).path) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            loaded.append(object)
        }
        items = loaded.sorted { $0.createdAt > $1.createdAt }
        if skipped > 0 {
            lastIssue = "형식이 달라 읽지 못한 항목 \(skipped)개를 건너뛰었습니다"
        }
    }

    private func ensureFolder() {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastIssue = "컬렉션 폴더 생성 실패: \(error.localizedDescription)"
        }
    }

    /// 결과를 컬렉션에 담는다.
    @discardableResult
    func save(result: DesignResult, geometry: RegionGeometry) -> DesignObject? {
        ensureFolder()
        let id = UUID()
        let textureFileName = "\(id.uuidString).png"

        guard let pngData = UIImage(cgImage: result.texture).pngData() else {
            lastIssue = "텍스처 PNG 변환 실패"
            return nil
        }
        do {
            try pngData.write(to: folder.appendingPathComponent(textureFileName), options: .atomic)
        } catch {
            lastIssue = "텍스처 저장 실패: \(error.localizedDescription)"
            return nil
        }

        // 기하는 로컬 좌표만 남기고, 원래 자리는 따로 기록한다.
        var localGeometry = geometry
        localGeometry.transform = matrix_identity_float4x4

        let object = DesignObject(
            id: id,
            name: result.restyle.title,
            surface: result.surface,
            restyle: result.restyle,
            geometry: localGeometry,
            textureFileName: textureFileName,
            originTransformValues: geometry.transformValues,
            createdAt: Date()
        )
        do {
            let data = try JSONEncoder().encode(object)
            try data.write(to: folder.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        } catch {
            lastIssue = "컬렉션 저장 실패: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(textureFileName))
            return nil
        }

        textureCache[id] = result.texture
        items.insert(object, at: 0)
        return object
    }

    func rename(_ object: DesignObject, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == object.id }) else { return }
        items[index].name = name
        persist(items[index])
    }

    private func persist(_ object: DesignObject) {
        guard let data = try? JSONEncoder().encode(object) else { return }
        try? data.write(to: folder.appendingPathComponent("\(object.id.uuidString).json"), options: .atomic)
    }

    func remove(_ object: DesignObject) {
        items.removeAll { $0.id == object.id }
        textureCache[object.id] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(object.id.uuidString).json"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(object.textureFileName))
    }

    // MARK: - 읽기

    func texture(for object: DesignObject) -> CGImage? {
        if let cached = textureCache[object.id] { return cached }
        let url = folder.appendingPathComponent(object.textureFileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        textureCache[object.id] = image
        return image
    }

    /// 저장한 오브젝트를 다시 엔티티로 만든다. 손으로 옮기고 돌릴 수 있다.
    func makeEntity(for object: DesignObject) async -> ModelEntity? {
        guard let texture = texture(for: object) else {
            lastIssue = "텍스처를 읽을 수 없습니다"
            return nil
        }
        do {
            let mesh = try object.geometry.makeMesh()
            let resource = try await TextureResource(image: texture, options: .init(semantic: .color))
            let entity = ModelEntity()
            entity.name = "collection:\(object.id.uuidString)"
            entity.model = ModelComponent(
                mesh: mesh,
                materials: [DesignMaterial.make(for: object.restyle, texture: resource, isShell: object.geometry.isShell)]
            )
            let shape = object.geometry.makeCollisionShape()
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(shapes: [shape]))
            entity.components.set(GroundingShadowComponent(castsShadow: true))
            ManipulationComponent.configureEntity(entity, collisionShapes: [shape])
            return entity
        } catch {
            lastIssue = "오브젝트 생성 실패: \(error.localizedDescription)"
            return nil
        }
    }
}

/// 리스타일 사양을 RealityKit 재질로 옮기는 공용 도우미.
enum DesignMaterial {
    static func make(for restyle: ObjectRestyle, texture: TextureResource, isShell: Bool) -> any RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture))
        // 닫힌 입체는 뒷면을 잘라내야 조명과 음영이 제대로 계산된다.
        material.faceCulling = isShell ? .back : .none

        switch restyle.finish {
        case .matte:
            material.roughness = .init(floatLiteral: 0.85)
            material.metallic = .init(floatLiteral: 0)
        case .glossy:
            material.roughness = .init(floatLiteral: 0.18)
            material.metallic = .init(floatLiteral: 0.05)
            material.clearcoat = .init(floatLiteral: 1)
            material.clearcoatRoughness = .init(floatLiteral: 0.12)
        case .metallic:
            material.roughness = .init(floatLiteral: 0.3)
            material.metallic = .init(floatLiteral: 0.9)
        case .fabric:
            material.roughness = .init(floatLiteral: 1)
            material.metallic = .init(floatLiteral: 0)
        case .wood:
            material.roughness = .init(floatLiteral: 0.55)
            material.metallic = .init(floatLiteral: 0)
        case .neon:
            material.roughness = .init(floatLiteral: 0.45)
            material.emissiveColor = .init(color: .white, texture: .init(texture))
            material.emissiveIntensity = 1.4
        }
        return material
    }

    /// 판단을 기다리는 동안 보여 줄 반투명 재질.
    static func placeholder() -> any RealityKit.Material {
        var material = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.28))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.28))
        material.faceCulling = .none
        return material
    }
}
