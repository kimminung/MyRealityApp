import SwiftUI

@main
struct DesignApp: App {
    /// 사물 위에 디자인을 얹는 공간. 사용자는 창의 "사물 인식 시작" 버튼으로만 켠다.
    static let designSpaceID = "design-space"

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ControlView()
                .environment(model)
        }
        .defaultSize(width: 720, height: 900)

        ImmersiveSpace(id: Self.designSpaceID) {
            DesignSpaceView()
                .environment(model)
        }
    }
}
