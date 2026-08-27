// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
internal enum L10n {
  internal enum About {
    /// Copyright © 2026 by Vladimír Slavík, AI Archeology
    internal static let copyright = L10n.tr("Localizable", "about.copyright", fallback: "Copyright © 2026 by Vladimír Slavík, AI Archeology")
    /// Privacy Policy not available. Missing in the bundle?
    internal static let privacyNotAvailable = L10n.tr("Localizable", "about.privacyNotAvailable", fallback: "Privacy Policy not available. Missing in the bundle?")
    /// Privacy Policy
    internal static let privacyPolicy = L10n.tr("Localizable", "about.privacyPolicy", fallback: "Privacy Policy")
    /// Version
    internal static let version = L10n.tr("Localizable", "about.version", fallback: "Version")
    internal enum Section {
      /// Application
      internal static let application = L10n.tr("Localizable", "about.section.application", fallback: "Application")
      /// Contact
      internal static let contact = L10n.tr("Localizable", "about.section.contact", fallback: "Contact")
      /// Privacy
      internal static let privacy = L10n.tr("Localizable", "about.section.privacy", fallback: "Privacy")
    }
  }
  internal enum Action {
    /// Tap
    internal static let tapOrClick = L10n.tr("Localizable", "action.tap_or_click", fallback: "Tap")
  }
  internal enum Adjustment {
    /// Brightness
    internal static let brightness = L10n.tr("Localizable", "adjustment.brightness", fallback: "Brightness")
    /// Content Preview
    internal static let contentPreview = L10n.tr("Localizable", "adjustment.contentPreview", fallback: "Content Preview")
    /// Contrast
    internal static let contrast = L10n.tr("Localizable", "adjustment.contrast", fallback: "Contrast")
    /// Tap outside panel to dismiss
    internal static let dismissHint = L10n.tr("Localizable", "adjustment.dismissHint", fallback: "Tap outside panel to dismiss")
    /// Saturation
    internal static let saturation = L10n.tr("Localizable", "adjustment.saturation", fallback: "Saturation")
    /// Adjustments
    internal static let title = L10n.tr("Localizable", "adjustment.title", fallback: "Adjustments")
  }
  internal enum Alert {
    internal enum Error {
      /// Error
      internal static let title = L10n.tr("Localizable", "alert.error.title", fallback: "Error")
      /// An unexpected error occurred.
      internal static let unexpected = L10n.tr("Localizable", "alert.error.unexpected", fallback: "An unexpected error occurred.")
    }
    internal enum History {
      internal enum Clear {
        /// Clear the browsing history?
        internal static let message = L10n.tr("Localizable", "alert.history.clear.message", fallback: "Clear the browsing history?")
      }
      internal enum Full {
        /// Browsing history is full. Increase the web browsing history size in Settings, or delete some existing entries from the history.
        internal static let message = L10n.tr("Localizable", "alert.history.full.message", fallback: "Browsing history is full. Increase the web browsing history size in Settings, or delete some existing entries from the history.")
      }
    }
    internal enum Restore {
      /// Resetting the application will erase all data models from the ML Browser except the demo models. Are you sure you want to proceed?
      internal static let message = L10n.tr("Localizable", "alert.restore.message", fallback: "Resetting the application will erase all data models from the ML Browser except the demo models. Are you sure you want to proceed?")
    }
    internal enum Warning {
      /// Warning
      internal static let title = L10n.tr("Localizable", "alert.warning.title", fallback: "Warning")
    }
  }
  internal enum Analytics {
    internal enum Choice {
      /// Enable analytics
      internal static let enable = L10n.tr("Localizable", "analytics.choice.enable", fallback: "Enable analytics")
      /// Share basic usage statistics to help improve the app. When you're signed in, they're linked to your account, so your usage is counted once across all your devices. Analytics is off unless you enable it, and you can change this at any time.
      internal static let message = L10n.tr("Localizable", "analytics.choice.message", fallback: "Share basic usage statistics to help improve the app. When you're signed in, they're linked to your account, so your usage is counted once across all your devices. Analytics is off unless you enable it, and you can change this at any time.")
      /// Not now
      internal static let notNow = L10n.tr("Localizable", "analytics.choice.notNow", fallback: "Not now")
      /// Help improve ML Browser
      internal static let title = L10n.tr("Localizable", "analytics.choice.title", fallback: "Help improve ML Browser")
    }
    internal enum Settings {
      /// Analytics is off by default. You can change this at any time. When you're signed in, usage statistics are linked to your account, so your usage is counted once across all your devices. Page content, images, URLs, titles, filenames, detection results, and model names are never sent.
      internal static let footer = L10n.tr("Localizable", "analytics.settings.footer", fallback: "Analytics is off by default. You can change this at any time. When you're signed in, usage statistics are linked to your account, so your usage is counted once across all your devices. Page content, images, URLs, titles, filenames, detection results, and model names are never sent.")
      /// Share usage data
      internal static let toggle = L10n.tr("Localizable", "analytics.settings.toggle", fallback: "Share usage data")
    }
  }
  internal enum Auth {
    /// Sign Out
    internal static let signOut = L10n.tr("Localizable", "auth.signOut", fallback: "Sign Out")
    internal enum Account {
      /// Deleting your account does not cancel your subscription. Cancel it in the App Store.
      internal static let deleteBillingNote = L10n.tr("Localizable", "auth.account.deleteBillingNote", fallback: "Deleting your account does not cancel your subscription. Cancel it in the App Store.")
      /// Permanently delete your account and all associated data. This cannot be undone.
      internal static let deleteFooter = L10n.tr("Localizable", "auth.account.deleteFooter", fallback: "Permanently delete your account and all associated data. This cannot be undone.")
      /// Free Beta
      internal static let freeBeta = L10n.tr("Localizable", "auth.account.freeBeta", fallback: "Free Beta")
      /// Manage Account
      internal static let manage = L10n.tr("Localizable", "auth.account.manage", fallback: "Manage Account")
      /// Subscription
      internal static let subscription = L10n.tr("Localizable", "auth.account.subscription", fallback: "Subscription")
      /// Account
      internal static let title = L10n.tr("Localizable", "auth.account.title", fallback: "Account")
      internal enum Delete {
        /// Delete Account
        internal static let action = L10n.tr("Localizable", "auth.account.delete.action", fallback: "Delete Account")
        /// This permanently deletes your account and cannot be undone. If you have a subscription, this does not cancel it — cancel it in the App Store.
        internal static let messageBilling = L10n.tr("Localizable", "auth.account.delete.messageBilling", fallback: "This permanently deletes your account and cannot be undone. If you have a subscription, this does not cancel it — cancel it in the App Store.")
        /// Delete Account?
        internal static let title = L10n.tr("Localizable", "auth.account.delete.title", fallback: "Delete Account?")
      }
    }
    internal enum Environment {
      /// Development
      internal static let development = L10n.tr("Localizable", "auth.environment.development", fallback: "Development")
      /// Test builds only. Switching signs you out and reconnects to the selected Clerk instance.
      internal static let footer = L10n.tr("Localizable", "auth.environment.footer", fallback: "Test builds only. Switching signs you out and reconnects to the selected Clerk instance.")
      /// Production
      internal static let production = L10n.tr("Localizable", "auth.environment.production", fallback: "Production")
      /// Clerk Environment
      internal static let title = L10n.tr("Localizable", "auth.environment.title", fallback: "Clerk Environment")
    }
    internal enum Locked {
      /// Your account isn't enabled for access yet. ML Browser is in early access — hang tight, or sign out to switch accounts.
      internal static let message = L10n.tr("Localizable", "auth.locked.message", fallback: "Your account isn't enabled for access yet. ML Browser is in early access — hang tight, or sign out to switch accounts.")
      /// Access pending
      internal static let title = L10n.tr("Localizable", "auth.locked.title", fallback: "Access pending")
    }
    internal enum Offline {
      /// No connection
      internal static let title = L10n.tr("Localizable", "auth.offline.title", fallback: "No connection")
    }
    internal enum SignIn {
      /// Sign In
      internal static let button = L10n.tr("Localizable", "auth.signIn.button", fallback: "Sign In")
      /// Sign in to your ML Browser account.
      internal static let subtitle = L10n.tr("Localizable", "auth.signIn.subtitle", fallback: "Sign in to your ML Browser account.")
      /// Welcome to ML Browser
      internal static let title = L10n.tr("Localizable", "auth.signIn.title", fallback: "Welcome to ML Browser")
    }
  }
  internal enum Browser {
    internal enum FloatingButton {
      /// Show or hide browser controls
      internal static let label = L10n.tr("Localizable", "browser.floatingButton.label", fallback: "Show or hide browser controls")
    }
    internal enum Load {
      /// Try Again
      internal static let retry = L10n.tr("Localizable", "browser.load.retry", fallback: "Try Again")
      internal enum Error {
        /// The page couldn’t be reached. Check your connection and try again.
        internal static let message = L10n.tr("Localizable", "browser.load.error.message", fallback: "The page couldn’t be reached. Check your connection and try again.")
        /// Page didn’t load
        internal static let title = L10n.tr("Localizable", "browser.load.error.title", fallback: "Page didn’t load")
      }
    }
    internal enum Location {
      /// Data
      internal static let data = L10n.tr("Localizable", "browser.location.data", fallback: "Data")
      /// Full URLs
      internal static let fullUrls = L10n.tr("Localizable", "browser.location.fullUrls", fallback: "Full URLs")
      /// Open
      internal static let `open` = L10n.tr("Localizable", "browser.location.open", fallback: "Open")
      /// Search or enter website name
      internal static let placeholder = L10n.tr("Localizable", "browser.location.placeholder", fallback: "Search or enter website name")
      /// Set as Home Page
      internal static let setHomePage = L10n.tr("Localizable", "browser.location.setHomePage", fallback: "Set as Home Page")
      /// Page Address
      internal static let title = L10n.tr("Localizable", "browser.location.title", fallback: "Page Address")
      /// All visits
      internal static let trail = L10n.tr("Localizable", "browser.location.trail", fallback: "All visits")
      /// %lld×
      internal static func visitCount(_ p1: Int) -> String {
        return L10n.tr("Localizable", "browser.location.visitCount", p1, fallback: "%lld×")
      }
      internal enum DataSheet {
        /// Delete Cookies
        internal static let deleteCookies = L10n.tr("Localizable", "browser.location.dataSheet.deleteCookies", fallback: "Delete Cookies")
        /// Removes cookies, caches and other data stored by this website. Its pages may sign you out.
        internal static let description = L10n.tr("Localizable", "browser.location.dataSheet.description", fallback: "Removes cookies, caches and other data stored by this website. Its pages may sign you out.")
        /// Website Data
        internal static let title = L10n.tr("Localizable", "browser.location.dataSheet.title", fallback: "Website Data")
      }
      internal enum DeleteHistory {
        /// Delete the browsing history of this website?
        internal static let confirm = L10n.tr("Localizable", "browser.location.deleteHistory.confirm", fallback: "Delete the browsing history of this website?")
      }
      internal enum Sort {
        /// Alphabetical
        internal static let alphabetical = L10n.tr("Localizable", "browser.location.sort.alphabetical", fallback: "Alphabetical")
        /// Sort order
        internal static let label = L10n.tr("Localizable", "browser.location.sort.label", fallback: "Sort order")
        /// Recent
        internal static let recent = L10n.tr("Localizable", "browser.location.sort.recent", fallback: "Recent")
      }
      internal enum Trail {
        /// No visits recorded yet
        internal static let empty = L10n.tr("Localizable", "browser.location.trail.empty", fallback: "No visits recorded yet")
      }
    }
    internal enum Navigation {
      /// Back
      internal static let back = L10n.tr("Localizable", "browser.navigation.back", fallback: "Back")
      /// Forward
      internal static let forward = L10n.tr("Localizable", "browser.navigation.forward", fallback: "Forward")
      /// Reload
      internal static let reload = L10n.tr("Localizable", "browser.navigation.reload", fallback: "Reload")
      /// Stop
      internal static let stop = L10n.tr("Localizable", "browser.navigation.stop", fallback: "Stop")
    }
  }
  internal enum Catalog {
    /// Downloads
    internal static let downloads = L10n.tr("Localizable", "catalog.downloads", fallback: "Downloads")
    /// Provider
    internal static let provider = L10n.tr("Localizable", "catalog.provider", fallback: "Provider")
    /// Open Catalog
    internal static let title = L10n.tr("Localizable", "catalog.title", fallback: "Open Catalog")
    internal enum Download {
      /// Couldn’t download this model.
      internal static let error = L10n.tr("Localizable", "catalog.download.error", fallback: "Couldn’t download this model.")
      /// Package
      internal static let package = L10n.tr("Localizable", "catalog.download.package", fallback: "Package")
      /// Files: %lld / %lld
      internal static func progress(_ p1: Int, _ p2: Int) -> String {
        return L10n.tr("Localizable", "catalog.download.progress", p1, p2, fallback: "Files: %lld / %lld")
      }
      /// The download timed out. Please try again.
      internal static let timeout = L10n.tr("Localizable", "catalog.download.timeout", fallback: "The download timed out. Please try again.")
      /// Downloading model
      internal static let title = L10n.tr("Localizable", "catalog.download.title", fallback: "Downloading model")
      /// This model is too large to download.
      internal static let tooLarge = L10n.tr("Localizable", "catalog.download.tooLarge", fallback: "This model is too large to download.")
    }
    internal enum Empty {
      /// Search for an object-detection or image-classification model.
      internal static let message = L10n.tr("Localizable", "catalog.empty.message", fallback: "Search for an object-detection or image-classification model.")
      /// Try a different search term.
      internal static let noResultsMessage = L10n.tr("Localizable", "catalog.empty.noResultsMessage", fallback: "Try a different search term.")
      /// No models found
      internal static let noResultsTitle = L10n.tr("Localizable", "catalog.empty.noResultsTitle", fallback: "No models found")
      /// Find a model
      internal static let title = L10n.tr("Localizable", "catalog.empty.title", fallback: "Find a model")
    }
    internal enum Error {
      /// We couldn’t load the catalog. Check your connection and try again.
      internal static let message = L10n.tr("Localizable", "catalog.error.message", fallback: "We couldn’t load the catalog. Check your connection and try again.")
      /// Catalog unavailable
      internal static let title = L10n.tr("Localizable", "catalog.error.title", fallback: "Catalog unavailable")
      /// This result does not include an installable model.
      internal static let unsupportedModel = L10n.tr("Localizable", "catalog.error.unsupportedModel", fallback: "This result does not include an installable model.")
    }
    internal enum Filter {
      /// Clear Filters
      internal static let clear = L10n.tr("Localizable", "catalog.filter.clear", fallback: "Clear Filters")
      /// No models match the selected filters. Clear filters to see more.
      internal static let emptyMessage = L10n.tr("Localizable", "catalog.filter.emptyMessage", fallback: "No models match the selected filters. Clear filters to see more.")
      /// No Matching Models
      internal static let emptyTitle = L10n.tr("Localizable", "catalog.filter.emptyTitle", fallback: "No Matching Models")
      internal enum Family {
        /// Other
        internal static let other = L10n.tr("Localizable", "catalog.filter.family.other", fallback: "Other")
      }
      internal enum Model {
        /// Model
        internal static let title = L10n.tr("Localizable", "catalog.filter.model.title", fallback: "Model")
      }
      internal enum Task {
        /// Classification
        internal static let classification = L10n.tr("Localizable", "catalog.filter.task.classification", fallback: "Classification")
        /// Detection
        internal static let detection = L10n.tr("Localizable", "catalog.filter.task.detection", fallback: "Detection")
        /// Task
        internal static let title = L10n.tr("Localizable", "catalog.filter.task.title", fallback: "Task")
      }
    }
    internal enum Results {
      /// All sources
      internal static let allSources = L10n.tr("Localizable", "catalog.results.allSources", fallback: "All sources")
      /// Core ML
      internal static let coreML = L10n.tr("Localizable", "catalog.results.coreML", fallback: "Core ML")
      /// Downloads: %lld
      internal static func downloads(_ p1: Int) -> String {
        return L10n.tr("Localizable", "catalog.results.downloads", p1, fallback: "Downloads: %lld")
      }
      /// Classification
      internal static let imageClassification = L10n.tr("Localizable", "catalog.results.imageClassification", fallback: "Classification")
      /// Likes: %lld
      internal static func likes(_ p1: Int) -> String {
        return L10n.tr("Localizable", "catalog.results.likes", p1, fallback: "Likes: %lld")
      }
      /// Detection
      internal static let objectDetection = L10n.tr("Localizable", "catalog.results.objectDetection", fallback: "Detection")
      /// ONNX
      internal static let onnx = L10n.tr("Localizable", "catalog.results.onnx", fallback: "ONNX")
      /// Models
      internal static let title = L10n.tr("Localizable", "catalog.results.title", fallback: "Models")
    }
    internal enum Search {
      /// Search models
      internal static let prompt = L10n.tr("Localizable", "catalog.search.prompt", fallback: "Search models")
    }
    internal enum Support {
      /// Convertible
      internal static let convertible = L10n.tr("Localizable", "catalog.support.convertible", fallback: "Convertible")
      /// Generic Labels
      internal static let genericLabels = L10n.tr("Localizable", "catalog.support.genericLabels", fallback: "Generic Labels")
      /// Verified
      internal static let verified = L10n.tr("Localizable", "catalog.support.verified", fallback: "Verified")
    }
  }
  internal enum Clipboard {
    /// Copied: %@
    internal static func copied(_ p1: Any) -> String {
      return L10n.tr("Localizable", "clipboard.copied", String(describing: p1), fallback: "Copied: %@")
    }
  }
  internal enum Common {
    /// Cancel
    internal static let cancel = L10n.tr("Localizable", "common.cancel", fallback: "Cancel")
    /// Clear
    internal static let clear = L10n.tr("Localizable", "common.clear", fallback: "Clear")
    /// Copy
    internal static let copy = L10n.tr("Localizable", "common.copy", fallback: "Copy")
    /// Delete
    internal static let delete = L10n.tr("Localizable", "common.delete", fallback: "Delete")
    /// Dismiss
    internal static let dismiss = L10n.tr("Localizable", "common.dismiss", fallback: "Dismiss")
    /// Done
    internal static let done = L10n.tr("Localizable", "common.done", fallback: "Done")
    /// Edit
    internal static let edit = L10n.tr("Localizable", "common.edit", fallback: "Edit")
    /// Import
    internal static let `import` = L10n.tr("Localizable", "common.import", fallback: "Import")
    /// Imported
    internal static let imported = L10n.tr("Localizable", "common.imported", fallback: "Imported")
    /// Loading...
    internal static let loading = L10n.tr("Localizable", "common.loading", fallback: "Loading...")
    /// OK
    internal static let ok = L10n.tr("Localizable", "common.ok", fallback: "OK")
    /// Reset
    internal static let reset = L10n.tr("Localizable", "common.reset", fallback: "Reset")
    /// Share
    internal static let share = L10n.tr("Localizable", "common.share", fallback: "Share")
  }
  internal enum Configuration {
    /// Author
    internal static let author = L10n.tr("Localizable", "configuration.author", fallback: "Author")
    /// Catalog
    internal static let catalog = L10n.tr("Localizable", "configuration.catalog", fallback: "Catalog")
    /// Color
    internal static let color = L10n.tr("Localizable", "configuration.color", fallback: "Color")
    /// Conversion Log
    internal static let conversionLog = L10n.tr("Localizable", "configuration.conversionLog", fallback: "Conversion Log")
    /// Created
    internal static let created = L10n.tr("Localizable", "configuration.created", fallback: "Created")
    /// Description
    internal static let description = L10n.tr("Localizable", "configuration.description", fallback: "Description")
    /// Detection Confidence
    internal static let detectionConfidence = L10n.tr("Localizable", "configuration.detectionConfidence", fallback: "Detection Confidence")
    /// Export
    internal static let export = L10n.tr("Localizable", "configuration.export", fallback: "Export")
    /// Fade Out Time
    internal static let fadeOutTime = L10n.tr("Localizable", "configuration.fadeOutTime", fallback: "Fade Out Time")
    /// File
    internal static let file = L10n.tr("Localizable", "configuration.file", fallback: "File")
    /// Flash when object found
    internal static let flashOnFinding = L10n.tr("Localizable", "configuration.flashOnFinding", fallback: "Flash when object found")
    /// Flash border size
    internal static let flashSize = L10n.tr("Localizable", "configuration.flashSize", fallback: "Flash border size")
    /// Hardware Acceleration
    internal static let hardwareAcceleration = L10n.tr("Localizable", "configuration.hardwareAcceleration", fallback: "Hardware Acceleration")
    /// Automatic
    internal static let hardwareAccelerationAutomatic = L10n.tr("Localizable", "configuration.hardwareAccelerationAutomatic", fallback: "Automatic")
    /// Lets the system pick the best available hardware for each part of the model. The right choice for almost everyone. Which hardware is used can vary by device, so results may differ very slightly between devices.
    internal static let hardwareAccelerationAutomaticDescription = L10n.tr("Localizable", "configuration.hardwareAccelerationAutomaticDescription", fallback: "Lets the system pick the best available hardware for each part of the model. The right choice for almost everyone. Which hardware is used can vary by device, so results may differ very slightly between devices.")
    /// Graphics Processor
    internal static let hardwareAccelerationGraphicsProcessor = L10n.tr("Localizable", "configuration.hardwareAccelerationGraphicsProcessor", fallback: "Graphics Processor")
    /// Uses the graphics processor alongside the main processor and never the Neural Engine. Mainly useful for comparison when a model behaves unexpectedly; it is not automatically faster.
    internal static let hardwareAccelerationGraphicsProcessorDescription = L10n.tr("Localizable", "configuration.hardwareAccelerationGraphicsProcessorDescription", fallback: "Uses the graphics processor alongside the main processor and never the Neural Engine. Mainly useful for comparison when a model behaves unexpectedly; it is not automatically faster.")
    /// Neural Engine
    internal static let hardwareAccelerationNeuralEngine = L10n.tr("Localizable", "configuration.hardwareAccelerationNeuralEngine", fallback: "Neural Engine")
    /// Prefers Apple's Neural Engine, built for machine-learning work and typically the most power-efficient. It calculates in reduced precision, so detections can shift very slightly compared with the processor.
    internal static let hardwareAccelerationNeuralEngineDescription = L10n.tr("Localizable", "configuration.hardwareAccelerationNeuralEngineDescription", fallback: "Prefers Apple's Neural Engine, built for machine-learning work and typically the most power-efficient. It calculates in reduced precision, so detections can shift very slightly compared with the processor.")
    /// Choose the hardware Core ML requests for this model.
    internal static let hardwareAccelerationPickerHint = L10n.tr("Localizable", "configuration.hardwareAccelerationPickerHint", fallback: "Choose the hardware Core ML requests for this model.")
    /// Processor Only
    internal static let hardwareAccelerationProcessorOnly = L10n.tr("Localizable", "configuration.hardwareAccelerationProcessorOnly", fallback: "Processor Only")
    /// Uses only the main processor. Much slower — several seconds per image tile — but the most exact, and identical on every device. Choose this when detections must match a reference result precisely.
    internal static let hardwareAccelerationProcessorOnlyDescription = L10n.tr("Localizable", "configuration.hardwareAccelerationProcessorOnlyDescription", fallback: "Uses only the main processor. Much slower — several seconds per image tile — but the most exact, and identical on every device. Choose this when detections must match a reference result precisely.")
    /// Not available on this device
    internal static let hardwareAccelerationUnavailable = L10n.tr("Localizable", "configuration.hardwareAccelerationUnavailable", fallback: "Not available on this device")
    /// License
    internal static let license = L10n.tr("Localizable", "configuration.license", fallback: "License")
    /// Link
    internal static let link = L10n.tr("Localizable", "configuration.link", fallback: "Link")
    /// Classification
    internal static let modelTypeClassification = L10n.tr("Localizable", "configuration.modelTypeClassification", fallback: "Classification")
    /// Detection
    internal static let modelTypeDetection = L10n.tr("Localizable", "configuration.modelTypeDetection", fallback: "Detection")
    /// Disabled
    internal static let modelTypeDisabled = L10n.tr("Localizable", "configuration.modelTypeDisabled", fallback: "Disabled")
    /// Choose a type to enable this model.
    internal static let modelTypeDisabledHint = L10n.tr("Localizable", "configuration.modelTypeDisabledHint", fallback: "Choose a type to enable this model.")
    /// Pre-selected as our best guess. Confirm it's correct or change it — the app can't verify it, so you're responsible for the choice, and a wrong type can produce incorrect results.
    internal static let modelTypeReviewConfirm = L10n.tr("Localizable", "configuration.modelTypeReviewConfirm", fallback: "Pre-selected as our best guess. Confirm it's correct or change it — the app can't verify it, so you're responsible for the choice, and a wrong type can produce incorrect results.")
    /// This model's type isn't set, so it won't run. Choose Detection or Classification — the app can't verify the model's real type, so you're responsible for the choice, and a wrong type can produce incorrect results.
    internal static let modelTypeReviewDisabled = L10n.tr("Localizable", "configuration.modelTypeReviewDisabled", fallback: "This model's type isn't set, so it won't run. Choose Detection or Classification — the app can't verify the model's real type, so you're responsible for the choice, and a wrong type can produce incorrect results.")
    /// Sound
    internal static let sound = L10n.tr("Localizable", "configuration.sound", fallback: "Sound")
    /// Bell
    internal static let soundBell = L10n.tr("Localizable", "configuration.soundBell", fallback: "Bell")
    /// Bloom
    internal static let soundBloom = L10n.tr("Localizable", "configuration.soundBloom", fallback: "Bloom")
    /// Chime
    internal static let soundChime = L10n.tr("Localizable", "configuration.soundChime", fallback: "Chime")
    /// Click
    internal static let soundClick = L10n.tr("Localizable", "configuration.soundClick", fallback: "Click")
    /// Croak
    internal static let soundCroak = L10n.tr("Localizable", "configuration.soundCroak", fallback: "Croak")
    /// Drop
    internal static let soundDrop = L10n.tr("Localizable", "configuration.soundDrop", fallback: "Drop")
    /// Echo
    internal static let soundEcho = L10n.tr("Localizable", "configuration.soundEcho", fallback: "Echo")
    /// Play sound for annotations
    internal static let soundEnabled = L10n.tr("Localizable", "configuration.soundEnabled", fallback: "Play sound for annotations")
    /// Your device's media volume is off, so these sounds will not be heard.
    internal static let soundOutputMuted = L10n.tr("Localizable", "configuration.soundOutputMuted", fallback: "Your device's media volume is off, so these sounds will not be heard.")
    /// Detection sounds follow Silent mode. If your device is silenced you will not hear them, not even the previews above.
    internal static let soundOutputNote = L10n.tr("Localizable", "configuration.soundOutputNote", fallback: "Detection sounds follow Silent mode. If your device is silenced you will not hear them, not even the previews above.")
    /// Ping
    internal static let soundPing = L10n.tr("Localizable", "configuration.soundPing", fallback: "Ping")
    /// Pulse
    internal static let soundPulse = L10n.tr("Localizable", "configuration.soundPulse", fallback: "Pulse")
    /// Sonar
    internal static let soundSonar = L10n.tr("Localizable", "configuration.soundSonar", fallback: "Sonar")
    /// Tap
    internal static let soundTap = L10n.tr("Localizable", "configuration.soundTap", fallback: "Tap")
    /// Volume
    internal static let soundVolume = L10n.tr("Localizable", "configuration.soundVolume", fallback: "Volume")
    /// Symbol
    internal static let symbol = L10n.tr("Localizable", "configuration.symbol", fallback: "Symbol")
    /// Configuration
    internal static let title = L10n.tr("Localizable", "configuration.title", fallback: "Configuration")
    /// Type
    internal static let type = L10n.tr("Localizable", "configuration.type", fallback: "Type")
    /// Version
    internal static let version = L10n.tr("Localizable", "configuration.version", fallback: "Version")
    internal enum Provenance {
      /// Converted from %@
      internal static func converted(_ p1: Any) -> String {
        return L10n.tr("Localizable", "configuration.provenance.converted", String(describing: p1), fallback: "Converted from %@")
      }
      /// Core ML
      internal static let coreML = L10n.tr("Localizable", "configuration.provenance.coreML", fallback: "Core ML")
    }
    internal enum Section {
      /// Annotation
      internal static let annotation = L10n.tr("Localizable", "configuration.section.annotation", fallback: "Annotation")
      /// Author
      internal static let author = L10n.tr("Localizable", "configuration.section.author", fallback: "Author")
      /// Model
      internal static let model = L10n.tr("Localizable", "configuration.section.model", fallback: "Model")
    }
  }
  internal enum Download {
    /// Downloaded
    internal static let downloaded = L10n.tr("Localizable", "download.downloaded", fallback: "Downloaded")
    /// Error
    internal static let error = L10n.tr("Localizable", "download.error", fallback: "Error")
    /// Status
    internal static let status = L10n.tr("Localizable", "download.status", fallback: "Status")
    /// Model
    internal static let title = L10n.tr("Localizable", "download.title", fallback: "Model")
    /// URL
    internal static let url = L10n.tr("Localizable", "download.url", fallback: "URL")
    /// Enter a direct .mlmodel or .onnx URL for a detection or classification model. Use Open Catalog for multi-file .mlpackage models.
    internal static let urlHintFormats = L10n.tr("Localizable", "download.urlHintFormats", fallback: "Enter a direct .mlmodel or .onnx URL for a detection or classification model. Use Open Catalog for multi-file .mlpackage models.")
    /// https://.../mymodel.mlmodel
    internal static let urlPlaceholder = L10n.tr("Localizable", "download.urlPlaceholder", fallback: "https://.../mymodel.mlmodel")
    internal enum Button {
      /// Cancel
      internal static let cancel = L10n.tr("Localizable", "download.button.cancel", fallback: "Cancel")
      /// Continue
      internal static let `continue` = L10n.tr("Localizable", "download.button.continue", fallback: "Continue")
      /// Download
      internal static let download = L10n.tr("Localizable", "download.button.download", fallback: "Download")
      /// Pause
      internal static let pause = L10n.tr("Localizable", "download.button.pause", fallback: "Pause")
      /// Restart
      internal static let restart = L10n.tr("Localizable", "download.button.restart", fallback: "Restart")
    }
    internal enum Error {
      /// Download was interrupted and cannot be resumed. Please restart the download.
      internal static let interruptedNoResumeData = L10n.tr("Localizable", "download.error.interruptedNoResumeData", fallback: "Download was interrupted and cannot be resumed. Please restart the download.")
      /// Unable to save the URL. Please try again.
      internal static let persistFailed = L10n.tr("Localizable", "download.error.persistFailed", fallback: "Unable to save the URL. Please try again.")
    }
    internal enum Help {
      /// Help
      internal static let title = L10n.tr("Localizable", "download.help.title", fallback: "Help")
    }
  }
  internal enum DownloadState {
    /// Cancelled
    internal static let cancelled = L10n.tr("Localizable", "downloadState.cancelled", fallback: "Cancelled")
    /// Complete
    internal static let complete = L10n.tr("Localizable", "downloadState.complete", fallback: "Complete")
    /// Downloading
    internal static let downloading = L10n.tr("Localizable", "downloadState.downloading", fallback: "Downloading")
    /// Failed
    internal static let failed = L10n.tr("Localizable", "downloadState.failed", fallback: "Failed")
    /// Imported
    internal static let imported = L10n.tr("Localizable", "downloadState.imported", fallback: "Imported")
    /// Import failed
    internal static let importFailed = L10n.tr("Localizable", "downloadState.importFailed", fallback: "Import failed")
    /// Not started
    internal static let notStarted = L10n.tr("Localizable", "downloadState.notStarted", fallback: "Not started")
    /// Paused
    internal static let paused = L10n.tr("Localizable", "downloadState.paused", fallback: "Paused")
  }
  internal enum Finding {
    /// Author
    internal static let author = L10n.tr("Localizable", "finding.author", fallback: "Author")
    /// Who found it
    internal static let authorPlaceholder = L10n.tr("Localizable", "finding.authorPlaceholder", fallback: "Who found it")
    /// Detection
    internal static let detection = L10n.tr("Localizable", "finding.detection", fallback: "Detection")
    /// GPS
    internal static let gps = L10n.tr("Localizable", "finding.gps", fallback: "GPS")
    /// 48.800000, 19.530000
    internal static let gpsPlaceholder = L10n.tr("Localizable", "finding.gpsPlaceholder", fallback: "48.800000, 19.530000")
    /// Highlight Opacity
    internal static let highlightOpacity = L10n.tr("Localizable", "finding.highlightOpacity", fallback: "Highlight Opacity")
    /// Label
    internal static let label = L10n.tr("Localizable", "finding.label", fallback: "Label")
    /// Add a label (e.g. fortification)
    internal static let labelPlaceholder = L10n.tr("Localizable", "finding.labelPlaceholder", fallback: "Add a label (e.g. fortification)")
    /// Note
    internal static let note = L10n.tr("Localizable", "finding.note", fallback: "Note")
    /// Notes about this finding
    internal static let notePlaceholder = L10n.tr("Localizable", "finding.notePlaceholder", fallback: "Notes about this finding")
    /// Page
    internal static let page = L10n.tr("Localizable", "finding.page", fallback: "Page")
    /// Title
    internal static let title = L10n.tr("Localizable", "finding.title", fallback: "Title")
    /// Name this finding
    internal static let titlePlaceholder = L10n.tr("Localizable", "finding.titlePlaceholder", fallback: "Name this finding")
    /// Zoom
    internal static let zoom = L10n.tr("Localizable", "finding.zoom", fallback: "Zoom")
    internal enum Pick {
      /// Tap the place to store
      internal static let hint = L10n.tr("Localizable", "finding.pick.hint", fallback: "Tap the place to store")
    }
    internal enum Save {
      /// Save
      internal static let action = L10n.tr("Localizable", "finding.save.action", fallback: "Save")
      /// Could not save the finding.
      internal static let error = L10n.tr("Localizable", "finding.save.error", fallback: "Could not save the finding.")
      /// Save Finding
      internal static let title = L10n.tr("Localizable", "finding.save.title", fallback: "Save Finding")
    }
    internal enum Share {
      /// No web address will travel with this link.
      internal static let addressNotIncluded = L10n.tr("Localizable", "finding.share.addressNotIncluded", fallback: "No web address will travel with this link.")
      /// This link carries at most:
      internal static let addressPreview = L10n.tr("Localizable", "finding.share.addressPreview", fallback: "This link carries at most:")
      /// Dark
      internal static let dark = L10n.tr("Localizable", "finding.share.dark", fallback: "Dark")
      /// Share the full web address
      internal static let fullAddress = L10n.tr("Localizable", "finding.share.fullAddress", fallback: "Share the full web address")
      /// Map sites keep the view you are looking at inside the web address. Sharing it in full is what lets someone open that same view; turned off, only the site itself is shared.
      internal static let fullAddressFootnote = L10n.tr("Localizable", "finding.share.fullAddressFootnote", fallback: "Map sites keep the view you are looking at inside the web address. Sharing it in full is what lets someone open that same view; turned off, only the site itself is shared.")
      /// Let people open this finding in the app
      internal static let includeLink = L10n.tr("Localizable", "finding.share.includeLink", fallback: "Let people open this finding in the app")
      /// Adds a tappable link beside the picture, so people can open this finding in the app. While it's on, iOS hides Save Image and any app that only accepts pictures from the share sheet. Turn it off to share just the picture.
      internal static let includeLinkFootnote = L10n.tr("Localizable", "finding.share.includeLinkFootnote", fallback: "Adds a tappable link beside the picture, so people can open this finding in the app. While it's on, iOS hides Save Image and any app that only accepts pictures from the share sheet. Turn it off to share just the picture.")
      /// Landscape
      internal static let landscape = L10n.tr("Localizable", "finding.share.landscape", fallback: "Landscape")
      /// Layout
      internal static let layout = L10n.tr("Localizable", "finding.share.layout", fallback: "Layout")
      /// Light
      internal static let light = L10n.tr("Localizable", "finding.share.light", fallback: "Light")
      /// Portrait
      internal static let portrait = L10n.tr("Localizable", "finding.share.portrait", fallback: "Portrait")
      /// Theme
      internal static let theme = L10n.tr("Localizable", "finding.share.theme", fallback: "Theme")
      /// Share Finding
      internal static let title = L10n.tr("Localizable", "finding.share.title", fallback: "Share Finding")
    }
    internal enum Shared {
      /// Open the Original Page
      internal static let openPage = L10n.tr("Localizable", "finding.shared.openPage", fallback: "Open the Original Page")
      /// Show on Map
      internal static let showOnMap = L10n.tr("Localizable", "finding.shared.showOnMap", fallback: "Show on Map")
      /// Shared Finding
      internal static let title = L10n.tr("Localizable", "finding.shared.title", fallback: "Shared Finding")
      /// Everything on this screen came from the link that was shared with you. None of it has been checked, so treat the details as unconfirmed.
      internal static let unverifiedMessage = L10n.tr("Localizable", "finding.shared.unverifiedMessage", fallback: "Everything on this screen came from the link that was shared with you. None of it has been checked, so treat the details as unconfirmed.")
      /// Shared by Someone Else
      internal static let unverifiedTitle = L10n.tr("Localizable", "finding.shared.unverifiedTitle", fallback: "Shared by Someone Else")
      internal enum Owned {
        /// This link points to a finding already saved on this device, so there is nothing to add.
        internal static let message = L10n.tr("Localizable", "finding.shared.owned.message", fallback: "This link points to a finding already saved on this device, so there is nothing to add.")
        /// Open Findings
        internal static let `open` = L10n.tr("Localizable", "finding.shared.owned.open", fallback: "Open Findings")
        /// This Is Your Finding
        internal static let title = L10n.tr("Localizable", "finding.shared.owned.title", fallback: "This Is Your Finding")
      }
      internal enum Unreadable {
        /// It may have been shortened or edited on its way to you. Ask whoever shared it to send the link again.
        internal static let message = L10n.tr("Localizable", "finding.shared.unreadable.message", fallback: "It may have been shortened or edited on its way to you. Ask whoever shared it to send the link again.")
        /// This Link Could Not Be Read
        internal static let title = L10n.tr("Localizable", "finding.shared.unreadable.title", fallback: "This Link Could Not Be Read")
      }
      internal enum Where {
        /// Detection %1$@ from the left, %2$@ from the top, covering about %3$@ of the page.
        internal static func accessibility(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
          return L10n.tr("Localizable", "finding.shared.where.accessibility", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Detection %1$@ from the left, %2$@ from the top, covering about %3$@ of the page.")
        }
        /// Where on the page
        internal static let title = L10n.tr("Localizable", "finding.shared.where.title", fallback: "Where on the page")
      }
    }
  }
  internal enum Findings {
    /// Export
    internal static let export = L10n.tr("Localizable", "findings.export", fallback: "Export")
    /// Import
    internal static let `import` = L10n.tr("Localizable", "findings.import", fallback: "Import")
    /// Open Page
    internal static let openPage = L10n.tr("Localizable", "findings.openPage", fallback: "Open Page")
    /// Findings
    internal static let title = L10n.tr("Localizable", "findings.title", fallback: "Findings")
    internal enum Empty {
      /// Use the Find button, then tap the place in the web content to store it here.
      internal static let message = L10n.tr("Localizable", "findings.empty.message", fallback: "Use the Find button, then tap the place in the web content to store it here.")
      /// No Findings Yet
      internal static let title = L10n.tr("Localizable", "findings.empty.title", fallback: "No Findings Yet")
    }
    internal enum Export {
      /// Could not export the findings.
      internal static let error = L10n.tr("Localizable", "findings.export.error", fallback: "Could not export the findings.")
    }
    internal enum Filter {
      /// All
      internal static let all = L10n.tr("Localizable", "findings.filter.all", fallback: "All")
    }
    internal enum Import {
      /// That file is not a findings archive.
      internal static let error = L10n.tr("Localizable", "findings.import.error", fallback: "That file is not a findings archive.")
      internal enum Duplicates {
        /// Keep Mine
        internal static let keep = L10n.tr("Localizable", "findings.import.duplicates.keep", fallback: "Keep Mine")
        /// %lld of these findings are already on this device.
        internal static func message(_ p1: Int) -> String {
          return L10n.tr("Localizable", "findings.import.duplicates.message", p1, fallback: "%lld of these findings are already on this device.")
        }
        /// Replace
        internal static let replace = L10n.tr("Localizable", "findings.import.duplicates.replace", fallback: "Replace")
        /// Some findings are already here
        internal static let title = L10n.tr("Localizable", "findings.import.duplicates.title", fallback: "Some findings are already here")
      }
      internal enum Result {
        /// Restored %1$lld. Skipped %2$lld already here. %3$lld could not be read.
        internal static func message(_ p1: Int, _ p2: Int, _ p3: Int) -> String {
          return L10n.tr("Localizable", "findings.import.result.message", p1, p2, p3, fallback: "Restored %1$lld. Skipped %2$lld already here. %3$lld could not be read.")
        }
        /// Import finished
        internal static let title = L10n.tr("Localizable", "findings.import.result.title", fallback: "Import finished")
      }
    }
    internal enum Sync {
      /// %d could not be backed up
      internal static func parked(_ p1: Int) -> String {
        return L10n.tr("Localizable", "findings.sync.parked", p1, fallback: "%d could not be backed up")
      }
      /// %d not backed up yet
      internal static func pending(_ p1: Int) -> String {
        return L10n.tr("Localizable", "findings.sync.pending", p1, fallback: "%d not backed up yet")
      }
      internal enum Backup {
        /// Backing up…
        internal static let busy = L10n.tr("Localizable", "findings.sync.backup.busy", fallback: "Backing up…")
        /// Back Up My Findings
        internal static let button = L10n.tr("Localizable", "findings.sync.backup.button", fallback: "Back Up My Findings")
        /// Back Up
        internal static let confirm = L10n.tr("Localizable", "findings.sync.backup.confirm", fallback: "Back Up")
        /// Back-up didn’t finish. It will try again.
        internal static let failed = L10n.tr("Localizable", "findings.sync.backup.failed", fallback: "Back-up didn’t finish. It will try again.")
        /// Keep on This Device
        internal static let keepOnDevice = L10n.tr("Localizable", "findings.sync.backup.keepOnDevice", fallback: "Keep on This Device")
        /// %d findings on this device are not in this account yet.
        internal static func message(_ p1: Int) -> String {
          return L10n.tr("Localizable", "findings.sync.backup.message", p1, fallback: "%d findings on this device are not in this account yet.")
        }
        /// No connection. Your findings will go up when you’re back online.
        internal static let offline = L10n.tr("Localizable", "findings.sync.backup.offline", fallback: "No connection. Your findings will go up when you’re back online.")
        /// Your findings are backed up.
        internal static let succeeded = L10n.tr("Localizable", "findings.sync.backup.succeeded", fallback: "Your findings are backed up.")
        /// Back up existing findings?
        internal static let title = L10n.tr("Localizable", "findings.sync.backup.title", fallback: "Back up existing findings?")
        /// Back Up My Findings
        internal static let toggle = L10n.tr("Localizable", "findings.sync.backup.toggle", fallback: "Back Up My Findings")
        /// When off, nothing new leaves this device. Findings already backed up stay in your account and are still restored on a new device.
        internal static let toggleFooter = L10n.tr("Localizable", "findings.sync.backup.toggleFooter", fallback: "When off, nothing new leaves this device. Findings already backed up stay in your account and are still restored on a new device.")
      }
      internal enum Storage {
        /// Cloud storage full — delete findings you no longer need, or export them
        internal static let full = L10n.tr("Localizable", "findings.sync.storage.full", fallback: "Cloud storage full — delete findings you no longer need, or export them")
        /// Cloud storage %d%% full
        internal static func warning(_ p1: Int) -> String {
          return L10n.tr("Localizable", "findings.sync.storage.warning", p1, fallback: "Cloud storage %d%% full")
        }
      }
    }
  }
  internal enum History {
    /// Browsing History
    internal static let title = L10n.tr("Localizable", "history.title", fallback: "Browsing History")
    internal enum Clear {
      /// Clear
      internal static let button = L10n.tr("Localizable", "history.clear.button", fallback: "Clear")
      /// Clear Browsing History
      internal static let title = L10n.tr("Localizable", "history.clear.title", fallback: "Clear Browsing History")
    }
    internal enum Section {
      /// History
      internal static let title = L10n.tr("Localizable", "history.section.title", fallback: "History")
    }
  }
  internal enum Import {
    /// Apple Create ML Documentation
    internal static let appleDocumentation = L10n.tr("Localizable", "import.appleDocumentation", fallback: "Apple Create ML Documentation")
    /// This file describes itself as an ADAF %@ detection model. It was converted on this device.
    internal static func checkpointDetectorConverted(_ p1: Any) -> String {
      return L10n.tr("Localizable", "import.checkpointDetectorConverted", String(describing: p1), fallback: "This file describes itself as an ADAF %@ detection model. It was converted on this device.")
    }
    /// This file describes itself as an ADAF detection model. It was converted on this device.
    internal static let checkpointDetectorConvertedUnlabelled = L10n.tr("Localizable", "import.checkpointDetectorConvertedUnlabelled", fallback: "This file describes itself as an ADAF detection model. It was converted on this device.")
    /// This file describes itself as an image segmentation model. This app finds and classifies objects in a scene, so segmentation models are not supported.
    internal static let checkpointSegmentation = L10n.tr("Localizable", "import.checkpointSegmentation", fallback: "This file describes itself as an image segmentation model. This app finds and classifies objects in a scene, so segmentation models are not supported.")
    /// This training checkpoint holds a model this app does not recognise. Only ADAF detection models can be imported.
    internal static let checkpointUnrecognized = L10n.tr("Localizable", "import.checkpointUnrecognized", fallback: "This training checkpoint holds a model this app does not recognise. Only ADAF detection models can be imported.")
    /// Confirm the model type
    internal static let confirmTypeTitle = L10n.tr("Localizable", "import.confirmTypeTitle", fallback: "Confirm the model type")
    /// Conversion Log
    internal static let conversionLog = L10n.tr("Localizable", "import.conversionLog", fallback: "Conversion Log")
    /// Code
    internal static let conversionLogCode = L10n.tr("Localizable", "import.conversionLogCode", fallback: "Code")
    /// Diagnostic
    internal static let conversionLogDiagnostic = L10n.tr("Localizable", "import.conversionLogDiagnostic", fallback: "Diagnostic")
    /// Events
    internal static let conversionLogEvents = L10n.tr("Localizable", "import.conversionLogEvents", fallback: "Events")
    /// Input bytes
    internal static let conversionLogInputBytes = L10n.tr("Localizable", "import.conversionLogInputBytes", fallback: "Input bytes")
    /// Metrics
    internal static let conversionLogMetrics = L10n.tr("Localizable", "import.conversionLogMetrics", fallback: "Metrics")
    /// Operations
    internal static let conversionLogOperations = L10n.tr("Localizable", "import.conversionLogOperations", fallback: "Operations")
    /// Output bytes
    internal static let conversionLogOutputBytes = L10n.tr("Localizable", "import.conversionLogOutputBytes", fallback: "Output bytes")
    /// Phase
    internal static let conversionLogPhase = L10n.tr("Localizable", "import.conversionLogPhase", fallback: "Phase")
    /// Conversion revision
    internal static let conversionLogRevision = L10n.tr("Localizable", "import.conversionLogRevision", fallback: "Conversion revision")
    /// Converter version
    internal static let conversionLogSourceVersion = L10n.tr("Localizable", "import.conversionLogSourceVersion", fallback: "Converter version")
    /// State
    internal static let conversionLogState = L10n.tr("Localizable", "import.conversionLogState", fallback: "State")
    /// Status
    internal static let conversionLogStatus = L10n.tr("Localizable", "import.conversionLogStatus", fallback: "Status")
    /// Observed peak increase
    internal static let conversionObservedPeakIncrease = L10n.tr("Localizable", "import.conversionObservedPeakIncrease", fallback: "Observed peak increase")
    /// Observed peak process memory
    internal static let conversionObservedPeakMemory = L10n.tr("Localizable", "import.conversionObservedPeakMemory", fallback: "Observed peak process memory")
    /// Process memory
    internal static let conversionProcessMemory = L10n.tr("Localizable", "import.conversionProcessMemory", fallback: "Process memory")
    /// Waiting for another conversion to finish
    internal static let conversionWaitingForExclusiveAccess = L10n.tr("Localizable", "import.conversionWaitingForExclusiveAccess", fallback: "Waiting for another conversion to finish")
    /// Convert Only
    internal static let convertOnly = L10n.tr("Localizable", "import.convertOnly", fallback: "Convert Only")
    /// Discard Conversion
    internal static let discardConversion = L10n.tr("Localizable", "import.discardConversion", fallback: "Discard Conversion")
    /// Export Converted Model
    internal static let exportConvertedModel = L10n.tr("Localizable", "import.exportConvertedModel", fallback: "Export Converted Model")
    /// Import from Files
    internal static let fromFiles = L10n.tr("Localizable", "import.fromFiles", fallback: "Import from Files")
    /// Select a .mlmodel or .mlpackage file
    internal static let fromFilesHint = L10n.tr("Localizable", "import.fromFilesHint", fallback: "Select a .mlmodel or .mlpackage file")
    /// Download from URL
    internal static let fromURL = L10n.tr("Localizable", "import.fromURL", fallback: "Download from URL")
    /// Download a model from the internet
    internal static let fromURLHint = L10n.tr("Localizable", "import.fromURLHint", fallback: "Download a model from the internet")
    /// generic class-index labels
    internal static let inferredLabelsGeneric = L10n.tr("Localizable", "import.inferredLabelsGeneric", fallback: "generic class-index labels")
    /// ImageNet-1k labels
    internal static let inferredLabelsImageNet = L10n.tr("Localizable", "import.inferredLabelsImageNet", fallback: "ImageNet-1k labels")
    /// Pascal VOC labels
    internal static let inferredLabelsPascalVoc = L10n.tr("Localizable", "import.inferredLabelsPascalVoc", fallback: "Pascal VOC labels")
    /// preprocessing embedded in the model graph
    internal static let inferredPreprocessingEmbedded = L10n.tr("Localizable", "import.inferredPreprocessingEmbedded", fallback: "preprocessing embedded in the model graph")
    /// ImageNet RGB normalization
    internal static let inferredPreprocessingImageNetRgb = L10n.tr("Localizable", "import.inferredPreprocessingImageNetRgb", fallback: "ImageNet RGB normalization")
    /// no image preprocessing
    internal static let inferredPreprocessingNone = L10n.tr("Localizable", "import.inferredPreprocessingNone", fallback: "no image preprocessing")
    /// RGB pixels scaled to 0–1
    internal static let inferredPreprocessingRgbZeroToOne = L10n.tr("Localizable", "import.inferredPreprocessingRgbZeroToOne", fallback: "RGB pixels scaled to 0–1")
    /// This file has no label metadata. AI Archeology used %1$@ and %2$@. Check a few known images before relying on its results.
    internal static func inferredSemantics(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "import.inferredSemantics", String(describing: p1), String(describing: p2), fallback: "This file has no label metadata. AI Archeology used %1$@ and %2$@. Check a few known images before relying on its results.")
    }
    /// Keep Original
    internal static let keepOriginal = L10n.tr("Localizable", "import.keepOriginal", fallback: "Keep Original")
    /// The converted Core ML model will be used by the app. Do you also want to keep a copy of the original model package for provenance or future conversion?
    internal static let keepOriginalMessage = L10n.tr("Localizable", "import.keepOriginalMessage", fallback: "The converted Core ML model will be used by the app. Do you also want to keep a copy of the original model package for provenance or future conversion?")
    /// Keep Original Model?
    internal static let keepOriginalTitle = L10n.tr("Localizable", "import.keepOriginalTitle", fallback: "Keep Original Model?")
    /// Learn More
    internal static let learnMore = L10n.tr("Localizable", "import.learnMore", fallback: "Learn More")
    /// ONNX Conversion
    internal static let onnxConversion = L10n.tr("Localizable", "import.onnxConversion", fallback: "ONNX Conversion")
    /// Use this Python code to convert ONNX models:
    internal static let onnxConversionHint = L10n.tr("Localizable", "import.onnxConversionHint", fallback: "Use this Python code to convert ONNX models:")
    /// Resume Conversion
    internal static let resumeConversion = L10n.tr("Localizable", "import.resumeConversion", fallback: "Resume Conversion")
    /// A native model conversion did not finish. You can resume it, inspect its path-free conversion log, or discard its staged app-sandbox artifacts.
    internal static let resumeConversionMessage = L10n.tr("Localizable", "import.resumeConversionMessage", fallback: "A native model conversion did not finish. You can resume it, inspect its path-free conversion log, or discard its staged app-sandbox artifacts.")
    /// Resume Conversion?
    internal static let resumeConversionTitle = L10n.tr("Localizable", "import.resumeConversionTitle", fallback: "Resume Conversion?")
    /// Show Conversion Log
    internal static let showConversionLog = L10n.tr("Localizable", "import.showConversionLog", fallback: "Show Conversion Log")
    /// The model has been imported successfully.
    internal static let success = L10n.tr("Localizable", "import.success", fallback: "The model has been imported successfully.")
    /// Model imported
    internal static let successTitle = L10n.tr("Localizable", "import.successTitle", fallback: "Model imported")
    /// The model %1$@ from %2$@ has been successfully imported.
    internal static func successWithInfo(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "import.successWithInfo", String(describing: p1), String(describing: p2), fallback: "The model %1$@ from %2$@ has been successfully imported.")
    }
    /// Supported Models
    internal static let supportedModels = L10n.tr("Localizable", "import.supportedModels", fallback: "Supported Models")
    /// Choose a Core ML model (.mlmodel or .mlpackage) for object detection or image classification. You can also import an ONNX model (.onnx), which the app converts to Core ML on your device — image classifiers and YOLO-family detectors are supported. Other model types are not supported in this version.
    internal static let supportedModelsAndFormats = L10n.tr("Localizable", "import.supportedModelsAndFormats", fallback: "Choose a Core ML model (.mlmodel or .mlpackage) for object detection or image classification. You can also import an ONNX model (.onnx), which the app converts to Core ML on your device — image classifiers and YOLO-family detectors are supported. Other model types are not supported in this version.")
    /// Import Model
    internal static let title = L10n.tr("Localizable", "import.title", fallback: "Import Model")
    /// The model was imported. The app can't verify what an imported model does, so please confirm its type on the next screen. You're responsible for the choice, and a wrong type can produce incorrect results.
    internal static let typeConfirmation = L10n.tr("Localizable", "import.typeConfirmation", fallback: "The model was imported. The app can't verify what an imported model does, so please confirm its type on the next screen. You're responsible for the choice, and a wrong type can produce incorrect results.")
    /// This download is an archive, not a model. Extract it first, then import the model file inside it.
    internal static let unsupportedArchive = L10n.tr("Localizable", "import.unsupportedArchive", fallback: "This download is an archive, not a model. Extract it first, then import the model file inside it.")
    /// This download is a training checkpoint, which this app cannot open yet. Import a Core ML or ONNX model instead.
    internal static let unsupportedCheckpoint = L10n.tr("Localizable", "import.unsupportedCheckpoint", fallback: "This download is a training checkpoint, which this app cannot open yet. Import a Core ML or ONNX model instead.")
    /// Validating model...
    internal static let validating = L10n.tr("Localizable", "import.validating", fallback: "Validating model...")
    /// WWDC: Core ML Converters
    internal static let wwdcCoreML = L10n.tr("Localizable", "import.wwdcCoreML", fallback: "WWDC: Core ML Converters")
  }
  internal enum Items {
    /// %lld items
    internal static func count(_ p1: Int) -> String {
      return L10n.tr("Localizable", "items.count", p1, fallback: "%lld items")
    }
  }
  internal enum Models {
    /// Add Model
    internal static let add = L10n.tr("Localizable", "models.add", fallback: "Add Model")
    /// Models
    internal static let title = L10n.tr("Localizable", "models.title", fallback: "Models")
    internal enum Available {
      /// Available Models
      internal static let title = L10n.tr("Localizable", "models.available.title", fallback: "Available Models")
    }
    internal enum Empty {
      /// Add your first ML model to get started.
      internal static let messageAddModel = L10n.tr("Localizable", "models.empty.messageAddModel", fallback: "Add your first ML model to get started.")
      /// No Models
      internal static let title = L10n.tr("Localizable", "models.empty.title", fallback: "No Models")
    }
  }
  internal enum Paywall {
    /// Subscribed
    internal static let active = L10n.tr("Localizable", "paywall.active", fallback: "Subscribed")
    /// Cancel anytime in your Apple Account settings.
    internal static let cancelFooter = L10n.tr("Localizable", "paywall.cancelFooter", fallback: "Cancel anytime in your Apple Account settings.")
    /// Payment is charged to your Apple Account at confirmation. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple Account settings.
    internal static let disclosure = L10n.tr("Localizable", "paywall.disclosure", fallback: "Payment is charged to your Apple Account at confirmation. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple Account settings.")
    /// Payment is charged to your Apple Account when the free trial ends. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple Account settings.
    internal static let disclosureTrial = L10n.tr("Localizable", "paywall.disclosureTrial", fallback: "Payment is charged to your Apple Account when the free trial ends. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple Account settings.")
    /// Your free access has ended. Subscribe to keep using ML Browser and receive all future updates and improvements.
    internal static let expired = L10n.tr("Localizable", "paywall.expired", fallback: "Your free access has ended. Subscribe to keep using ML Browser and receive all future updates and improvements.")
    /// Export or Delete Findings
    internal static let findings = L10n.tr("Localizable", "paywall.findings", fallback: "Export or Delete Findings")
    /// Continue with unlimited access
    internal static let headline = L10n.tr("Localizable", "paywall.headline", fallback: "Continue with unlimited access")
    /// Unlimited access to every feature
    internal static let headlineFirstMeeting = L10n.tr("Localizable", "paywall.headlineFirstMeeting", fallback: "Unlimited access to every feature")
    /// Manage Subscription
    internal static let manage = L10n.tr("Localizable", "paywall.manage", fallback: "Manage Subscription")
    /// Subscribe to keep using ML Browser and receive all future updates and improvements.
    internal static let pitch = L10n.tr("Localizable", "paywall.pitch", fallback: "Subscribe to keep using ML Browser and receive all future updates and improvements.")
    /// Subscribe to use ML Browser and receive all future updates and improvements.
    internal static let pitchFirstMeeting = L10n.tr("Localizable", "paywall.pitchFirstMeeting", fallback: "Subscribe to use ML Browser and receive all future updates and improvements.")
    /// Restore Purchases
    internal static let restore = L10n.tr("Localizable", "paywall.restore", fallback: "Restore Purchases")
    /// Try Free for %@
    internal static func startTrial(_ p1: Any) -> String {
      return L10n.tr("Localizable", "paywall.startTrial", String(describing: p1), fallback: "Try Free for %@")
    }
    /// Subscribe
    internal static let subscribe = L10n.tr("Localizable", "paywall.subscribe", fallback: "Subscribe")
    /// Terms of Use
    internal static let terms = L10n.tr("Localizable", "paywall.terms", fallback: "Terms of Use")
    /// ML Browser
    internal static let title = L10n.tr("Localizable", "paywall.title", fallback: "ML Browser")
    /// Enjoying ML Browser?
    internal static let titleEngaged = L10n.tr("Localizable", "paywall.titleEngaged", fallback: "Enjoying ML Browser?")
    /// Nothing is charged during your free trial. Billing starts %@ after your purchase completes, unless you cancel.
    internal static func trialSupport(_ p1: Any) -> String {
      return L10n.tr("Localizable", "paywall.trialSupport", String(describing: p1), fallback: "Nothing is charged during your free trial. Billing starts %@ after your purchase completes, unless you cancel.")
    }
    /// Subscriptions are not available right now. Please try again later.
    internal static let unavailable = L10n.tr("Localizable", "paywall.unavailable", fallback: "Subscriptions are not available right now. Please try again later.")
    internal enum Benefit {
      /// Cancel anytime
      internal static let cancel = L10n.tr("Localizable", "paywall.benefit.cancel", fallback: "Cancel anytime")
      /// Every feature in ML Browser
      internal static let features = L10n.tr("Localizable", "paywall.benefit.features", fallback: "Every feature in ML Browser")
      /// Unlimited access
      internal static let unlimited = L10n.tr("Localizable", "paywall.benefit.unlimited", fallback: "Unlimited access")
      /// Ongoing improvements
      internal static let updates = L10n.tr("Localizable", "paywall.benefit.updates", fallback: "Ongoing improvements")
    }
    internal enum Billing {
      /// Your Apple Account has already used the free trial, so billing starts as soon as you subscribe.
      internal static let immediate = L10n.tr("Localizable", "paywall.billing.immediate", fallback: "Your Apple Account has already used the free trial, so billing starts as soon as you subscribe.")
    }
    internal enum Failed {
      /// The purchase could not be completed. Please try again, or use Restore Purchases if your Apple Account was already charged.
      internal static let message = L10n.tr("Localizable", "paywall.failed.message", fallback: "The purchase could not be completed. Please try again, or use Restore Purchases if your Apple Account was already charged.")
    }
    internal enum KeepFreeAccess {
      /// Keep My Free Days
      internal static let keep = L10n.tr("Localizable", "paywall.keepFreeAccess.keep", fallback: "Keep My Free Days")
      /// Subscribing now starts billing as soon as your purchase completes, so the days you have left aren't added to your subscription.
      internal static let messageNoTrial = L10n.tr("Localizable", "paywall.keepFreeAccess.messageNoTrial", fallback: "Subscribing now starts billing as soon as your purchase completes, so the days you have left aren't added to your subscription.")
      /// Subscribing now starts your trial as soon as your purchase completes, so the days you have left aren't added to it.
      internal static let messageWithTrial = L10n.tr("Localizable", "paywall.keepFreeAccess.messageWithTrial", fallback: "Subscribing now starts your trial as soon as your purchase completes, so the days you have left aren't added to it.")
      /// Subscribe Anyway
      internal static let subscribeAnyway = L10n.tr("Localizable", "paywall.keepFreeAccess.subscribeAnyway", fallback: "Subscribe Anyway")
      /// You still have %lld days of free access — no subscription and no payment method needed.
      internal static func titleNoPaymentNeeded(_ p1: Int) -> String {
        return L10n.tr("Localizable", "paywall.keepFreeAccess.titleNoPaymentNeeded", p1, fallback: "You still have %lld days of free access — no subscription and no payment method needed.")
      }
    }
    internal enum Pending {
      /// This purchase needs approval before it can complete. Access is granted automatically once it is approved — you can close this screen.
      internal static let message = L10n.tr("Localizable", "paywall.pending.message", fallback: "This purchase needs approval before it can complete. Access is granted automatically once it is approved — you can close this screen.")
      /// Waiting for Approval
      internal static let title = L10n.tr("Localizable", "paywall.pending.title", fallback: "Waiting for Approval")
    }
    internal enum RestoreEmpty {
      /// No subscription was found for the Apple Account signed in on this device.
      /// 
      /// Subscriptions belong to the Apple Account that paid, not to your ML Browser account. If you subscribed with a different Apple Account, sign in to the App Store with that one and tap Restore Purchases again. Buying here would start a second subscription.
      internal static let messageAppleAccount = L10n.tr("Localizable", "paywall.restoreEmpty.messageAppleAccount", fallback: "No subscription was found for the Apple Account signed in on this device.\n\nSubscriptions belong to the Apple Account that paid, not to your ML Browser account. If you subscribed with a different Apple Account, sign in to the App Store with that one and tap Restore Purchases again. Buying here would start a second subscription.")
      /// Nothing to Restore
      internal static let title = L10n.tr("Localizable", "paywall.restoreEmpty.title", fallback: "Nothing to Restore")
    }
    internal enum RestoreFailed {
      /// Your purchases could not be restored. Please try again.
      internal static let message = L10n.tr("Localizable", "paywall.restoreFailed.message", fallback: "Your purchases could not be restored. Please try again.")
    }
  }
  internal enum Sentry {
    /// Config
    internal static let config = L10n.tr("Localizable", "sentry.config", fallback: "Config")
    /// Counters
    internal static let counters = L10n.tr("Localizable", "sentry.counters", fallback: "Counters")
    /// Sentry throttle diagnostics not available in this build.
    internal static let notAvailable = L10n.tr("Localizable", "sentry.notAvailable", fallback: "Sentry throttle diagnostics not available in this build.")
  }
  internal enum Settings {
    /// About the app
    internal static let about = L10n.tr("Localizable", "settings.about", fallback: "About the app")
    /// Default Page
    internal static let defaultPage = L10n.tr("Localizable", "settings.defaultPage", fallback: "Default Page")
    /// Delete Cache
    internal static let deleteCache = L10n.tr("Localizable", "settings.deleteCache", fallback: "Delete Cache")
    /// Keep a detailed log
    internal static let detailedLogging = L10n.tr("Localizable", "settings.detailedLogging", fallback: "Keep a detailed log")
    /// Records what the app is doing in more detail and keeps it between launches, so a support report can cover a problem you hit earlier. Turning this off deletes the stored log.
    internal static let detailedLoggingExplanation = L10n.tr("Localizable", "settings.detailedLoggingExplanation", fallback: "Records what the app is doing in more detail and keeps it between launches, so a support report can cover a problem you hit earlier. Turning this off deletes the stored log.")
    /// Disable Detection Animations
    internal static let disableDetectionAnimations = L10n.tr("Localizable", "settings.disableDetectionAnimations", fallback: "Disable Detection Animations")
    /// Frequency
    internal static let frequency = L10n.tr("Localizable", "settings.frequency", fallback: "Frequency")
    /// Fullscreen Detection
    internal static let fullscreenDetection = L10n.tr("Localizable", "settings.fullscreenDetection", fallback: "Fullscreen Detection")
    /// 3x3 tiling
    internal static let grid3x3Tiling = L10n.tr("Localizable", "settings.grid3x3Tiling", fallback: "3x3 tiling")
    /// History
    internal static let history = L10n.tr("Localizable", "settings.history", fallback: "History")
    /// History Limit
    internal static let historyLimit = L10n.tr("Localizable", "settings.historyLimit", fallback: "History Limit")
    /// 0-100
    internal static let historyLimitPlaceholder = L10n.tr("Localizable", "settings.historyLimitPlaceholder", fallback: "0-100")
    /// Pyramid tiling
    internal static let pyramidTiling = L10n.tr("Localizable", "settings.pyramidTiling", fallback: "Pyramid tiling")
    /// Reopen Last Page
    internal static let reopenLastPage = L10n.tr("Localizable", "settings.reopenLastPage", fallback: "Reopen Last Page")
    /// Replay onboarding
    internal static let replayOnboarding = L10n.tr("Localizable", "settings.replayOnboarding", fallback: "Replay onboarding")
    /// Restore
    internal static let restore = L10n.tr("Localizable", "settings.restore", fallback: "Restore")
    /// Restore Defaults
    internal static let restoreDefaults = L10n.tr("Localizable", "settings.restoreDefaults", fallback: "Restore Defaults")
    /// Run At Launch
    internal static let runAtLaunch = L10n.tr("Localizable", "settings.runAtLaunch", fallback: "Run At Launch")
    /// Show Labels
    internal static let showLabels = L10n.tr("Localizable", "settings.showLabels", fallback: "Show Labels")
    /// Tiled Borders
    internal static let tiledBorders = L10n.tr("Localizable", "settings.tiledBorders", fallback: "Tiled Borders")
    /// Draws a red border around each tile fed to the detector, so you can see how the page is split. Detection is unaffected.
    internal static let tiledBordersFooter = L10n.tr("Localizable", "settings.tiledBordersFooter", fallback: "Draws a red border around each tile fed to the detector, so you can see how the page is split. Detection is unaffected.")
    /// Tiled Detection
    internal static let tiledDetection = L10n.tr("Localizable", "settings.tiledDetection", fallback: "Tiled Detection")
    /// Choose which tile layouts feed the detector. Enable either or both; both run the union of their tiles.
    internal static let tiledDetectionFooter = L10n.tr("Localizable", "settings.tiledDetectionFooter", fallback: "Choose which tile layouts feed the detector. Enable either or both; both run the union of their tiles.")
    /// Settings
    internal static let title = L10n.tr("Localizable", "settings.title", fallback: "Settings")
    /// Subscribe
    internal static let upgrade = L10n.tr("Localizable", "settings.upgrade", fallback: "Subscribe")
    internal enum Frequency {
      /// %lld seconds
      internal static func seconds(_ p1: Int) -> String {
        return L10n.tr("Localizable", "settings.frequency.seconds", p1, fallback: "%lld seconds")
      }
    }
    internal enum Reset {
      /// Reset
      internal static let title = L10n.tr("Localizable", "settings.reset.title", fallback: "Reset")
      internal enum RemoveFindings {
        /// Remove
        internal static let button = L10n.tr("Localizable", "settings.reset.removeFindings.button", fallback: "Remove")
        /// Delete All Findings
        internal static let delete = L10n.tr("Localizable", "settings.reset.removeFindings.delete", fallback: "Delete All Findings")
        /// Couldn’t remove findings. Please try again.
        internal static let error = L10n.tr("Localizable", "settings.reset.removeFindings.error", fallback: "Couldn’t remove findings. Please try again.")
        /// Export First…
        internal static let export = L10n.tr("Localizable", "settings.reset.removeFindings.export", fallback: "Export First…")
        /// This permanently deletes every saved finding and its photo. Export first if you want to keep a copy — exporting does not delete anything.
        internal static let message = L10n.tr("Localizable", "settings.reset.removeFindings.message", fallback: "This permanently deletes every saved finding and its photo. Export first if you want to keep a copy — exporting does not delete anything.")
        /// Remove Findings
        internal static let row = L10n.tr("Localizable", "settings.reset.removeFindings.row", fallback: "Remove Findings")
        /// Remove all findings?
        internal static let title = L10n.tr("Localizable", "settings.reset.removeFindings.title", fallback: "Remove all findings?")
      }
    }
    internal enum Section {
      /// Annotation
      internal static let annotation = L10n.tr("Localizable", "settings.section.annotation", fallback: "Annotation")
      /// Debug
      internal static let debug = L10n.tr("Localizable", "settings.section.debug", fallback: "Debug")
      /// ML Browser
      internal static let mlBrowser = L10n.tr("Localizable", "settings.section.mlBrowser", fallback: "ML Browser")
      /// Web Content
      internal static let webContent = L10n.tr("Localizable", "settings.section.webContent", fallback: "Web Content")
    }
    internal enum Sentry {
      /// Sentry Stats
      internal static let title = L10n.tr("Localizable", "settings.sentry.title", fallback: "Sentry Stats")
    }
    internal enum Subscription {
      /// Free until %@ — no subscription, no payment method.
      internal static func freeAccessFootnoteNoTrial(_ p1: Any) -> String {
        return L10n.tr("Localizable", "settings.subscription.freeAccessFootnoteNoTrial", String(describing: p1), fallback: "Free until %@ — no subscription, no payment method.")
      }
      /// Free until %1$@ — no subscription, no payment method. Subscribing starts a %2$@ free trial from that moment; your remaining free days aren't added to it.
      internal static func freeAccessFootnoteWithTrial(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "settings.subscription.freeAccessFootnoteWithTrial", String(describing: p1), String(describing: p2), fallback: "Free until %1$@ — no subscription, no payment method. Subscribing starts a %2$@ free trial from that moment; your remaining free days aren't added to it.")
      }
      /// Your free trial runs until %@, when the first charge is made.
      internal static func trialFootnote(_ p1: Any) -> String {
        return L10n.tr("Localizable", "settings.subscription.trialFootnote", String(describing: p1), fallback: "Your free trial runs until %@, when the first charge is made.")
      }
    }
  }
  internal enum Subscription {
    /// Not subscribed
    internal static let notSubscribed = L10n.tr("Localizable", "subscription.notSubscribed", fallback: "Not subscribed")
    /// Plan
    internal static let plan = L10n.tr("Localizable", "subscription.plan", fallback: "Plan")
    /// %1$@ / %2$@
    internal static func planTerm(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "subscription.planTerm", String(describing: p1), String(describing: p2), fallback: "%1$@ / %2$@")
    }
    /// %1$@ per %2$@
    internal static func planTermSpoken(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "subscription.planTermSpoken", String(describing: p1), String(describing: p2), fallback: "%1$@ per %2$@")
    }
    /// Renews
    internal static let renews = L10n.tr("Localizable", "subscription.renews", fallback: "Renews")
    /// Status
    internal static let state = L10n.tr("Localizable", "subscription.state", fallback: "Status")
    /// Free trial
    internal static let trial = L10n.tr("Localizable", "subscription.trial", fallback: "Free trial")
    /// Free trial until
    internal static let trialEnds = L10n.tr("Localizable", "subscription.trialEnds", fallback: "Free trial until")
    internal enum Period {
      /// day
      internal static let day = L10n.tr("Localizable", "subscription.period.day", fallback: "day")
      /// month
      internal static let month = L10n.tr("Localizable", "subscription.period.month", fallback: "month")
      /// week
      internal static let week = L10n.tr("Localizable", "subscription.period.week", fallback: "week")
      /// year
      internal static let year = L10n.tr("Localizable", "subscription.period.year", fallback: "year")
    }
  }
  internal enum Support {
    /// Screenshot attached
    internal static let attachedScreenshot = L10n.tr("Localizable", "support.attachedScreenshot", fallback: "Screenshot attached")
    /// Attach a screenshot
    internal static let attachScreenshot = L10n.tr("Localizable", "support.attachScreenshot", fallback: "Attach a screenshot")
    /// What is this about?
    internal static let categoryPrompt = L10n.tr("Localizable", "support.categoryPrompt", fallback: "What is this about?")
    /// Continue in Mail
    internal static let compose = L10n.tr("Localizable", "support.compose", fallback: "Continue in Mail")
    /// Copy report
    internal static let copyReport = L10n.tr("Localizable", "support.copyReport", fallback: "Copy report")
    /// Detect screenshots
    internal static let detectScreenshots = L10n.tr("Localizable", "support.detectScreenshots", fallback: "Detect screenshots")
    /// Include application log
    internal static let includeApplicationLog = L10n.tr("Localizable", "support.includeApplicationLog", fallback: "Include application log")
    /// Open Settings
    internal static let openSettings = L10n.tr("Localizable", "support.openSettings", fallback: "Open Settings")
    /// Nothing is sent until you send it. You will see the whole email and can remove any screenshot or app log attachment before sending.
    internal static let privacyNote = L10n.tr("Localizable", "support.privacyNote", fallback: "Nothing is sent until you send it. You will see the whole email and can remove any screenshot or app log attachment before sending.")
    /// Report copied. Paste it into an email to %@.
    internal static func reportCopied(_ p1: Any) -> String {
      return L10n.tr("Localizable", "support.reportCopied", String(describing: p1), fallback: "Report copied. Paste it into an email to %@.")
    }
    /// Send email
    internal static let sendEmail = L10n.tr("Localizable", "support.sendEmail", fallback: "Send email")
    /// Send unredacted data
    internal static let sendUnredactedData = L10n.tr("Localizable", "support.sendUnredactedData", fallback: "Send unredacted data")
    /// Use this only if you are comfortable sharing the full technical details. It can include complete web addresses, IDs and location information, which may help us reproduce the problem.
    internal static let sendUnredactedDataExplanation = L10n.tr("Localizable", "support.sendUnredactedDataExplanation", fallback: "Use this only if you are comfortable sharing the full technical details. It can include complete web addresses, IDs and location information, which may help us reproduce the problem.")
    /// Save or share the log
    internal static let shareApplicationLog = L10n.tr("Localizable", "support.shareApplicationLog", fallback: "Save or share the log")
    /// Report a problem
    internal static let title = L10n.tr("Localizable", "support.title", fallback: "Report a problem")
    internal enum ApplicationLog {
      /// This makes your report much more useful. It gives us a short record of what the app was doing before the problem.
      internal static let explanation = L10n.tr("Localizable", "support.applicationLog.explanation", fallback: "This makes your report much more useful. It gives us a short record of what the app was doing before the problem.")
    }
    internal enum Body {
      /// Account
      internal static let account = L10n.tr("Localizable", "support.body.account", fallback: "Account")
      /// Support category
      internal static let category = L10n.tr("Localizable", "support.body.category", fallback: "Support category")
      /// Please describe the problem here:
      internal static let describePrompt = L10n.tr("Localizable", "support.body.describePrompt", fallback: "Please describe the problem here:")
      /// Technical details — these help us find the problem. You can edit or remove anything below before sending.
      internal static let detailsHeader = L10n.tr("Localizable", "support.body.detailsHeader", fallback: "Technical details — these help us find the problem. You can edit or remove anything below before sending.")
      /// App language
      internal static let language = L10n.tr("Localizable", "support.body.language", fallback: "App language")
      /// Web address
      internal static let webAddress = L10n.tr("Localizable", "support.body.webAddress", fallback: "Web address")
    }
    internal enum Category {
      /// Account or login
      internal static let account = L10n.tr("Localizable", "support.category.account", fallback: "Account or login")
      /// Bug or technical problem
      internal static let bug = L10n.tr("Localizable", "support.category.bug", fallback: "Bug or technical problem")
      /// Feature request
      internal static let featureRequest = L10n.tr("Localizable", "support.category.featureRequest", fallback: "Feature request")
      /// Other
      internal static let other = L10n.tr("Localizable", "support.category.other", fallback: "Other")
      /// Privacy or account deletion
      internal static let privacy = L10n.tr("Localizable", "support.category.privacy", fallback: "Privacy or account deletion")
      /// Purchase or subscription
      internal static let purchase = L10n.tr("Localizable", "support.category.purchase", fallback: "Purchase or subscription")
    }
    internal enum MailUnavailable {
      /// We opened your default mail app instead — attachments cannot be added that way. If it says no account is set up, add one in Settings → Mail → Mail Accounts. You can also copy the report and send it to %@ from anywhere.
      internal static func message(_ p1: Any) -> String {
        return L10n.tr("Localizable", "support.mailUnavailable.message", String(describing: p1), fallback: "We opened your default mail app instead — attachments cannot be added that way. If it says no account is set up, add one in Settings → Mail → Mail Accounts. You can also copy the report and send it to %@ from anywhere.")
      }
      /// No mail app could be opened. Add an email account in Settings → Mail → Mail Accounts, or copy the report and send it to %@ from another device.
      internal static func messageNoMailApp(_ p1: Any) -> String {
        return L10n.tr("Localizable", "support.mailUnavailable.messageNoMailApp", String(describing: p1), fallback: "No mail app could be opened. Add an email account in Settings → Mail → Mail Accounts, or copy the report and send it to %@ from another device.")
      }
      /// Couldn't open Mail
      internal static let title = L10n.tr("Localizable", "support.mailUnavailable.title", fallback: "Couldn't open Mail")
    }
    internal enum Prompt {
      /// Don't ask again
      internal static let dontAskAgain = L10n.tr("Localizable", "support.prompt.dontAskAgain", fallback: "Don't ask again")
      /// If something looks wrong, you can send us that screenshot with a short description.
      internal static let message = L10n.tr("Localizable", "support.prompt.message", fallback: "If something looks wrong, you can send us that screenshot with a short description.")
      /// Report a problem
      internal static let report = L10n.tr("Localizable", "support.prompt.report", fallback: "Report a problem")
      /// Found a problem?
      internal static let title = L10n.tr("Localizable", "support.prompt.title", fallback: "Found a problem?")
    }
    internal enum ScreenshotTooSmall {
      /// Choose a screenshot with at least %d pixels on its shortest side so the details stay readable.
      internal static func message(_ p1: Int) -> String {
        return L10n.tr("Localizable", "support.screenshotTooSmall.message", p1, fallback: "Choose a screenshot with at least %d pixels on its shortest side so the details stay readable.")
      }
      /// Screenshot is too small
      internal static let title = L10n.tr("Localizable", "support.screenshotTooSmall.title", fallback: "Screenshot is too small")
    }
    internal enum ScreenshotUnreadable {
      /// We couldn't read that image. Please choose another screenshot.
      internal static let message = L10n.tr("Localizable", "support.screenshotUnreadable.message", fallback: "We couldn't read that image. Please choose another screenshot.")
      /// Couldn't use screenshot
      internal static let title = L10n.tr("Localizable", "support.screenshotUnreadable.title", fallback: "Couldn't use screenshot")
    }
  }
  internal enum Symbol {
    /// Circle
    internal static let circle = L10n.tr("Localizable", "symbol.circle", fallback: "Circle")
    /// Point
    internal static let point = L10n.tr("Localizable", "symbol.point", fallback: "Point")
    /// Rectangle
    internal static let rectangle = L10n.tr("Localizable", "symbol.rectangle", fallback: "Rectangle")
  }
  internal enum Tab {
    /// Examples
    internal static let examples = L10n.tr("Localizable", "tab.examples", fallback: "Examples")
    /// Web
    internal static let web = L10n.tr("Localizable", "tab.web", fallback: "Web")
  }
  internal enum Tour {
    /// My demo finding
    internal static let defaultFindingTitle = L10n.tr("Localizable", "tour.defaultFindingTitle", fallback: "My demo finding")
    /// Next
    internal static let next = L10n.tr("Localizable", "tour.next", fallback: "Next")
    /// Skip
    internal static let skip = L10n.tr("Localizable", "tour.skip", fallback: "Skip")
    internal enum AddressBar {
      /// Type a page address here — sample pages are already in your history.
      internal static let text = L10n.tr("Localizable", "tour.addressBar.text", fallback: "Type a page address here — sample pages are already in your history.")
    }
    internal enum Capture {
      /// Now tap anywhere on the map to mark your finding.
      internal static let text = L10n.tr("Localizable", "tour.capture.text", fallback: "Now tap anywhere on the map to mark your finding.")
    }
    internal enum DemoModels {
      /// These are your detection models, ready to go.
      internal static let text = L10n.tr("Localizable", "tour.demoModels.text", fallback: "These are your detection models, ready to go.")
    }
    internal enum EnableModel {
      /// Switch a model on to start using it.
      internal static let text = L10n.tr("Localizable", "tour.enableModel.text", fallback: "Switch a model on to start using it.")
    }
    internal enum Find {
      /// Tap here to capture a finding.
      internal static let text = L10n.tr("Localizable", "tour.find.text", fallback: "Tap here to capture a finding.")
    }
    internal enum Finished {
      /// That's it — you saved your first finding! You're all set.
      internal static let text = L10n.tr("Localizable", "tour.finished.text", fallback: "That's it — you saved your first finding! You're all set.")
    }
    internal enum ModelsButton {
      /// Tap here to download or configure your detection models.
      internal static let text = L10n.tr("Localizable", "tour.modelsButton.text", fallback: "Tap here to download or configure your detection models.")
    }
    internal enum Play {
      /// Tap to start detecting features on the page.
      internal static let text = L10n.tr("Localizable", "tour.play.text", fallback: "Tap to start detecting features on the page.")
    }
    internal enum Save {
      /// Tap Save to store your finding.
      internal static let text = L10n.tr("Localizable", "tour.save.text", fallback: "Tap Save to store your finding.")
    }
  }
  internal enum Welcome {
    /// No subscription required today. Take your time, discover the app, and decide later if it's right for you.
    internal static let body = L10n.tr("Localizable", "welcome.body", fallback: "No subscription required today. Take your time, discover the app, and decide later if it's right for you.")
    /// Continue
    internal static let continueButton = L10n.tr("Localizable", "welcome.continueButton", fallback: "Continue")
    /// Explore everything free for %lld days
    internal static func headline(_ p1: Int) -> String {
      return L10n.tr("Localizable", "welcome.headline", p1, fallback: "Explore everything free for %lld days")
    }
    /// After your free access ends, you can subscribe for %@ to continue using ML Browser.
    internal static func priceNote(_ p1: Any) -> String {
      return L10n.tr("Localizable", "welcome.priceNote", String(describing: p1), fallback: "After your free access ends, you can subscribe for %@ to continue using ML Browser.")
    }
    /// After your free access ends, you can subscribe to continue using ML Browser.
    internal static let priceNoteGeneric = L10n.tr("Localizable", "welcome.priceNoteGeneric", fallback: "After your free access ends, you can subscribe to continue using ML Browser.")
    /// Welcome to ML Browser
    internal static let title = L10n.tr("Localizable", "welcome.title", fallback: "Welcome to ML Browser")
    internal enum Footer {
      /// You'll only be asked to subscribe after your free access ends.
      internal static let askLater = L10n.tr("Localizable", "welcome.footer.askLater", fallback: "You'll only be asked to subscribe after your free access ends.")
      /// No credit card required.
      internal static let noCard = L10n.tr("Localizable", "welcome.footer.noCard", fallback: "No credit card required.")
      /// No payment today.
      internal static let noPayment = L10n.tr("Localizable", "welcome.footer.noPayment", fallback: "No payment today.")
    }
  }
}
// swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg..., fallback value: String) -> String {
    let format = BundleToken.bundle.localizedString(forKey: key, value: value, table: table)
    return String(format: format, locale: Locale.current, arguments: args)
  }
}

// swiftlint:disable convenience_type
private final class BundleToken {
  static let bundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle(for: BundleToken.self)
    #endif
  }()
}
// swiftlint:enable convenience_type
