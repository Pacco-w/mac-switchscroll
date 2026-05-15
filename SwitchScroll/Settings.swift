import Foundation

final class Settings {
    static let shared = Settings()

    private enum Key: String {
        case enableSmoothScroll
        case reverseScrollDirection
        case enableWindowSwitcher
        case enableWindowThumbnails
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enableSmoothScroll.rawValue: false,
            Key.reverseScrollDirection.rawValue: false,
            Key.enableWindowSwitcher.rawValue: true,
            Key.enableWindowThumbnails.rawValue: true
        ])
    }

    var enableSmoothScroll: Bool {
        get { defaults.bool(forKey: Key.enableSmoothScroll.rawValue) }
        set { defaults.set(newValue, forKey: Key.enableSmoothScroll.rawValue) }
    }

    var reverseScrollDirection: Bool {
        get { defaults.bool(forKey: Key.reverseScrollDirection.rawValue) }
        set { defaults.set(newValue, forKey: Key.reverseScrollDirection.rawValue) }
    }

    var enableWindowSwitcher: Bool {
        get { defaults.bool(forKey: Key.enableWindowSwitcher.rawValue) }
        set { defaults.set(newValue, forKey: Key.enableWindowSwitcher.rawValue) }
    }

    var enableWindowThumbnails: Bool {
        get { defaults.bool(forKey: Key.enableWindowThumbnails.rawValue) }
        set { defaults.set(newValue, forKey: Key.enableWindowThumbnails.rawValue) }
    }
}
