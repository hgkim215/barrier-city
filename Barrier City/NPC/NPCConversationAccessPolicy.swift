enum NPCConversationAccessPolicy {
    static func canOfferTalk(
        clerkPhaseAllowsConversation: Bool,
        isPlayerNear: Bool,
        guideAllowsConversation: Bool,
        isDialogueBusy: Bool,
        isReadyAnnouncementBlocking: Bool
    ) -> Bool {
        clerkPhaseAllowsConversation
            && isPlayerNear
            && guideAllowsConversation
            && !isDialogueBusy
            && !isReadyAnnouncementBlocking
    }

    static func canBeginGreeting(
        clerkPhaseAllowsConversation: Bool,
        guideAllowsConversation: Bool
    ) -> Bool {
        clerkPhaseAllowsConversation && guideAllowsConversation
    }
}
