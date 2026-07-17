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
      /// Legal
      internal static let legal = L10n.tr("Localizable", "about.section.legal", fallback: "Legal")
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
      /// Share anonymous, privacy-safe usage statistics to help improve the app. Analytics is off unless you enable it.
      internal static let message = L10n.tr("Localizable", "analytics.choice.message", fallback: "Share anonymous, privacy-safe usage statistics to help improve the app. Analytics is off unless you enable it.")
      /// Not now
      internal static let notNow = L10n.tr("Localizable", "analytics.choice.notNow", fallback: "Not now")
      /// Help improve ML Browser
      internal static let title = L10n.tr("Localizable", "analytics.choice.title", fallback: "Help improve ML Browser")
    }
    internal enum Settings {
      /// Analytics is off by default. You can change this at any time. Page content, images, URLs, titles, filenames, detection results, and model names are never sent.
      internal static let footer = L10n.tr("Localizable", "analytics.settings.footer", fallback: "Analytics is off by default. You can change this at any time. Page content, images, URLs, titles, filenames, detection results, and model names are never sent.")
      /// Privacy
      internal static let title = L10n.tr("Localizable", "analytics.settings.title", fallback: "Privacy")
      /// Share anonymous usage data
      internal static let toggle = L10n.tr("Localizable", "analytics.settings.toggle", fallback: "Share anonymous usage data")
    }
  }
  internal enum Auth {
    /// Checking your session…
    internal static let checking = L10n.tr("Localizable", "auth.checking", fallback: "Checking your session…")
    /// Sign Out
    internal static let signOut = L10n.tr("Localizable", "auth.signOut", fallback: "Sign Out")
    internal enum Account {
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
        /// This permanently deletes your account and cannot be undone. Are you sure?
        internal static let message = L10n.tr("Localizable", "auth.account.delete.message", fallback: "This permanently deletes your account and cannot be undone. Are you sure?")
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
      /// ML Browser needs an internet connection to verify your account. Reconnect and try again.
      internal static let message = L10n.tr("Localizable", "auth.offline.message", fallback: "ML Browser needs an internet connection to verify your account. Reconnect and try again.")
      /// Try Again
      internal static let retry = L10n.tr("Localizable", "auth.offline.retry", fallback: "Try Again")
      /// No connection
      internal static let title = L10n.tr("Localizable", "auth.offline.title", fallback: "No connection")
    }
    internal enum SignIn {
      /// Sign In
      internal static let button = L10n.tr("Localizable", "auth.signIn.button", fallback: "Sign In")
      /// Sign in to detect objects on any website.
      internal static let tagline = L10n.tr("Localizable", "auth.signIn.tagline", fallback: "Sign in to detect objects on any website.")
      /// Welcome to ML Browser
      internal static let title = L10n.tr("Localizable", "auth.signIn.title", fallback: "Welcome to ML Browser")
    }
  }
  internal enum Browser {
    internal enum FloatingButton {
      /// Show or hide browser controls
      internal static let label = L10n.tr("Localizable", "browser.floatingButton.label", fallback: "Show or hide browser controls")
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
    }
    internal enum Empty {
      /// Search for an object-detection or image-classification Core ML model.
      internal static let message = L10n.tr("Localizable", "catalog.empty.message", fallback: "Search for an object-detection or image-classification Core ML model.")
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
      /// This result does not include an installable Core ML model.
      internal static let unsupportedModel = L10n.tr("Localizable", "catalog.error.unsupportedModel", fallback: "This result does not include an installable Core ML model.")
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
      /// Models
      internal static let title = L10n.tr("Localizable", "catalog.results.title", fallback: "Models")
    }
    internal enum Search {
      /// Search models
      internal static let prompt = L10n.tr("Localizable", "catalog.search.prompt", fallback: "Search models")
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
    /// Created
    internal static let created = L10n.tr("Localizable", "configuration.created", fallback: "Created")
    /// Description
    internal static let description = L10n.tr("Localizable", "configuration.description", fallback: "Description")
    /// Fade Out Time
    internal static let fadeOutTime = L10n.tr("Localizable", "configuration.fadeOutTime", fallback: "Fade Out Time")
    /// File
    internal static let file = L10n.tr("Localizable", "configuration.file", fallback: "File")
    /// Flash when object found
    internal static let flashOnFinding = L10n.tr("Localizable", "configuration.flashOnFinding", fallback: "Flash when object found")
    /// Flash border size
    internal static let flashSize = L10n.tr("Localizable", "configuration.flashSize", fallback: "Flash border size")
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
    /// Symbol
    internal static let symbol = L10n.tr("Localizable", "configuration.symbol", fallback: "Symbol")
    /// Configuration
    internal static let title = L10n.tr("Localizable", "configuration.title", fallback: "Configuration")
    /// Type
    internal static let type = L10n.tr("Localizable", "configuration.type", fallback: "Type")
    /// Version
    internal static let version = L10n.tr("Localizable", "configuration.version", fallback: "Version")
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
    /// Enter a direct .mlmodel URL for a detection or classification model. Use Open Catalog for multi-file .mlpackage models.
    internal static let urlHint = L10n.tr("Localizable", "download.urlHint", fallback: "Enter a direct .mlmodel URL for a detection or classification model. Use Open Catalog for multi-file .mlpackage models.")
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
      /// Dark
      internal static let dark = L10n.tr("Localizable", "finding.share.dark", fallback: "Dark")
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
  }
  internal enum Findings {
    /// Export
    internal static let export = L10n.tr("Localizable", "findings.export", fallback: "Export")
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
    /// Confirm the model type
    internal static let confirmTypeTitle = L10n.tr("Localizable", "import.confirmTypeTitle", fallback: "Confirm the model type")
    /// Import from Files
    internal static let fromFiles = L10n.tr("Localizable", "import.fromFiles", fallback: "Import from Files")
    /// Select a .mlmodel or .mlpackage file
    internal static let fromFilesHint = L10n.tr("Localizable", "import.fromFilesHint", fallback: "Select a .mlmodel or .mlpackage file")
    /// Download from URL
    internal static let fromURL = L10n.tr("Localizable", "import.fromURL", fallback: "Download from URL")
    /// Download a model from the internet
    internal static let fromURLHint = L10n.tr("Localizable", "import.fromURLHint", fallback: "Download a model from the internet")
    /// Learn More
    internal static let learnMore = L10n.tr("Localizable", "import.learnMore", fallback: "Learn More")
    /// ONNX Conversion
    internal static let onnxConversion = L10n.tr("Localizable", "import.onnxConversion", fallback: "ONNX Conversion")
    /// Use this Python code to convert ONNX models:
    internal static let onnxConversionHint = L10n.tr("Localizable", "import.onnxConversionHint", fallback: "Use this Python code to convert ONNX models:")
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
    /// Choose a Core ML model (.mlmodel or .mlpackage) that supports object detection or image classification. Other model types are not supported in this version.
    internal static let supportedModelsInfo = L10n.tr("Localizable", "import.supportedModelsInfo", fallback: "Choose a Core ML model (.mlmodel or .mlpackage) that supports object detection or image classification. Other model types are not supported in this version.")
    /// Import Model
    internal static let title = L10n.tr("Localizable", "import.title", fallback: "Import Model")
    /// The model was imported. The app can't verify what an imported model does, so please confirm its type on the next screen. You're responsible for the choice, and a wrong type can produce incorrect results.
    internal static let typeConfirmation = L10n.tr("Localizable", "import.typeConfirmation", fallback: "The model was imported. The app can't verify what an imported model does, so please confirm its type on the next screen. You're responsible for the choice, and a wrong type can produce incorrect results.")
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
    /// Models
    internal static let title = L10n.tr("Localizable", "models.title", fallback: "Models")
    internal enum Available {
      /// Available Models
      internal static let title = L10n.tr("Localizable", "models.available.title", fallback: "Available Models")
    }
    internal enum Empty {
      /// Tap the + button to add your first ML model.
      internal static let message = L10n.tr("Localizable", "models.empty.message", fallback: "Tap the + button to add your first ML model.")
      /// No Models
      internal static let title = L10n.tr("Localizable", "models.empty.title", fallback: "No Models")
    }
  }
  internal enum Paywall {
    /// Subscribed
    internal static let active = L10n.tr("Localizable", "paywall.active", fallback: "Subscribed")
    /// Payment is charged to your Apple ID at confirmation. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in Settings.
    internal static let disclosure = L10n.tr("Localizable", "paywall.disclosure", fallback: "Payment is charged to your Apple ID at confirmation. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in Settings.")
    /// Manage Subscription
    internal static let manage = L10n.tr("Localizable", "paywall.manage", fallback: "Manage Subscription")
    /// Request a Refund
    internal static let requestRefund = L10n.tr("Localizable", "paywall.requestRefund", fallback: "Request a Refund")
    /// Restore Purchases
    internal static let restore = L10n.tr("Localizable", "paywall.restore", fallback: "Restore Purchases")
    /// Subscribe
    internal static let subscribe = L10n.tr("Localizable", "paywall.subscribe", fallback: "Subscribe")
    /// Subscribe to unlock the full app.
    internal static let tagline = L10n.tr("Localizable", "paywall.tagline", fallback: "Subscribe to unlock the full app.")
    /// Terms of Use
    internal static let terms = L10n.tr("Localizable", "paywall.terms", fallback: "Terms of Use")
    /// ML Browser
    internal static let title = L10n.tr("Localizable", "paywall.title", fallback: "ML Browser")
    /// Free for %1$@, then %2$@
    internal static func trialFormat(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "paywall.trialFormat", String(describing: p1), String(describing: p2), fallback: "Free for %1$@, then %2$@")
    }
    /// Subscriptions are not available right now. Please try again later.
    internal static let unavailable = L10n.tr("Localizable", "paywall.unavailable", fallback: "Subscriptions are not available right now. Please try again later.")
    internal enum Failed {
      /// The purchase could not be completed. Please try again, or use Restore Purchases if your Apple Account was already charged.
      internal static let message = L10n.tr("Localizable", "paywall.failed.message", fallback: "The purchase could not be completed. Please try again, or use Restore Purchases if your Apple Account was already charged.")
    }
    internal enum Pending {
      /// This purchase needs approval before it can complete. Access is granted automatically once it is approved — you can close this screen.
      internal static let message = L10n.tr("Localizable", "paywall.pending.message", fallback: "This purchase needs approval before it can complete. Access is granted automatically once it is approved — you can close this screen.")
      /// Waiting for Approval
      internal static let title = L10n.tr("Localizable", "paywall.pending.title", fallback: "Waiting for Approval")
    }
    internal enum RestoreEmpty {
      /// No previous subscription was found for this Apple Account.
      internal static let message = L10n.tr("Localizable", "paywall.restoreEmpty.message", fallback: "No previous subscription was found for this Apple Account.")
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
    internal enum Refund {
      internal enum Duplicate {
        /// You have already requested a refund for this purchase. Apple is still reviewing it.
        internal static let message = L10n.tr("Localizable", "subscription.refund.duplicate.message", fallback: "You have already requested a refund for this purchase. Apple is still reviewing it.")
        /// Already Requested
        internal static let title = L10n.tr("Localizable", "subscription.refund.duplicate.title", fallback: "Already Requested")
      }
      internal enum Failed {
        /// The refund request could not be sent. You can also request a refund at reportaproblem.apple.com.
        internal static let message = L10n.tr("Localizable", "subscription.refund.failed.message", fallback: "The refund request could not be sent. You can also request a refund at reportaproblem.apple.com.")
      }
      internal enum Submitted {
        /// The App Store has your request. Apple decides the outcome and will let you know. Your subscription stays active until a refund is approved.
        internal static let message = L10n.tr("Localizable", "subscription.refund.submitted.message", fallback: "The App Store has your request. Apple decides the outcome and will let you know. Your subscription stays active until a refund is approved.")
        /// Refund Requested
        internal static let title = L10n.tr("Localizable", "subscription.refund.submitted.title", fallback: "Refund Requested")
      }
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
    /// Nothing is sent until you send it. You will see the whole email — including the technical details and any screenshot you attach — and can edit it first.
    internal static let privacyNote = L10n.tr("Localizable", "support.privacyNote", fallback: "Nothing is sent until you send it. You will see the whole email — including the technical details and any screenshot you attach — and can edit it first.")
    /// Report a problem
    internal static let title = L10n.tr("Localizable", "support.title", fallback: "Report a problem")
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
      /// No email account is set up on this device, so we opened your default mail app instead. A screenshot cannot be attached that way — please add it yourself, or write to %@.
      internal static func message(_ p1: Any) -> String {
        return L10n.tr("Localizable", "support.mailUnavailable.message", String(describing: p1), fallback: "No email account is set up on this device, so we opened your default mail app instead. A screenshot cannot be attached that way — please add it yourself, or write to %@.")
      }
      /// No email account or mail app is available on this device. Please write to %@ from another device — mentioning the app version shown under Settings → About helps us find the problem.
      internal static func messageNoMailApp(_ p1: Any) -> String {
        return L10n.tr("Localizable", "support.mailUnavailable.messageNoMailApp", String(describing: p1), fallback: "No email account or mail app is available on this device. Please write to %@ from another device — mentioning the app version shown under Settings → About helps us find the problem.")
      }
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
  }
  internal enum Symbol {
    /// Circle
    internal static let circle = L10n.tr("Localizable", "symbol.circle", fallback: "Circle")
    /// Point
    internal static let point = L10n.tr("Localizable", "symbol.point", fallback: "Point")
    /// Square
    internal static let square = L10n.tr("Localizable", "symbol.square", fallback: "Square")
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
      /// Type a page address here — a Bavaria LiDAR page is already in your history.
      internal static let text = L10n.tr("Localizable", "tour.addressBar.text", fallback: "Type a page address here — a Bavaria LiDAR page is already in your history.")
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
