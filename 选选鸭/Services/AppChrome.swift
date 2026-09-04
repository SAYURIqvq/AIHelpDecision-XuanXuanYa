import Foundation
import SwiftUI

@MainActor
final class AppChrome: ObservableObject {
    enum Tab: Int, Hashable {
        case chat = 0
        case call = 1
        case grain = 2
        case profile = 3
    }

    enum RechargeSegment: Int, Hashable {
        case packs = 0
        case monthCards = 1
        case ledger = 2
    }

    @Published var selectedTab: Tab = .chat
    @Published var rechargeSegment: RechargeSegment = .packs
    @Published var showGrainExhaustSheet = false
    @Published var showPurchaseSuccess = false
    @Published var purchaseSuccessMessage = "🦆鸭鸭吃饱啦！谷粒已到账"

    func openMonthCards() {
        rechargeSegment = .monthCards
        selectedTab = .grain
        showGrainExhaustSheet = false
    }

    func openPacks() {
        rechargeSegment = .packs
        selectedTab = .grain
        showGrainExhaustSheet = false
    }

    func presentExhausted() {
        showGrainExhaustSheet = true
    }

    func celebratePurchase(_ message: String = "🦆鸭鸭吃饱啦！谷粒已到账") {
        purchaseSuccessMessage = message
        showPurchaseSuccess = true
    }
}
