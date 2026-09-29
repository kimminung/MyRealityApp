import Foundation
import FoundationModels

/// 온디바이스 Foundation Models로 "이 사물을 어떤 색과 글자로 바꿀지"를 판단한다.
/// 참고 이미지 검색은 쓰지 않는다. 사물 종류·크기와 사용자의 요청만 근거로 삼는다.
@Observable
@MainActor
final class DesignBrain {
    private(set) var isAvailable = false
    private(set) var availabilityDescription = "확인 중…"

    private let model = SystemLanguageModel.default

    /// 모델 공통 지침. 문서 권고대로 로케일 문구를 정확히 포함한다.
    private var instructions: String {
        """
        The person's locale is ko_KR.
        You restyle a real physical object that the person is looking at through Apple Vision Pro.
        You may ONLY change its color and optional short lettering. Never invent patterns, textures,
        images, logos or decorations. Keep the object recognizable as itself.
        Choose colors that suit the kind of object and the person's request.
        Title and rationale MUST be in Korean. Colors MUST be #RRGGBB hex.
        """
    }

    func refreshAvailability() {
        switch model.availability {
        case .available:
            isAvailable = true
            availabilityDescription = "온디바이스 Apple Intelligence 사용 가능"
        case .unavailable(let reason):
            isAvailable = false
            switch reason {
            case .appleIntelligenceNotEnabled:
                availabilityDescription = "설정에서 Apple Intelligence를 켜 주세요"
            case .deviceNotEligible:
                availabilityDescription = "이 기기는 Apple Intelligence를 지원하지 않습니다"
            case .modelNotReady:
                availabilityDescription = "모델 다운로드 중입니다. 잠시 후 다시 시도하세요"
            @unknown default:
                availabilityDescription = "Apple Intelligence를 사용할 수 없습니다"
            }
        }
    }

    /// 사물 종류·크기와 사용자의 요청으로 새 색과 글자를 정한다.
    func restyle(
        request: String,
        surface: SurfaceKind,
        sizeDescription: String,
        target: SurfaceHit.Target
    ) async -> (restyle: ObjectRestyle, usedModel: Bool) {
        guard isAvailable else {
            return (fallback(request: request, surface: surface), false)
        }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                generating: ObjectRestyle.self,
                options: GenerationOptions(temperature: 0.6)
            ) {
                """
                Object kind: \(surface.englishName)
                Approximate size: \(sizeDescription)
                Shape: \(Self.shapeDescription(for: target))
                The person's request (Korean): "\(request)"

                Decide the object's new base color, a matching darker accent color for edges and shading,
                a finish, and optional short lettering to print on the front.
                Rules:
                - If the request names a color, use exactly that color family.
                - If the request names text, initials or a word, put it in `label`; otherwise leave `label` empty.
                - Pick `finish` from the object's likely material: cups and appliances tend to be glossy,
                  fabric seats are fabric, wood furniture is wood, plants are matte.
                - `accentColor` must be clearly darker than `baseColor`.
                - `labelColor` must contrast with `baseColor`.
                """
            }
            return (response.content.sanitized, true)
        } catch {
            return (fallback(request: request, surface: surface), false)
        }
    }

    /// 대상 종류를 모델이 이해할 영어 문구로.
    private static func shapeDescription(for target: SurfaceHit.Target) -> String {
        switch target {
        case .object: "a standalone object separated from the wall or floor behind it"
        case .panel: "a flat panel-like object such as a window, door or tabletop"
        case .background: "a part of a large background surface such as a wall or floor"
        }
    }

    // MARK: - 대체 로직

    /// 모델이 없을 때 요청 문구의 색 이름을 찾아 쓰는 규칙 기반 사양.
    func fallback(request: String, surface: SurfaceKind) -> ObjectRestyle {
        let lowered = request.lowercased()
        var base = "#3C6E9F"
        for (keywords, hex) in Self.colorKeywords {
            if keywords.contains(where: { lowered.contains($0) }) {
                base = hex
                break
            }
        }

        let finish: FinishKind
        switch surface {
        case .seat, .bed: finish = .fabric
        case .table, .cabinet: finish = .wood
        case .plant: finish = .matte
        case .tv, .homeAppliance, .window: finish = .glossy
        default: finish = .matte
        }

        // 따옴표 안의 문구가 있으면 글자로 쓴다.
        var label = ""
        if let match = request.firstMatch(of: /["'“”‘’]([^"'“”‘’]{1,12})["'“”‘’]/) {
            label = String(match.1)
        }

        let rgb = HexColor.components(from: base) ?? (0.2, 0.4, 0.6)
        let accent = HexColor.string(r: rgb.r * 0.55, g: rgb.g * 0.55, b: rgb.b * 0.55)
        let isLight = (rgb.r + rgb.g + rgb.b) / 3 > 0.6

        return ObjectRestyle(
            title: "\(surface.koreanName) 새 색",
            rationale: "요청에서 찾은 색으로 규칙 기반 적용했습니다. Apple Intelligence를 켜면 더 정교하게 판단합니다.",
            baseColor: base,
            accentColor: accent,
            label: label,
            labelColor: isLight ? "#1A1A1A" : "#FFFFFF",
            finish: finish
        ).sanitized
    }

    /// 한국어·영어 색 이름과 대표 색.
    private static let colorKeywords: [([String], String)] = [
        (["빨강", "빨간", "레드", "red"], "#C0392B"),
        (["주황", "오렌지", "orange"], "#E07B2C"),
        (["노랑", "노란", "옐로", "yellow"], "#E8C547"),
        (["초록", "녹색", "그린", "green"], "#3E8E5A"),
        (["파랑", "파란", "블루", "blue"], "#2E5E9E"),
        (["남색", "네이비", "navy"], "#1B2A4A"),
        (["보라", "퍼플", "purple", "violet"], "#6B4E9B"),
        (["분홍", "핑크", "pink"], "#D9748F"),
        (["갈색", "브라운", "brown", "우드", "나무"], "#8A5A3B"),
        (["검정", "검은", "블랙", "black"], "#1C1C1E"),
        (["하양", "흰", "화이트", "white"], "#F2F2F0"),
        (["회색", "그레이", "gray", "grey"], "#8E8E93"),
        (["금색", "골드", "gold"], "#C9A227"),
        (["은색", "실버", "silver"], "#B8BDC4"),
    ]
}
