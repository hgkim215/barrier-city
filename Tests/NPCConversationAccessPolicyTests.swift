import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

@main
@MainActor
struct NPCConversationAccessPolicyTests {
    static func main() {
        let orderSession = CafeOrderSession()
        let generation = orderSession.beginIndoorSession()
        var guide = GuideFlowState(phase: .missionActive(index: 2))

        expect(
            NPCConversationAccessPolicy.canOfferTalk(
                clerkPhaseAllowsConversation: true,
                isPlayerNear: true,
                guideAllowsConversation: guide.allowsNPCConversation,
                isDialogueBusy: false,
                isReadyAnnouncementBlocking: false),
            "mission three offers the in-world order conversation")
        expect(guide.allowsNPCOrderConversation, "mission three permits the first order")
        expect(orderSession.acceptOrder() == generation, "mission order is accepted once")

        guide.send(.questAdvanced(nextIndex: 3))
        expect(guide.phase == .missionAnnouncement(index: 3), "accepted order advances to mission 4 announcement")
        guide.send(.confirmMission)
        expect(guide.phase == .missionActive(index: 3), "confirmed mission 4 is active")
        expect(
            NPCConversationAccessPolicy.canOfferTalk(
                clerkPhaseAllowsConversation: true,
                isPlayerNear: true,
                guideAllowsConversation: guide.allowsNPCConversation,
                isDialogueBusy: false,
                isReadyAnnouncementBlocking: false),
            "preparing follow-up remains reachable through the in-world clerk")
        expect(
            NPCConversationAccessPolicy.canBeginGreeting(
                clerkPhaseAllowsConversation: true,
                guideAllowsConversation: guide.allowsNPCConversation),
            "preparing follow-up may begin a greeting")
        expect(!guide.allowsNPCOrderConversation, "post-order guide state cannot place another order")
        expect(orderSession.acceptOrder() == nil, "shared session rejects a duplicate preparing order")

        expect(orderSession.markReady(generation: generation), "current preparation becomes ready")
        expect(
            NPCConversationAccessPolicy.canOfferTalk(
                clerkPhaseAllowsConversation: true,
                isPlayerNear: true,
                guideAllowsConversation: guide.allowsNPCConversation,
                isDialogueBusy: false,
                isReadyAnnouncementBlocking: false),
            "ready follow-up remains reachable through the in-world clerk")
        expect(orderSession.acceptOrder() == nil, "shared session rejects a duplicate ready order")

        for phase in [
            GuidePhase.introduction,
            .tutorial(index: 0),
            .missionAnnouncement(index: 2),
            .missionActive(index: 0),
            .missionActive(index: 1),
            .completionAnnouncement,
            .completed,
        ] {
            let unrelated = GuideFlowState(phase: phase)
            expect(!unrelated.allowsNPCConversation, "unrelated guide phase remains conversation-locked")
            expect(
                !NPCConversationAccessPolicy.canOfferTalk(
                    clerkPhaseAllowsConversation: true,
                    isPlayerNear: true,
                    guideAllowsConversation: unrelated.allowsNPCConversation,
                    isDialogueBusy: false,
                    isReadyAnnouncementBlocking: false),
                "clerk policy respects unrelated guide locks")
        }

        expect(
            !NPCConversationAccessPolicy.canOfferTalk(
                clerkPhaseAllowsConversation: true,
                isPlayerNear: true,
                guideAllowsConversation: true,
                isDialogueBusy: true,
                isReadyAnnouncementBlocking: false),
            "busy dialogue still blocks a new follow-up")
        expect(
            !NPCConversationAccessPolicy.canOfferTalk(
                clerkPhaseAllowsConversation: true,
                isPlayerNear: true,
                guideAllowsConversation: true,
                isDialogueBusy: false,
                isReadyAnnouncementBlocking: true),
            "ready announcement still owns the voice channel")

        print("PASS: NPCConversationAccessPolicyTests")
    }
}
