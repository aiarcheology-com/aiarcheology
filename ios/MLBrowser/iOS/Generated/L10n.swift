// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
internal enum L10n {
  internal enum About {
    /// Copyright © 2023 by Vladimír Slavík, AI Archeology
    internal static let copyright = L10n.tr("Localizable", "about.copyright", fallback: "Copyright © 2023 by Vladimír Slavík, AI Archeology")
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
    /// About
    internal static let about = L10n.tr("Localizable", "settings.about", fallback: "About")
    /// Default Page
    internal static let defaultPage = L10n.tr("Localizable", "settings.defaultPage", fallback: "Default Page")
    /// Delete Cache
    internal static let deleteCache = L10n.tr("Localizable", "settings.deleteCache", fallback: "Delete Cache")
    /// Frequency
    internal static let frequency = L10n.tr("Localizable", "settings.frequency", fallback: "Frequency")
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
    /// Settings
    internal static let title = L10n.tr("Localizable", "settings.title", fallback: "Settings")
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
