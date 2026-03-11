struct SidebarInitialFocusPolicy {
    private var didEvaluateInitialSelection = false

    mutating func consumeFocusRequest(for selection: SidebarItem?) -> Bool {
        guard !didEvaluateInitialSelection else { return false }
        didEvaluateInitialSelection = true

        guard case .vm = selection else { return false }
        return true
    }
}
