import SwiftUI

/// 모든 조작이 모여 있는 제어 창.
/// 공간에 떠 있는 라벨에는 버튼을 두지 않아 탭이 서로 부딪히지 않는다.
struct ControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    scanSection
                    shapeModeSection(model: $model)
                    if model.isScanning {
                        aimSection
                    }
                    selectedSection
                    requestSection(model: $model)
                    collectionSection
                    logSection
                }
                .padding(28)
            }
            .navigationTitle("사물 리디자인")
        }
        .task {
            model.bootstrap()
        }
    }

    // MARK: - 1단계: 인식 켜기

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await toggleScanning() }
            } label: {
                Text(model.isScanning ? "사물 인식 끄기" : "사물 인식 시작")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isScanning ? .red : .accentColor)

            HStack(spacing: 10) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Text(model.statusText)
                    .font(.headline)
            }

            HStack(spacing: 12) {
                capability("brain.head.profile", model.brain.isAvailable, model.brain.availabilityDescription)
                capability(
                    "cube.transparent",
                    model.sceneUnderstanding.isRunning,
                    model.sceneUnderstanding.isRunning
                        ? "라이다 스캔 중 · 메시 \(model.sceneUnderstanding.meshAnchorCount) · 평면 \(model.sceneUnderstanding.planeAnchorCount)"
                        : model.sceneUnderstanding.statusDescription
                )
            }
        }
    }

    private func toggleScanning() async {
        if model.isScanning {
            // 공간이 사라질 때 DesignSpaceView가 상태를 정리한다.
            await dismissSpace()
        } else {
            switch await openSpace(id: DesignApp.designSpaceID) {
            case .opened:
                model.isScanning = true
            case .userCancelled, .error:
                model.isScanning = false
                model.noteSpaceOpenFailed()
            @unknown default:
                model.isScanning = false
            }
        }
    }

    // MARK: - 모양 방식

    private func shapeModeSection(model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("모양 만드는 방식")
                .font(.headline)
            Picker("모양", selection: model.shapeMode) {
                ForEach(ShapeMode.allCases) { mode in
                    Text(mode.koreanName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(self.model.shapeMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func capability(_ symbol: String, _ ok: Bool, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .lineLimit(2)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(ok ? .green : .orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 2단계: 사물 고르기

    private var aimSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.isArmed ? "viewfinder.circle.fill" : "viewfinder.circle")
                    .font(.title2)
                    .foregroundStyle(model.isArmed ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isArmed ? "고르기 켜짐" : "고르기 꺼짐")
                        .font(.headline)
                    Text(model.isArmed
                         ? "바꿀 사물을 바라보고 손가락을 맞대세요. 하나를 고르면 자동으로 꺼집니다."
                         : "실수로 다른 사물이 바뀌지 않도록 꺼 두었습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    model.armForNextObject()
                } label: {
                    Label("다음 사물 고르기", systemImage: "hand.tap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isArmed || model.isWorking)

                if model.isArmed {
                    Button("고르기 멈추기") { model.disarm() }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 3단계: 고른 사물 조작

    @ViewBuilder
    private var selectedSection: some View {
        if let patch = model.selectedPatch {
            VStack(alignment: .leading, spacing: 12) {
                Text("고른 사물")
                    .font(.title3.bold())

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: patch.surface.symbolName)
                        .font(.title)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(patch.title)
                            .font(.headline)
                        if !patch.subtitle.isEmpty {
                            Text(patch.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(patch.surface.koreanName)
                            Text(patch.target.koreanName)
                                .foregroundStyle(patch.target == .background ? .orange : .green)
                        }
                        .font(.caption2)
                    }
                    Spacer(minLength: 0)
                    if patch.state == .thinking {
                        ProgressView().controlSize(.small)
                    }
                }

                // 큰 버튼을 나란히 둔다. 공간에 떠 있는 라벨 대신 여기서 조작한다.
                HStack(spacing: 10) {
                    Button {
                        Task { await model.redesignSelected() }
                    } label: {
                        Label("다른 색", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .disabled(model.isWorking || patch.state == .thinking)

                    Button {
                        model.saveSelectedToCollection()
                    } label: {
                        Label(patch.isSaved ? "담김" : "컬렉션에 담기",
                              systemImage: patch.isSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(patch.isSaved || !model.canSaveSelected)

                    Button(role: .destructive) {
                        model.removeSelected()
                    } label: {
                        Label("지우기", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                }

                if model.patches.count > 1 {
                    Button("공간에서 모두 지우기") { model.clearPatches() }
                        .controlSize(.small)
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - 요청

    private func requestSection(model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("어떻게 바꿀까요")
                .font(.title3.bold())
            Text("사물의 색을 바꾸고, 원하면 짧은 글자를 넣습니다. 패턴이나 그림은 넣지 않고 사물 본래의 윤곽을 유지합니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("예: 무광 검정에 'MW' 글자", text: model.requestText, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            ScrollView(.horizontal) {
                HStack {
                    ForEach(AppModel.sampleRequests, id: \.self) { sample in
                        Button(sample) { model.wrappedValue.requestText = sample }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - 컬렉션

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("내 컬렉션")
                    .font(.title3.bold())
                Spacer()
                Text("\(model.collection.items.count)개")
                    .foregroundStyle(.secondary)
            }
            Text("마음에 든 결과는 사물 윤곽 그대로 하나의 오브젝트로 저장됩니다. 다시 놓으면 손으로 집어 옮길 수 있습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if model.collection.items.isEmpty {
                Text("색이 적용되면 위의 \"컬렉션에 담기\"를 누르세요.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(model.collection.items) { object in
                        CollectionCard(object: object)
                    }
                }
            }

            if !model.placedObjects.isEmpty {
                HStack {
                    Text("공간에 놓은 오브젝트 \(model.placedObjects.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("모두 치우기") { model.clearPlaced() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 로그

    private var logSection: some View {
        DisclosureGroup("진행 기록") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.log) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Text(entry.text)
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - 부속 뷰

/// 컬렉션에 담긴 오브젝트 하나.
private struct CollectionCard: View {
    @Environment(AppModel.self) private var model
    let object: DesignObject
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let texture = model.collection.texture(for: object) {
                Image(decorative: texture, scale: 1)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(height: 104)
            }

            HStack(spacing: 6) {
                Image(systemName: object.surface.symbolName)
                    .font(.caption)
                Text(object.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Text("\(object.surface.koreanName) · \(object.geometry.isShell ? "입체" : "표면") · \(object.geometry.sizeDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                Task { await model.place(object) }
            } label: {
                Label("공간에 놓기", systemImage: "arrow.down.forward.and.arrow.up.backward")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(!model.isScanning)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button {
                draftName = object.name
                isRenaming = true
            } label: {
                Label("이름 바꾸기", systemImage: "pencil")
            }
            Button(role: .destructive) {
                model.collection.remove(object)
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
        .alert("이름 바꾸기", isPresented: $isRenaming) {
            TextField("이름", text: $draftName)
            Button("저장") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.collection.rename(object, to: trimmed) }
            }
            Button("취소", role: .cancel) {}
        }
    }
}

#Preview(windowStyle: .automatic) {
    ControlView()
        .environment(AppModel())
}
