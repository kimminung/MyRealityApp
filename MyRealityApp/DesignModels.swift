import Foundation
import FoundationModels
import SwiftUI
import CoreGraphics

// MARK: - 사물 분류

/// ARKit 표면 분류를 앱 공통 어휘로 통일한 사물 종류.
nonisolated enum SurfaceKind: String, Codable, CaseIterable, Sendable {
    case wall, floor, ceiling, table, seat, window, door, stairs, bed, cabinet, homeAppliance, tv, plant, unknown

    var koreanName: String {
        switch self {
        case .wall: "벽"
        case .floor: "바닥"
        case .ceiling: "천장"
        case .table: "테이블"
        case .seat: "의자·소파"
        case .window: "창문"
        case .door: "문"
        case .stairs: "계단"
        case .bed: "침대"
        case .cabinet: "수납장"
        case .homeAppliance: "가전제품"
        case .tv: "TV·모니터"
        case .plant: "식물"
        case .unknown: "사물"
        }
    }

    /// 모델 프롬프트에 넣을 영어 표현.
    var englishName: String {
        switch self {
        case .homeAppliance: "home appliance"
        case .tv: "TV or monitor"
        case .unknown: "object"
        default: rawValue
        }
    }

    var symbolName: String {
        switch self {
        case .wall: "rectangle.portrait"
        case .floor: "square.dashed"
        case .ceiling: "rectangle.topthird.inset.filled"
        case .table: "table.furniture"
        case .seat: "chair"
        case .window: "window.casement"
        case .door: "door.left.hand.closed"
        case .stairs: "stairs"
        case .bed: "bed.double"
        case .cabinet: "cabinet"
        case .homeAppliance: "refrigerator"
        case .tv: "tv"
        case .plant: "leaf"
        case .unknown: "cube"
        }
    }
}

// MARK: - 온디바이스 모델 출력 타입

/// 마감 질감. 색을 어떤 재질감으로 보여 줄지 정한다.
@Generable(description: "사물 표면의 마감 질감")
enum FinishKind: String, CaseIterable, Codable {
    case matte
    case glossy
    case metallic
    case fabric
    case wood
    case neon
}

/// 사물의 색과 글자만 바꾸는 리스타일 사양.
/// 패턴이나 참고 이미지를 쓰지 않고, 그 사물 본래의 모습에서 색과 글자만 갈아 끼운다.
@Generable(description: "사물의 색과 글자만 바꾸는 리스타일 사양")
struct ObjectRestyle: Equatable, Codable {
    @Guide(description: "디자인 제목. 한국어, 12자 이내")
    var title: String

    @Guide(description: "왜 이 색과 글자가 이 사물과 사용자의 요청에 맞는지 한국어 한두 문장")
    var rationale: String

    @Guide(description: "사물의 새 기본 색. #RRGGBB 형식")
    var baseColor: String

    @Guide(description: "테두리와 음영에 쓸 보조 색. 기본 색과 어울리는 어두운 톤. #RRGGBB 형식")
    var accentColor: String

    @Guide(description: "사물 앞면에 넣을 짧은 글자. 필요 없으면 빈 문자열. 최대 12자")
    var label: String

    @Guide(description: "글자 색. 기본 색 위에서 잘 읽히는 색. #RRGGBB 형식")
    var labelColor: String

    @Guide(description: "마감 질감")
    var finish: FinishKind

    /// 유효한 16진수 색만 남기고, 비면 기본값으로 채운 사양.
    var sanitized: ObjectRestyle {
        var copy = self
        copy.baseColor = HexColor.normalize(baseColor) ?? "#3C6E9F"
        copy.accentColor = HexColor.normalize(accentColor) ?? "#1E3A52"
        copy.labelColor = HexColor.normalize(labelColor) ?? "#FFFFFF"
        copy.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "새 색상" : copy.title
        return copy
    }
}

// MARK: - 결과 및 상태

/// 한 번의 리스타일 수행 결과.
struct DesignResult: Identifiable {
    let id = UUID()
    let surface: SurfaceKind
    let requestText: String
    let restyle: ObjectRestyle
    let texture: CGImage
    let target: SurfaceHit.Target
    let geometrySource: String
    let usedLanguageModel: Bool
    let createdAt = Date()
}

/// 공간에 적용한 리스타일의 표시 상태.
struct DesignPatch: Identifiable, Equatable {
    enum State: Equatable {
        case thinking
        case ready
        case failed
    }

    let id: UUID
    var surface: SurfaceKind
    /// 사물 중심(월드)
    var center: SIMD3<Float>
    /// 사용자를 향하는 방향(월드)
    var normal: SIMD3<Float>
    /// 독립 사물인지, 평면 사물인지, 배경 표면인지.
    var target: SurfaceHit.Target
    /// 라벨을 사물에서 얼마나 떨어뜨릴지(미터).
    var labelDistance: Float
    var title: String
    var subtitle: String
    var state: State
    /// 컬렉션에 이미 담았는지.
    var isSaved = false

    /// 라벨은 사물 크기에 맞춰 떨어진 곳에 띄운다.
    var labelPosition: SIMD3<Float> {
        center + normal * labelDistance
    }
}

// MARK: - 색상 도우미

extension Color {
    /// "#RRGGBB" 문자열을 Color로. 실패하면 nil.
    init?(hex: String) {
        guard let rgb = HexColor.components(from: hex) else { return nil }
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

nonisolated enum HexColor {
    /// "#1E3A5F" 또는 "1E3A5F"를 0...1 범위 RGB로 변환.
    static func components(from hex: String) -> (r: Double, g: Double, b: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// 유효한 색이면 "#RRGGBB"로 정규화해 돌려준다.
    static func normalize(_ hex: String) -> String? {
        guard let rgb = components(from: hex) else { return nil }
        return string(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    static func cgColor(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let rgb = components(from: hex) ?? (0.5, 0.5, 0.5)
        return CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    static func string(r: Double, g: Double, b: Double) -> String {
        let clamp = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// 색을 밝게(또는 어둡게) 조정한다.
    static func adjusted(_ hex: String, by amount: Double) -> CGColor {
        let rgb = components(from: hex) ?? (0.5, 0.5, 0.5)
        return CGColor(
            srgbRed: min(max(rgb.r + amount, 0), 1),
            green: min(max(rgb.g + amount, 0), 1),
            blue: min(max(rgb.b + amount, 0), 1),
            alpha: 1
        )
    }
}
