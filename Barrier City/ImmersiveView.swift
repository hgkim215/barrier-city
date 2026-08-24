import SwiftUI
import RealityKit
import RealityKitContent
import OSLog

/// RealityView 클로저가 직접 갱신하는 렌더링 참조.
/// SwiftUI 관찰 대상이 아닌 참조 타입에 보관해 view update 도중 @State를 변경하지 않는다.
@MainActor
private final class ImmersiveRuntimeState {
    var leftWheel: Entity?
    var rightWheel: Entity?
    var leftWheelMesh: Entity?
    var rightWheelMesh: Entity?
    var leftBaseMats: [any RealityKit.Material] = []
    var rightBaseMats: [any RealityKit.Material] = []
    var leftHiMats: [any RealityKit.Material] = []
    var rightHiMats: [any RealityKit.Material] = []
    var wheelsHighlighted = false
}

/// 몰입 공간 본체: 평지 + 거리 마커 기둥 + 양옆 바퀴.
struct ImmersiveView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BarrierCity",
        category: "ImmersiveScene")

    @State private var runtime = ImmersiveRuntimeState()
    @State private var handTracker = HandTrackingManager()
    @State private var immersiveSessionGeneration: Int?

    // 휠체어 모델 배치(보고 조정할 튜닝값)
    private static let chairScale: Float = 0.95                  // 전체(몸체 기준) 크기
    private static let wheelScale: Float = 1.45                  // 뒷바퀴에만 추가 배율(>1 키움, <1 줄임)
    private static let wheelForward: Float = 0.28               // 뒷바퀴를 앞으로(-Z) 당기는 양(m)
    private static let wheelUp: Float = 0.03                    // 뒷바퀴를 위로(+Y) 올리는 양(m, 프레임 대비)
    private static let wheelSpread: Float = 0.06                // 뒷바퀴를 좌우 바깥으로 벌리는 양(m, 한쪽)
    private static let chairYaw: Float = 0                       // 앞뒤 반대면 .pi
    // 바닥 자동 안착 후 추가 보정. y: 0=바닥에 딱, 음수=더 아래(박힘), 양수=더 위로. z: 양수=뒤로.
    private static let chairOffset = SIMD3<Float>(0, 0.0, 0.08)
    // 바퀴는 그대로 두고 '몸체만' 아래로 내리는 양(m). 전체를 내린 뒤 바퀴를 같은 만큼 올림.
    private static let bodyDrop: Float = 0.08

    var body: some View {
        // body가 이 값들을 '읽어' 관찰 의존성을 만든다.
        // 그래야 System이 매 프레임 이 값을 바꿀 때 body가 다시 평가되고,
        // 아래 RealityView update 클로저가 재실행되어 하이라이트/바퀴 회전이 반영된다.
        let _ = (model.leftGrabbed, model.rightGrabbed,
                 model.motion.leftWheelAngle, model.motion.rightWheelAngle,
                 model.fistDriveActive)

        return RealityView { content, attachments in
            // System이 읽을 입력 소스를 '실제 화면에 쓰이는' 이 모델로 고정.
            AppModel.current = model

            // 렌더 공간: 보이는 카페. System이 캡슐 위치의 역(inverse)으로 매 프레임 배치.
            let worldRoot = Entity()
            worldRoot.name = "worldRoot"
            worldRoot.components.set(WheelchairComponent())
            content.add(worldRoot)
            model.worldRoot = worldRoot
            AmbientSceneAudioController.shared.play(resource: "background_sound_outdoor", worldRoot: worldRoot)

            do {
                let outdoorVisible = try await Entity(
                    named: ImmersiveSceneCatalog.outdoor,
                    in: realityKitContentBundle)
                let outdoorCollision = outdoorVisible.clone(recursive: true)
                let groundLayout = SceneEntityPreparation.groundLayout(in: outdoorVisible)
                InteractionModel.shared.outdoorGroundLayout = groundLayout

                SceneEntityPreparation.prepareVisible(outdoorVisible)
                worldRoot.addChild(outdoorVisible)
                InteractionModel.shared.visibleMap = outdoorVisible

                // 시뮬 공간(고정·투명): authored Collision뿐 아니라 계단·경사로·건물 등
                // 실제 Outdoor 메시도 정적 충돌로 변환한다.
                var n = await SceneEntityPreparation.prepareCollision(
                    outdoorCollision,
                    includeSceneGeometry: true)
                if let groundLayout {
                    content.add(SceneEntityPreparation.makeGroundFallback(groundLayout))
                    n += 1
                }
                model.motion.collisionShapeCount = n
                content.add(outdoorCollision)
                InteractionModel.shared.collisionMap = outdoorCollision
            } catch {
                Self.logger.error(
                    "Outdoor scene \(ImmersiveSceneCatalog.outdoor, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
            }

            // 바닥 충돌은 각 씬의 authored collision(Outdoor: /Root/Collision,
            // Indoor: /Root/collision)이 제공한다. 예전에는 여기서 16x16 박스를
            // y=-0.1(윗면 +0.1)에 깔았지만, 맵마다 바닥 높이가 달라(실외 -0.188,
            // 실내 +0.003) 휠체어가 떠 보이는 원인이 되어 제거했다.

            // (캐릭터 캡슐 없음) 위치/자세는 System이 직접 적분하고, 충돌은 광선으로 메시를 읽는다.

            // 조명: 주광(방향광) + 부드러운 보조광
            let keyLight = Entity()
            let dl = DirectionalLightComponent(color: .white, intensity: 3500)
            keyLight.components.set(dl)
            keyLight.look(at: [0, 0, 0], from: [3, 6, 4], relativeTo: nil)
            content.add(keyLight)

            // 보조광: 방향광으로 둔다(점광원은 매트한 실내 바닥에 원형 빛 웅덩이를
            // 만들어 거슬리므로). 주광 반대편에서 부드럽게 채운다.
            let fillLight = Entity()
            fillLight.components.set(DirectionalLightComponent(color: .white, intensity: 1500))
            fillLight.look(at: [0, 0, 0], from: [-3, 5, -2], relativeTo: nil)
            content.add(fillLight)

            // 휠체어 USDZ(본체 + 뒷바퀴 분리). 사용자 기준 고정(content)에 둔다.
            if let chair = try? await Entity(named: "WhellChair", in: realityKitContentBundle) {
                let chairRoot = Entity()
                chairRoot.addChild(chair)
                chairRoot.scale = SIMD3(repeating: Self.chairScale)
                chairRoot.orientation = simd_quatf(angle: Self.chairYaw, axis: [0, 1, 0])
                chairRoot.position = SIMD3(Self.chairOffset.x, 0, Self.chairOffset.z)
                content.add(chairRoot)
                model.characterBody = chairRoot

                // 뒷바퀴 노드를 찾아 굴림 대상으로 보관(X축이 축 → X축 회전이 굴림).
                let wl = chair.findEntity(named: "Roda_Traseira_L")
                let wr = chair.findEntity(named: "Roda_Traseira_R")
                // 몸체와 별개로 뒷바퀴만 추가 배율(허브 중심으로 커짐 → 제자리에서 크기만 변함).
                if let wl { wl.scale = wl.scale * Self.wheelScale }
                if let wr { wr.scale = wr.scale * Self.wheelScale }
                runtime.leftWheel = wl
                runtime.rightWheel = wr

                // 뒷바퀴를 앞으로(-Z)·위로(+Y)·좌우 바깥으로 이동(chairRoot 기준).
                // 바닥 안착 '전'에 적용해 허브를 올리면 프레임이 바퀴 위로 더 내려앉는다.
                // L은 -X(왼쪽), R은 +X(오른쪽)로 벌린다.
                if let wl {
                    let p = wl.position(relativeTo: chairRoot)
                    wl.setPosition(p + SIMD3<Float>(-Self.wheelSpread, Self.wheelUp, -Self.wheelForward), relativeTo: chairRoot)
                }
                if let wr {
                    let p = wr.position(relativeTo: chairRoot)
                    wr.setPosition(p + SIMD3<Float>(Self.wheelSpread, Self.wheelUp, -Self.wheelForward), relativeTo: chairRoot)
                }

                // 모델 바닥을 바닥(y=0)에 자동 안착(바퀴 배율·이동 반영 후) + 수동 보정.
                let wb = chair.visualBounds(relativeTo: nil)
                chairRoot.position.y = -wb.min.y + Self.chairOffset.y

                // 몸체만 내리기: 전체를 bodyDrop만큼 내린 뒤, 바퀴는 월드 기준 같은 만큼 올림.
                chairRoot.position.y -= Self.bodyDrop
                if let wl {
                    let w = wl.position(relativeTo: nil)
                    wl.setPosition(w + SIMD3<Float>(0, Self.bodyDrop, 0), relativeTo: nil)
                }
                if let wr {
                    let w = wr.position(relativeTo: nil)
                    wr.setPosition(w + SIMD3<Float>(0, Self.bodyDrop, 0), relativeTo: nil)
                }

                // 시점 높이 보정: 바닥과 함께 휠체어도 같은 만큼 올려 정합 유지.
                chairRoot.position.y += AppModel.viewHeightOffset

                Self.addGroundingShadow(chairRoot)

                // 잡힘 하이라이트: 뒷바퀴 메시를 찾아 발광(emissive) 틴트 버전을 미리 준비.
                if let mesh = Self.firstModelEntity(wl), let comp = mesh.components[ModelComponent.self] {
                    runtime.leftWheelMesh = mesh
                    runtime.leftBaseMats = comp.materials
                    runtime.leftHiMats = Self.emissiveTinted(comp.materials)
                }
                if let mesh = Self.firstModelEntity(wr), let comp = mesh.components[ModelComponent.self] {
                    runtime.rightWheelMesh = mesh
                    runtime.rightBaseMats = comp.materials
                    runtime.rightHiMats = Self.emissiveTinted(comp.materials)
                }
            }

            // [김현기] 공간 인터랙션: 근접 패널 attachment + 문 트리거 + 매 프레임 판정 구독
            InteractionSetup.install(content: content, attachments: attachments, appModel: model)

        } update: { _, _ in
            // 미는 정도(속도)에 따라 뒷바퀴 굴림 회전 적용.
            // 기울기/덜컹/흔들림은 휠체어가 아니라 '세계'(System)가 처리한다.
            applyRoll(runtime.leftWheel, angle: model.motion.leftWheelAngle)
            applyRoll(runtime.rightWheel, angle: model.motion.rightWheelAngle)
            // 잡힘 하이라이트: 바퀴 메시 발광 틴트 적용/해제.
            let shouldHighlight = model.leftGrabbed || model.rightGrabbed || model.fistDriveActive
            if runtime.wheelsHighlighted != shouldHighlight {
                runtime.wheelsHighlighted = shouldHighlight
                setMaterials(runtime.leftWheelMesh,
                             shouldHighlight ? runtime.leftHiMats : runtime.leftBaseMats)
                setMaterials(runtime.rightWheelMesh,
                             shouldHighlight ? runtime.rightHiMats : runtime.rightBaseMats)
            }
        } attachments: {
            // [김현기] 사용자 눈앞 입장 패널(content-root 배치는 InteractionSetup이 처리)
            Attachment(id: "entryPrompt") {
                EntryPromptView()
            }
            // [김현기] 키오스크 주문 화면(고정 높이 장벽은 InteractionSetup이 처리)
            Attachment(id: "kioskScreen") {
                KioskOrderView()
            }
            // 온보딩과 미션 가이드(head lazy-follow는 QuestSetup이 처리)
            Attachment(id: "questHUD") {
                ExperienceGuideView(
                    model: .shared,
                    serving: model.rainbowSmoothieServing,
                    elapsedTime: model.experienceRunTimer.formattedElapsed)
            }
            // 점원 위에서 말 걸기 버튼과 발화 자막이 교대하는 공간 버블.
            Attachment(id: "npcInteraction") {
                NPCDialoguePanelView(controller: model.npcDialogue,
                                     clerk: model.npcClerk)
            }
        }
        .onAppear {
            immersiveSessionGeneration = model.immersiveSessionAppeared()
            AppModel.current = model
        }
        .onDisappear {
            handTracker.stopSession()
            guard let immersiveSessionGeneration,
                  model.immersiveSessionDisappeared(generation: immersiveSessionGeneration) else {
                return
            }
            QuestSetup.stop()
            model.rainbowSmoothieServing.resetForOutdoor()
            model.npcClerk.tearDownForOutdoor()
            model.npcGuests.tearDownForOutdoor()
            AmbientSceneAudioController.shared.stop()
            ImpactAudio.shared.stop()
            handTracker.clearModelInput(model: model)
            InteractionModel.shared.tearDown()
            model.worldRoot = nil
            model.characterBody = nil
            if AppModel.current === model {
                AppModel.current = nil
            }
            let resolution = StartExperienceFlow.resolve(.immersiveEnded)
            if resolution.windowAction == .openStartWindow {
                openWindow(id: AppSceneID.start)
            }
        }
        .task(id: model.useHandTracking) {
            // 창 토글을 몰입 공간 진입 뒤에 바꿔도 즉시 세션을 시작/종료한다.
            // 새 start 전에 반드시 이전 세대를 먼저 끊어 빠른 OFF→ON도 직렬화한다.
            handTracker.stop(model: model)
            if model.useHandTracking {
                await handTracker.start(model: model)
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    let target = value.entity
                    guard let app = AppModel.current else { return }
                    if let smoothie = app.rainbowSmoothiePresenter.smoothieEntity,
                       target.isDescendant(of: smoothie) {
                        app.pickupSmoothieIfReady()
                    }
                }
        )
    }

    // MARK: - Helpers

    /// USDZ 뒷바퀴 노드를 축(로컬 X) 기준으로 굴린다. (노드 기본 자세는 identity 가정)
    private func applyRoll(_ wheel: Entity?, angle: Float) {
        guard let wheel else { return }
        wheel.orientation = simd_quatf(angle: -angle, axis: [1, 0, 0])   // 전진 시 앞으로 구름
    }

    /// 서브트리에서 ModelComponent를 가진 첫 엔티티(실제 메시)를 찾는다.
    private static func firstModelEntity(_ e: Entity?) -> Entity? {
        guard let e else { return nil }
        if e.components[ModelComponent.self] != nil { return e }
        for c in e.children { if let m = firstModelEntity(c) { return m } }
        return nil
    }

    /// 원본 머티리얼에 발광(emissive) 틴트를 더한 버전(텍스처는 유지, 빛만 추가).
    private static func emissiveTinted(_ base: [any RealityKit.Material]) -> [any RealityKit.Material] {
        base.map { mat in
            if var pbm = mat as? PhysicallyBasedMaterial {
                pbm.emissiveColor = .init(color: UIColor(red: 0.25, green: 1.0, blue: 0.85, alpha: 1))
                pbm.emissiveIntensity = 0.5
                return pbm
            }
            return mat
        }
    }

    /// 메시 엔티티의 머티리얼 교체(발광 on/off).
    private func setMaterials(_ e: Entity?, _ mats: [any RealityKit.Material]) {
        guard let e, !mats.isEmpty, var comp = e.components[ModelComponent.self] else { return }
        comp.materials = mats
        e.components.set(comp)
    }

    /// 엔티티와 모든 하위 모델에 접지 그림자를 부여(바닥 그림자).
    private static func addGroundingShadow(_ entity: Entity) {
        entity.components.set(GroundingShadowComponent(castsShadow: true))
        for child in entity.children {
            addGroundingShadow(child)
        }
    }

}

private extension Entity {
    func isDescendant(of ancestor: Entity) -> Bool {
        var current: Entity? = self
        while let c = current {
            if c === ancestor { return true }
            current = c.parent
        }
        return false
    }
}
