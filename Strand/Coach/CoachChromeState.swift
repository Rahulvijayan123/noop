import Foundation
import Combine

/// Coach chrome that lives outside the chat itself: whether the chats drawer is open. Injected into
/// `RootTabView` (which stops the tab swipe while the drawer is open) and `CoachChatView` only, so opening the
/// drawer never invalidates the rest of the app.
final class CoachChromeState: ObservableObject {
    @Published var drawerOpen = false

    init(drawerOpen: Bool = false) { self.drawerOpen = drawerOpen }
}
