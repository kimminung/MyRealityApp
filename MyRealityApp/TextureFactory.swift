import Foundation
import CoreGraphics
import CoreText
import UIKit

/// 리스타일 사양을 텍스처로 그린다.
/// 패턴은 쓰지 않고 기본 색 + 형태가 드러나는 음영 + 글자만 그린다.
enum TextureFactory {
    /// 무거운 드로잉은 메인 액터 밖에서 수행한다.
    @concurrent
    nonisolated static func render(restyle: ObjectRestyle, isShell: Bool, size: Int = 1024) async -> CGImage? {
        draw(restyle: restyle, isShell: isShell, size: size)
    }

    nonisolated static func draw(restyle: ObjectRestyle, isShell: Bool, size: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let base = HexColor.cgColor(restyle.baseColor)
        let accent = HexColor.cgColor(restyle.accentColor)

        // 1. 기본 색.
        context.setFillColor(base)
        context.fill(rect)

        if isShell {
            // 입체는 정면(u = 0.5)이 가장 밝고 측면·뒷면으로 갈수록 어두워지게 한다.
            // 실제 조명과 겹쳐 사물의 둥근 형태가 드러난다.
            drawGradient(
                context, rect: rect, horizontal: true,
                stops: [
                    (accent.copy(alpha: 0.85) ?? accent, 0.0),
                    (base.copy(alpha: 0.0) ?? base, 0.34),
                    (HexColor.adjusted(restyle.baseColor, by: 0.10).copy(alpha: 0.55) ?? base, 0.5),
                    (base.copy(alpha: 0.0) ?? base, 0.66),
                    (accent.copy(alpha: 0.85) ?? accent, 1.0),
                ]
            )
        } else {
            // 평면 조각은 가장자리만 살짝 어둡게 해 면의 경계를 보여 준다.
            context.setStrokeColor(accent.copy(alpha: 0.8) ?? accent)
            context.setLineWidth(CGFloat(size) * 0.02)
            context.stroke(rect.insetBy(dx: CGFloat(size) * 0.01, dy: CGFloat(size) * 0.01))
        }

        // 2. 위에서 내려오는 빛. 위는 밝고 아래는 어둡게.
        drawGradient(
            context, rect: rect, horizontal: false,
            stops: [
                (CGColor(gray: 0, alpha: 0.22), 0.0),
                (CGColor(gray: 0, alpha: 0.0), 0.45),
                (CGColor(gray: 1, alpha: 0.16), 1.0),
            ]
        )

        // 3. 마감 질감에 따른 미세 하이라이트.
        drawFinish(restyle.finish, in: context, rect: rect)

        // 4. 글자. 입체는 정면(가운데), 평면 조각도 가운데에 그린다.
        if !restyle.label.isEmpty {
            drawLabel(restyle.label, color: HexColor.cgColor(restyle.labelColor), in: context, rect: rect)
        }

        return context.makeImage()
    }

    // MARK: - 그리기 도우미

    private nonisolated static func drawGradient(
        _ context: CGContext,
        rect: CGRect,
        horizontal: Bool,
        stops: [(CGColor, CGFloat)]
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map(\.0) as CFArray,
            locations: stops.map(\.1)
        ) else { return }
        let start = horizontal ? CGPoint(x: rect.minX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY)
        let end = horizontal ? CGPoint(x: rect.maxX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }

    private nonisolated static func drawFinish(_ finish: FinishKind, in context: CGContext, rect: CGRect) {
        let size = rect.width
        switch finish {
        case .matte:
            break

        case .glossy:
            // 정면 위쪽에 좁은 반사 띠.
            let band = CGRect(x: rect.midX - size * 0.16, y: rect.maxY - size * 0.34,
                              width: size * 0.10, height: size * 0.22)
            context.saveGState()
            context.addEllipse(in: band)
            context.clip()
            context.setFillColor(CGColor(gray: 1, alpha: 0.35))
            context.fill(band)
            context.restoreGState()

        case .metallic:
            drawGradient(context, rect: rect, horizontal: false, stops: [
                (CGColor(gray: 1, alpha: 0.20), 0.0),
                (CGColor(gray: 0, alpha: 0.12), 0.35),
                (CGColor(gray: 1, alpha: 0.18), 0.62),
                (CGColor(gray: 0, alpha: 0.10), 1.0),
            ])

        case .fabric:
            // 미세한 직조 격자.
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.07))
            context.setLineWidth(1)
            var position: CGFloat = 0
            while position <= size {
                context.move(to: CGPoint(x: position, y: 0)); context.addLine(to: CGPoint(x: position, y: size))
                context.move(to: CGPoint(x: 0, y: position)); context.addLine(to: CGPoint(x: size, y: position))
                position += 7
            }
            context.strokePath()

        case .wood:
            // 완만한 나무결.
            context.setLineWidth(2)
            for index in 0..<26 {
                let baseY = CGFloat(index) * size / 24
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.05))
                context.move(to: CGPoint(x: 0, y: baseY))
                var x: CGFloat = 0
                while x <= size {
                    let y = baseY + sin(x / size * .pi * 3 + CGFloat(index)) * 8
                    context.addLine(to: CGPoint(x: x, y: y))
                    x += 14
                }
                context.strokePath()
            }

        case .neon:
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
            context.setLineWidth(size * 0.01)
            context.stroke(rect.insetBy(dx: size * 0.04, dy: size * 0.04))
        }
    }

    /// 글자를 가운데에 맞춰 그린다. 너비에 맞게 글자 크기를 자동으로 줄인다.
    private nonisolated static func drawLabel(
        _ text: String,
        color: CGColor,
        in context: CGContext,
        rect: CGRect
    ) {
        let targetWidth = rect.width * 0.34
        var fontSize = rect.width * 0.16
        var line: CTLine?
        var bounds = CGRect.zero

        // 글자 수에 맞게 크기를 맞춘다.
        for _ in 0..<8 {
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: UIColor(cgColor: color),
            ])
            let candidate = CTLineCreateWithAttributedString(attributed)
            let candidateBounds = CTLineGetBoundsWithOptions(candidate, [.useOpticalBounds])
            if candidateBounds.width <= targetWidth || fontSize <= rect.width * 0.04 {
                line = candidate
                bounds = candidateBounds
                break
            }
            fontSize *= targetWidth / candidateBounds.width
            line = candidate
            bounds = candidateBounds
        }
        guard let line else { return }

        context.saveGState()
        context.textMatrix = .identity
        // 읽기 쉽도록 글자 뒤에 옅은 그림자를 둔다.
        context.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.004),
                          blur: rect.width * 0.01,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.textPosition = CGPoint(
            x: rect.midX - bounds.width / 2 - bounds.minX,
            y: rect.midY - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
