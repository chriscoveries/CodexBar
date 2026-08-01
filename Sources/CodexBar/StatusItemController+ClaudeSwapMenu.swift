import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeSwapMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let accounts = self.store.claudeSwapAccountSnapshots
        let plan = AccountMenuLayoutPlanner.plan(
            accounts: accounts,
            expandedAccountIDs: self.claudeSwapExpandedAccountIDs,
            healthyTailExpanded: self.claudeSwapHealthyTailExpanded)
        guard plan.usesCompactLayout else {
            self.addStackedClaudeSwapMenuCards(accounts: accounts, to: menu, captureMenu: captureMenu, context: context)
            return
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let progressColor = UsageMenuCardView.Model.progressColor(for: .claude)
        var previousRowWasCard = false
        for (index, row) in plan.rows.enumerated() {
            switch row {
            case let .card(accountID):
                guard let account = accountsByID[accountID],
                      let model = self.claudeSwapCardModel(for: account) else { continue }
                if index > 0 {
                    menu.addItem(.separator())
                }
                let collapseClick: (() -> Void)? = account.isActive ? nil : { [weak self, weak captureMenu] in
                    self?.toggleClaudeSwapAccountExpansion(accountID, menu: captureMenu)
                }
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(
                        model: model,
                        width: context.menuWidth,
                        planAction: self.claudeSwapAccountSwitchAction(account, menu: captureMenu)),
                    id: "claudeSwapCard-\(accountID.opaqueID)",
                    width: context.menuWidth,
                    heightCacheScope: "claude-swap-card-\(accountID.opaqueID)",
                    heightCacheFingerprint: model.heightFingerprint(section: "card"),
                    containsInteractiveControls: true,
                    onClick: collapseClick))
                previousRowWasCard = true
            case let .compact(compactRow):
                if previousRowWasCard {
                    menu.addItem(.separator())
                }
                let rowModel = MenuCardCompactAccountRowView.Model(
                    label: PersonalInfoRedactor.redactEmail(
                        compactRow.label,
                        isEnabled: self.settings.hidePersonalInfo),
                    headroomPercent: compactRow.headroomPercent,
                    severity: compactRow.severity,
                    constraintDetail: compactRow.constraintDetail,
                    hasError: compactRow.hasError,
                    showsBestBadge: compactRow.isBestCandidate)
                let accountID = compactRow.accountID
                menu.addItem(self.makeMenuCardItem(
                    MenuCardCompactAccountRowView(
                        model: rowModel,
                        progressColor: progressColor,
                        width: context.menuWidth),
                    id: "claudeSwapCompact-\(accountID.opaqueID)",
                    width: context.menuWidth,
                    heightCacheScope: "claude-swap-compact-\(accountID.opaqueID)",
                    heightCacheFingerprint: rowModel.heightFingerprint,
                    onClick: { [weak self, weak captureMenu] in
                        self?.toggleClaudeSwapAccountExpansion(accountID, menu: captureMenu)
                    }))
                previousRowWasCard = false
            case let .collapsedHealthy(count):
                let view = MenuCardCollapsedAccountsRowView(count: count, width: context.menuWidth)
                menu.addItem(self.makeMenuCardItem(
                    view,
                    id: "claudeSwapCollapsed",
                    width: context.menuWidth,
                    heightCacheScope: "claude-swap-collapsed",
                    heightCacheFingerprint: "collapsed-\(count)",
                    onClick: { [weak self, weak captureMenu] in
                        self?.expandClaudeSwapHealthyTail(menu: captureMenu)
                    }))
                previousRowWasCard = false
            }
        }
        if !plan.rows.isEmpty {
            menu.addItem(.separator())
        }
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
    }

    private func addStackedClaudeSwapMenuCards(
        accounts: [ProviderAccountUsageSnapshot],
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let cardRows = accounts.compactMap { account ->
            (account: ProviderAccountUsageSnapshot, model: UsageMenuCardView.Model)? in
            guard let model = self.claudeSwapCardModel(for: account) else { return nil }
            return (account, model)
        }
        self.addStackedMenuCards(
            cardRows.map(\.model),
            to: menu,
            context: context,
            planAction: { [weak self] index in
                guard cardRows.indices.contains(index) else { return nil }
                return self?.claudeSwapAccountSwitchAction(cardRows[index].account, menu: captureMenu)
            })
    }

    private func claudeSwapCardModel(for account: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        self.menuCardModel(
            for: .claude,
            snapshotOverride: account.snapshot,
            errorOverride: ClaudeSwapAccountProjection.displayError(
                accountError: account.error,
                adapterError: self.store.claudeSwapLastError,
                switchError: self.store.claudeSwapTransientState.lastErrorAccountID == account.id
                    ? self.store.claudeSwapTransientState.lastError
                    : nil),
            forceOverrideCard: account.snapshot == nil,
            accountOverride: AccountInfo(
                email: account.displayLabel,
                plan: nil),
            planOverride: self.claudeSwapAccountActionLabel(account))
    }

    private func toggleClaudeSwapAccountExpansion(_ accountID: ProviderAccountIdentity, menu: NSMenu?) {
        self.advanceMenuInteraction(for: menu)
        if self.claudeSwapExpandedAccountIDs.contains(accountID) {
            self.claudeSwapExpandedAccountIDs.remove(accountID)
        } else {
            self.claudeSwapExpandedAccountIDs.insert(accountID)
        }
        self.invalidateMenus(refreshOpenMenus: true)
    }

    private func expandClaudeSwapHealthyTail(menu: NSMenu?) {
        self.advanceMenuInteraction(for: menu)
        self.claudeSwapHealthyTailExpanded = true
        self.invalidateMenus(refreshOpenMenus: true)
    }

    /// Compact-layout expansion is per-open transient UI state; reset when the last menu closes.
    func resetClaudeSwapMenuExpansionStateIfIdle() {
        guard self.openMenus.isEmpty else { return }
        self.claudeSwapExpandedAccountIDs.removeAll()
        self.claudeSwapHealthyTailExpanded = false
    }

    private func claudeSwapAccountActionLabel(_ account: ProviderAccountUsageSnapshot) -> String? {
        if account.isActive {
            return L("Active")
        }
        if self.store.claudeSwapTransientState.switchingAccountID == account.id {
            return L("Loading…")
        }
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        return L("Switch Account...")
    }

    private func claudeSwapAccountSwitchAction(
        _ account: ProviderAccountUsageSnapshot,
        menu: NSMenu)
        -> (() -> Void)?
    {
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        let accountID = account.id
        return { [weak self, weak menu] in
            guard let self else { return }
            self.advanceMenuInteraction(for: menu)
            self.store.switchClaudeSwapAccount(accountID)
        }
    }
}
