import SwiftUI
import RealityKit
import RealityKitContent

/// 몰입 공간 본체: 평지 + 거리 마커 기둥 + 양옆 바퀴.
struct ImmersiveView: View {

    @Environment(AppModel.self) private var model

    @State private var leftWheel: Entity?     // USDZ 뒷바퀴 노드(Roda_Traseira_L)
    @State private var rightWheel: Entity?    // USDZ 뒷바퀴 노드(Roda_Traseira_R)
    @State private var leftWheelMesh: Entity?    // 뒷바퀴 메시(발광 틴트 대상)
    @State private var rightWheelMesh: Entity?
    @State private var leftBaseMats: [any RealityKit.Material] = []   // 원본 머티리얼
    @State private var rightBaseMats: [any RealityKit.Material] = []
    @State private var leftHiMats: [any RealityKit.Material] = []     // 발광 틴트 머티리얼
    @State private var rightHiMats: [any RealityKit.Material] = []
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
                 model.wheelAngleLeft, model.wheelAngleRight,
                 model.fistDriveActive)

        return RealityView { content, attachments in
            // System이 읽을 입력 소스를 '실제 화면에 쓰이는' 이 모델로 고정.
            AppModel.current = model

            // 렌더 공간: 보이는 카페. System이 캡슐 위치의 역(inverse)으로 매 프레임 배치.
            let worldRoot = Entity()
            worldRoot.name = "worldRoot"
            worldRoot.components.set(WheelchairComponent())
            if let cafeVisible = try? await Entity(named: "Map", in: realityKitContentBundle) {
                Self.stripPhysics(cafeVisible)    // USDA에 딸려온 RigidBody 제거(메시가 떨어지지 않게)
                Self.hideColliders(cafeVisible)   // 충돌용 단순 도형은 시각에서 숨김
                worldRoot.addChild(cafeVisible)
                InteractionModel.shared.visibleMap = cafeVisible   // [김현기] 씬 전환용 참조
            } else {
                print("⚠️ Immersive.usda(시각) 로드 실패 — 이름/번들 확인")
            }
            content.add(worldRoot)
            model.worldRoot = worldRoot

            // 시뮬 공간(고정·투명): 같은 카페의 콜리전 사본 + 캐릭터 캡슐.
            // 캡슐이 여기서 실제로 움직이며 벽·경사·턱에 부딪힌다. 시각은 worldRoot가 담당.
            if let cafeCollision = try? await Entity(named: "Map", in: realityKitContentBundle) {
                Self.stripPhysics(cafeCollision)   // USDA RigidBody 제거(우리가 콜리전만 따로 부여)
                let n = await Self.addStaticCollision(cafeCollision)
                model.collisionShapes = n
                cafeCollision.components.set(OpacityComponent(opacity: 0))   // 안 보이게(충돌만)
                content.add(cafeCollision)
                InteractionModel.shared.collisionMap = cafeCollision   // [김현기] 씬 전환용 참조
            } else {
                print("⚠️ Immersive.usda(콜리전) 로드 실패")
            }

            // [디버그] 무조건 착지하는 단순 바닥 콜리전(컨트롤러 동작 확인용).
            // 윗면이 y=0.1(보이는 바닥)과 맞게 두께 0.4 박스를 y=-0.1에.
            let floorShape = ShapeResource.generateBox(width: 16, height: 0.4, depth: 16)
            let floorCol = Entity()
            floorCol.name = "debugFloorCollision"
            floorCol.position = [0, -0.1, 0]
            var floorColC = CollisionComponent(shapes: [floorShape])
            floorColC.filter = CollisionFilter(group: AppModel.groundGroup, mask: .all)
            floorCol.components.set(floorColC)
            floorCol.components.set(PhysicsBodyComponent(shapes: [floorShape], mass: 0, mode: .static))
            content.add(floorCol)

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

                // 뒷바퀴 노드를 찾아 굴림 대상으로 보관(X축이 축 → X축 회전이 굴림).
                let wl = chair.findEntity(named: "Roda_Traseira_L")
                let wr = chair.findEntity(named: "Roda_Traseira_R")
                // 몸체와 별개로 뒷바퀴만 추가 배율(허브 중심으로 커짐 → 제자리에서 크기만 변함).
                if let wl { wl.scale = wl.scale * Self.wheelScale }
                if let wr { wr.scale = wr.scale * Self.wheelScale }
                leftWheel = wl
                rightWheel = wr

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
                    leftWheelMesh = mesh
                    leftBaseMats = comp.materials
                    leftHiMats = Self.emissiveTinted(comp.materials)
                }
                if let mesh = Self.firstModelEntity(wr), let comp = mesh.components[ModelComponent.self] {
                    rightWheelMesh = mesh
                    rightBaseMats = comp.materials
                    rightHiMats = Self.emissiveTinted(comp.materials)
                }
            } else {
                print("⚠️ WhellChair.usdz 로드 실패 — 이름/번들 확인")
            }

            // [김현기] 공간 인터랙션: 근접 패널 attachment + 문 트리거 + 매 프레임 판정 구독
            InteractionSetup.install(content: content, attachments: attachments, appModel: model)

        } update: { _, _ in
            // 미는 정도(속도)에 따라 뒷바퀴 굴림 회전 적용.
            // 기울기/덜컹/흔들림은 휠체어가 아니라 '세계'(System)가 처리한다.
            applyRoll(leftWheel, angle: model.wheelAngleLeft)
            applyRoll(rightWheel, angle: model.wheelAngleRight)
            // 잡힘 하이라이트: 바퀴 메시 발광 틴트 적용/해제.
            setMaterials(leftWheelMesh,
                         (model.leftGrabbed || model.fistDriveActive) ? leftHiMats : leftBaseMats)
            setMaterials(rightWheelMesh,
                         (model.rightGrabbed || model.fistDriveActive) ? rightHiMats : rightBaseMats)
        } attachments: {
            // [김현기] 문 앞 입장 패널(공간 고정 + 빌보드는 InteractionSetup이 처리)
            Attachment(id: "entryPrompt") {
                EntryPromptView()
            }
            // [김현기] 키오스크 주문 화면(고정 높이 장벽은 InteractionSetup이 처리)
            Attachment(id: "kioskScreen") {
                KioskOrderView()
            }
            // 온보딩과 미션 가이드(head lazy-follow는 QuestSetup이 처리)
            Attachment(id: "questHUD") {
                ExperienceGuideView()
            }
            // 점원이 계산대에 도착한 뒤 표시되는 공간 대화 패널.
            Attachment(id: "npcDialogue") {
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
            InteractionModel.shared.endImmersiveSession()
            model.npcClerk.resetForOutdoor()
            handTracker.clearModelInput(model: model)
        }
        .task(id: model.useHandTracking) {
            // 창 토글을 몰입 공간 진입 뒤에 바꿔도 즉시 세션을 시작/종료한다.
            // 새 start 전에 반드시 이전 세대를 먼저 끊어 빠른 OFF→ON도 직렬화한다.
            handTracker.stop(model: model)
            if model.useHandTracking {
                await handTracker.start(model: model)
            }
        }
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

    /// [임시] 엔티티 트리를 이름/타입/위치/크기와 함께 콘솔에 출력.
    private static func dumpHierarchy(_ e: Entity, _ indent: String = "") {
        let b = e.visualBounds(relativeTo: e.parent)
        let p = e.position
        let hasModel = e.components.has(ModelComponent.self) ? " [Model]" : ""
        let name = e.name.isEmpty ? "<no name>" : e.name
        print(String(format: "%@• '%@'%@ pos=(%.3f,%.3f,%.3f) size=(%.3f,%.3f,%.3f)",
                     indent, name, hasModel, p.x, p.y, p.z, b.extents.x, b.extents.y, b.extents.z))
        for c in e.children { dumpHierarchy(c, indent + "    ") }
    }

    // MARK: - USDA 정적 콜리전(베이크용)

    /// 이름에 "collision"이 들어간 엔티티(또는 그 하위)의 메시에만 정적 콜리전을 부여한다.
    /// → 디테일 모델은 시각용, 단순 도형(이름에 collision)은 충돌용으로 분리. 부여 수 반환.
    @discardableResult
    static func addStaticCollision(_ entity: Entity, inherited: Bool = false) async -> Int {
        let isCollider = inherited || entity.name.lowercased().contains("collision")
        var count = 0
        if isCollider,
           let model = entity.components[ModelComponent.self],
           let shape = try? await ShapeResource.generateStaticMesh(from: model.mesh) {
            var col = CollisionComponent(shapes: [shape])
            col.filter = CollisionFilter(group: AppModel.groundGroup, mask: .all)
            entity.components.set(col)
            count += 1
        }
        for child in entity.children {
            count += await addStaticCollision(child, inherited: isCollider)
        }
        return count
    }

    /// USDA에 딸려온 물리(RigidBody)/콜리전을 제거 — 물리·충돌은 코드에서만 관리.
    static func stripPhysics(_ entity: Entity) {
        entity.components.remove(PhysicsBodyComponent.self)
        entity.components.remove(PhysicsMotionComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children { stripPhysics(child) }
    }

    /// 시각 인스턴스에서 충돌용(이름에 collision) 도형은 안 보이게 한다(단순 도형이라 흉하므로).
    private static func hideColliders(_ entity: Entity, inherited: Bool = false) {
        let isCollider = inherited || entity.name.lowercased().contains("collision")
        if isCollider, entity.components[ModelComponent.self] != nil {
            entity.components.set(OpacityComponent(opacity: 0))
        }
        for child in entity.children {
            hideColliders(child, inherited: isCollider)
        }
    }

    /// 엔티티와 모든 하위 모델에 접지 그림자를 부여(바닥 그림자).
    private static func addGroundingShadow(_ entity: Entity) {
        entity.components.set(GroundingShadowComponent(castsShadow: true))
        for child in entity.children {
            addGroundingShadow(child)
        }
    }

    // MARK: - 휠체어 본체(앉아 있는 느낌)

    /// 좌석·등받이·프레임·발받침·앞 캐스터·다리를 도형으로 조립.
    /// 사용자가 -Z 방향을 바라보고 앉아 있다고 가정. (+Z=뒤, -Z=앞)
    /// 좌표는 큰 바퀴(y≈0.45)에 맞춰 엉덩이/허벅지 높이를 기준으로 배치.
    private static func makeWheelchairBody() -> Entity {
        let root = Entity()
        root.name = "wheelchairBody"

        // 재질
        let frameMat = SimpleMaterial(color: .init(white: 0.18, alpha: 1), isMetallic: true)
        let seatMat  = SimpleMaterial(color: .init(red: 0.10, green: 0.10, blue: 0.12, alpha: 1), isMetallic: false)
        let legMat   = SimpleMaterial(color: .init(red: 0.20, green: 0.28, blue: 0.45, alpha: 1), isMetallic: false) // 청바지색
        let shoeMat  = SimpleMaterial(color: .init(white: 0.08, alpha: 1), isMetallic: false)
        let tireMat  = SimpleMaterial(color: .init(white: 0.10, alpha: 1), isMetallic: false)

        func box(_ w: Float, _ h: Float, _ d: Float, _ mat: SimpleMaterial, _ pos: SIMD3<Float>) -> ModelEntity {
            let e = ModelEntity(mesh: .generateBox(width: w, height: h, depth: d, cornerRadius: 0.01), materials: [mat])
            e.position = pos
            return e
        }
        func cyl(_ r: Float, _ h: Float, _ mat: SimpleMaterial, _ pos: SIMD3<Float>, axis: SIMD3<Float> = [0,1,0]) -> ModelEntity {
            let e = ModelEntity(mesh: .generateCylinder(height: h, radius: r), materials: [mat])
            e.position = pos
            if axis.x == 1 { e.orientation = simd_quatf(angle: .pi/2, axis: [0,0,1]) }      // 수평(좌우축)
            else if axis.z == 1 { e.orientation = simd_quatf(angle: .pi/2, axis: [1,0,0]) } // 수평(앞뒤축)
            return e
        }

        // 좌석(엉덩이 받침): 큰 바퀴 사이, 약간 아래.
        root.addChild(box(0.46, 0.06, 0.44, seatMat, [0, 0.40, -0.05]))
        // 등받이: 뒤쪽에 세움.
        root.addChild(box(0.46, 0.5, 0.05, seatMat, [0, 0.63, 0.16]))
        // 좌우 아래 프레임 봉
        root.addChild(box(0.04, 0.04, 0.5, frameMat, [-0.30, 0.36, -0.05]))
        root.addChild(box(0.04, 0.04, 0.5, frameMat, [ 0.30, 0.36, -0.05]))

        // 팔걸이(좌우)
        root.addChild(box(0.05, 0.04, 0.34, frameMat, [-0.32, 0.60, -0.06]))
        root.addChild(box(0.05, 0.04, 0.34, frameMat, [ 0.32, 0.60, -0.06]))

        // 앞 프레임(발받침으로 내려가는 봉)
        root.addChild(box(0.04, 0.04, 0.45, frameMat, [-0.18, 0.22, -0.42]))
        root.addChild(box(0.04, 0.04, 0.45, frameMat, [ 0.18, 0.22, -0.42]))

        // 발받침판
        root.addChild(box(0.34, 0.03, 0.18, frameMat, [0, 0.07, -0.58]))

        // 앞 캐스터(작은 바퀴) 2개
        root.addChild(cyl(0.07, 0.04, tireMat, [-0.18, 0.07, -0.55], axis: [1,0,0]))
        root.addChild(cyl(0.07, 0.04, tireMat, [ 0.18, 0.07, -0.55], axis: [1,0,0]))

        // 다리(허벅지 → 정강이 → 발). 좌우 두 개.
        for side: Float in [-1, 1] {
            let x = side * 0.13
            // 허벅지: 엉덩이(z -0.1)에서 무릎(z -0.45)으로, 거의 수평.
            let thigh = cyl(0.07, 0.38, legMat, [x, 0.41, -0.28], axis: [0,0,1])
            root.addChild(thigh)
            // 정강이: 무릎에서 발목으로 내려감(수직에 가깝게).
            let shin = cyl(0.06, 0.34, legMat, [x, 0.24, -0.50])
            root.addChild(shin)
            // 발(신발)
            root.addChild(box(0.11, 0.06, 0.22, shoeMat, [x, 0.10, -0.56]))
        }

        return root
    }

    /// 바퀴 메시 생성. 타이어(검정) + 대비되는 스포크(살)로 회전이 눈에 보이게.
    /// 부모(타이어)를 회전시키면 자식 스포크도 함께 돌아 굴러가는 느낌을 준다.
    private static func makeWheel() -> ModelEntity {
        let radius: Float = AppModel.wheelRadius

        // 타이어 본체
        let tire = ModelEntity(
            mesh: .generateCylinder(height: 0.08, radius: radius),
            materials: [SimpleMaterial(color: .init(white: 0.12, alpha: 1), isMetallic: false)]
        )

        // 스포크 4개(국부 XZ 평면에 십자로). 한 쌍은 빨강, 다른 한 쌍은 흰색 → 회전 식별.
        let spokeLen: Float = radius * 1.9
        func spoke(color: UIColor, rotated: Bool) -> ModelEntity {
            let s = ModelEntity(
                mesh: .generateBox(width: rotated ? 0.03 : spokeLen,
                                   height: 0.09,
                                   depth: rotated ? spokeLen : 0.03),
                materials: [SimpleMaterial(color: color, isMetallic: false)]
            )
            return s
        }
        tire.addChild(spoke(color: .systemRed, rotated: false))   // 가로 살(빨강)
        tire.addChild(spoke(color: .white, rotated: true))        // 세로 살(흰색)

        // 허브(가운데 노랑)
        let hub = ModelEntity(
            mesh: .generateCylinder(height: 0.1, radius: radius * 0.18),
            materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)]
        )
        tire.addChild(hub)

        // 원기둥은 기본축이 Y. Z축으로 90도 돌려 바퀴처럼 세운다.
        tire.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        tire.generateCollisionShapes(recursive: false)
        return tire
    }

}
