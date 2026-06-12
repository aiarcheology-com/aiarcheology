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
  }
  internal enum Configuration {
    /// Author
    internal static let author = L10n.tr("Localizable", "configuration.author", fallback: "Author")
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
    /// Link
    internal static let link = L10n.tr("Localizable", "configuration.link", fallback: "Link")
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
    /// Provide a valid address pointing to a Create ML detection model (.mlmodel)
    internal static let urlHint = L10n.tr("Localizable", "download.urlHint", fallback: "Provide a valid address pointing to a Create ML detection model (.mlmodel)")
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
  }
  internal enum Findings {
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
    /// The model %1$@ from %2$@ has been successfully imported.
    internal static func successWithInfo(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "import.successWithInfo", String(describing: p1), String(describing: p2), fallback: "The model %1$@ from %2$@ has been successfully imported.")
    }
    /// Supported Models
    internal static let supportedModels = L10n.tr("Localizable", "import.supportedModels", fallback: "Supported Models")
    /// Choose a Create ML model (.mlmodel or .mlpackage) that supports object detection. Other model types are not supported in this version.
    internal static let supportedModelsInfo = L10n.tr("Localizable", "import.supportedModelsInfo", fallback: "Choose a Create ML model (.mlmodel or .mlpackage) that supports object detection. Other model types are not supported in this version.")
    /// Import Model
    internal static let title = L10n.tr("Localizable", "import.title", fallback: "Import Model")
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
    /// History
    internal static let history = L10n.tr("Localizable", "settings.history", fallback: "History")
    /// History Limit
    internal static let historyLimit = L10n.tr("Localizable", "settings.historyLimit", fallback: "History Limit")
    /// Introduction
    internal static let introduction = L10n.tr("Localizable", "settings.introduction", fallback: "Introduction")
    /// Reopen Last Page
    internal static let reopenLastPage = L10n.tr("Localizable", "settings.reopenLastPage", fallback: "Reopen Last Page")
    /// Restore
    internal static let restore = L10n.tr("Localizable", "settings.restore", fallback: "Restore")
    /// Restore Defaults
    internal static let restoreDefaults = L10n.tr("Localizable", "settings.restoreDefaults", fallback: "Restore Defaults")
    /// Run At Launch
    internal static let runAtLaunch = L10n.tr("Localizable", "settings.runAtLaunch", fallback: "Run At Launch")
    /// Show Labels
    internal static let showLabels = L10n.tr("Localizable", "settings.showLabels", fallback: "Show Labels")
    /// Show next time
    internal static let showNextTime = L10n.tr("Localizable", "settings.showNextTime", fallback: "Show next time")
    /// Tiled Detection
    internal static let tiledDetection = L10n.tr("Localizable", "settings.tiledDetection", fallback: "Tiled Detection")
    /// Settings
    internal static let title = L10n.tr("Localizable", "settings.title", fallback: "Settings")
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
  internal enum Slideshow {
    internal enum Slide0 {
      /// The application combines the browsing experience with assisted object detection within web content.
      internal static let description = L10n.tr("Localizable", "slideshow.slide0.description", fallback: "The application combines the browsing experience with assisted object detection within web content.")
      /// Welcome to ML Browser
      internal static let title = L10n.tr("Localizable", "slideshow.slide0.title", fallback: "Welcome to ML Browser")
    }
    internal enum Slide1 {
      /// You can open any web page, similar to how you would in a web browser, with content you wish to test using your object detection model.
      internal static let description = L10n.tr("Localizable", "slideshow.slide1.description", fallback: "You can open any web page, similar to how you would in a web browser, with content you wish to test using your object detection model.")
      /// Open a Web Page
      internal static let title = L10n.tr("Localizable", "slideshow.slide1.title", fallback: "Open a Web Page")
    }
    internal enum Slide2 {
      /// Start to write in the address bar and you will see pages from your history.
      internal static let description = L10n.tr("Localizable", "slideshow.slide2.description", fallback: "Start to write in the address bar and you will see pages from your history.")
      /// Pick a page from the browsing history
      internal static let title = L10n.tr("Localizable", "slideshow.slide2.title", fallback: "Pick a page from the browsing history")
    }
    internal enum Slide3 {
      /// The application is capable of working with Create ML detection models. Click the processor icon in the top left corner, and then plus sign to add a new model.
      internal static let description = L10n.tr("Localizable", "slideshow.slide3.description", fallback: "The application is capable of working with Create ML detection models. Click the processor icon in the top left corner, and then plus sign to add a new model.")
      /// Add a New Model
      internal static let title = L10n.tr("Localizable", "slideshow.slide3.title", fallback: "Add a New Model")
    }
    internal enum Slide4 {
      /// You can download any Create ML detection model to your Apple device and load it into the ML Browser app. The ML Browser does not send your model anywhere, or collect information. The model is used only for the annotations.
      internal static let description = L10n.tr("Localizable", "slideshow.slide4.description", fallback: "You can download any Create ML detection model to your Apple device and load it into the ML Browser app. The ML Browser does not send your model anywhere, or collect information. The model is used only for the annotations.")
      /// Open the Model from the device, or download it.
      internal static let title = L10n.tr("Localizable", "slideshow.slide4.title", fallback: "Open the Model from the device, or download it.")
    }
    internal enum Slide5 {
      /// In this menu on the left, you can activate any detection model. These detectors work simultaneously on the same web page content.
      internal static let description = L10n.tr("Localizable", "slideshow.slide5.description", fallback: "In this menu on the left, you can activate any detection model. These detectors work simultaneously on the same web page content.")
      /// Activate the Models
      internal static let title = L10n.tr("Localizable", "slideshow.slide5.title", fallback: "Activate the Models")
    }
    internal enum Slide6 {
      /// When you select a model from the left menu, you can adjust various annotation options.
      internal static let description = L10n.tr("Localizable", "slideshow.slide6.description", fallback: "When you select a model from the left menu, you can adjust various annotation options.")
      /// Change the Model's Annotation Options
      internal static let title = L10n.tr("Localizable", "slideshow.slide6.title", fallback: "Change the Model's Annotation Options")
    }
    internal enum Slide7 {
      /// In some cases, you can aid the detector by altering the browser's rendering properties, such as brightness and contrast.
      internal static let description = L10n.tr("Localizable", "slideshow.slide7.description", fallback: "In some cases, you can aid the detector by altering the browser's rendering properties, such as brightness and contrast.")
      /// Adjust Screen Image Properties
      internal static let title = L10n.tr("Localizable", "slideshow.slide7.title", fallback: "Adjust Screen Image Properties")
    }
    internal enum Slide8 {
      /// After hitting the button, the detectors start to label the web content.
      internal static let description = L10n.tr("Localizable", "slideshow.slide8.description", fallback: "After hitting the button, the detectors start to label the web content.")
      /// Hit the Play Button
      internal static let title = L10n.tr("Localizable", "slideshow.slide8.title", fallback: "Hit the Play Button")
    }
    internal enum Slide9 {
      /// Now, you can browse your favorite web content and look for features that your detection model might recognize.
      internal static let description = L10n.tr("Localizable", "slideshow.slide9.description", fallback: "Now, you can browse your favorite web content and look for features that your detection model might recognize.")
      /// Annotation
      internal static let title = L10n.tr("Localizable", "slideshow.slide9.title", fallback: "Annotation")
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
