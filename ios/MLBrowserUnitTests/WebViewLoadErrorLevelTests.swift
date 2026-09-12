//
//  WebViewLoadErrorLevelTests.swift
//  AI ArcheologyTests
//
//  Tests for webViewLoadErrorLevel(for:) — the decision that downgrades benign
//  WebView load cancellations (NSURLErrorCancelled, -999) to .debug so they stop
//  being captured as Sentry errors, while genuine load failures keep logging at
//  .error (AIA-0296).
//

import XCTest
import UIKit
import WebKit
@testable import ML_Browser

final class WebViewLoadErrorLevelTests: XCTestCase {

    // MARK: - Benign cancellation -> .debug

    func testCancelled_IsDowngradedToDebug() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .debug)
    }

    func testURLErrorCancelled_BridgesToDebug() {
        // URLError(.cancelled) bridges to NSURLErrorDomain/-999.
        let error = URLError(.cancelled)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .debug)
    }

    // MARK: - Genuine failures -> .error

    func testNotConnectedToInternet_StaysError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }

    func testTimedOut_StaysError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }

    func testCannotFindHost_StaysError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }

    // MARK: - Domain guard

    func testCancelledCodeInOtherDomain_StaysError() {
        // -999 only counts in NSURLErrorDomain; the same code elsewhere is a real error.
        let error = NSError(domain: "SomeOtherDomain", code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }
}

@MainActor
final class WebViewInteractionLifecycleTests: XCTestCase {

    func testNavigationStart_InteractionWasActive_PublishesIdle() {
        var interactionChanges: [Bool] = []
        let renderer = WebSnapshotRenderer(adjustment: SnapAdjustment())
        let view = MLWebView(
            .initial,
            renderer: renderer,
            interactionStateChanged: { interactionChanges.append($0.isInteracting) }
        )
        let coordinator = view.makeCoordinator()

        coordinator.scrollViewWillBeginDragging(UIScrollView())
        XCTAssertEqual(interactionChanges, [true])

        coordinator.webView(WKWebView(), didStartProvisionalNavigation: nil)

        XCTAssertEqual(interactionChanges, [true, false])
    }

    func testNavigationStart_InteractionWasIdle_DoesNotPublishDuplicateIdle() {
        var interactionChanges: [Bool] = []
        let renderer = WebSnapshotRenderer(adjustment: SnapAdjustment())
        let view = MLWebView(
            .initial,
            renderer: renderer,
            interactionStateChanged: { interactionChanges.append($0.isInteracting) }
        )
        let coordinator = view.makeCoordinator()

        coordinator.webView(WKWebView(), didStartProvisionalNavigation: nil)

        XCTAssertTrue(interactionChanges.isEmpty)
    }
}

// MARK: - AIA-0827: the blank-page verdict

@MainActor
final class RenderedContentSummaryTests: XCTestCase {

	/// `[visible, text, refused, examined]`, as the page returns it.
	private func summary(visible: Int, text: Int, refused: Bool = false, examined: Int = 10) -> RenderedContentSummary? {
		RenderedContentSummary([visible, text, refused ? 1 : 0, examined])
	}

	/// The reported shape: an application shell whose scripts never ran. Its container divs are not
	/// counted by anything, and nothing it holds has a box.
	func testAShellThatRenderedNothing_IsBlank() {
		XCTAssertEqual(summary(visible: 0, text: 0)?.drewNothing, true)
	}

	/// Either kind of visible content, alone, is enough. Asserted one at a time: a verdict written
	/// with `||` where `&&` was meant passes every test that only supplies a full page.
	func testAnyVisibleContent_IsNotBlank() {
		XCTAssertEqual(summary(visible: 1, text: 0)?.drewNothing, false, "a rendered element is content")
		XCTAssertEqual(summary(visible: 0, text: 968)?.drewNothing, false, "text is content")
	}

	/// **A refusal is not an absence.** The first version of this treated an unanswerable selector as
	/// zero, so a page that refused every measurement was reported blank on the strength of a
	/// measurement that never happened — and every false positive here becomes a Sentry issue.
	func testARefusedMeasurementAbandonsTheVerdict() {
		XCTAssertEqual(
			summary(visible: 0, text: 0, refused: true)?.drewNothing, false,
			"a page that refused to be measured must not be reported as blank"
		)
		XCTAssertEqual(
			summary(visible: 0, text: -1, refused: true)?.drewNothing, false,
			"an unreadable body is not an empty one"
		)
	}

	/// The page is untrusted input: a malformed answer is no measurement, and must not be reported as
	/// a blank page.
	func testAMalformedAnswerIsRefusedRatherThanReported() {
		XCTAssertNil(RenderedContentSummary(nil))
		XCTAssertNil(RenderedContentSummary("blank"))
		XCTAssertNil(RenderedContentSummary([0, 0, 0]), "a short array is not a measurement")
		XCTAssertNil(RenderedContentSummary([0, 0, 0, "lots"]), "a non-numeric count is not a count")
	}

	/// A fractional answer is not a count. `intValue` alone truncates 0.5 to 0, which would read as
	/// an empty page — the comment claimed floats were refused while the code accepted them.
	func testAFractionalAnswerIsRefused() {
		XCTAssertNil(RenderedContentSummary([0.5, 0, 0, 4]), "0.5 elements is not a measurement")
		XCTAssertNil(RenderedContentSummary([0, 12.7, 0, 4]))
	}

	/// JavaScript numbers arrive as `NSNumber`, not `Int`, so the parse has to go through it.
	func testJavaScriptNumbersAreAccepted() {
		let bridged: [Any] = [NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 4)]
		XCTAssertEqual(RenderedContentSummary(bridged)?.drewNothing, true)
	}
}

// MARK: - AIA-0827: the diagnostics script the app ships

@MainActor
final class PageDiagnosticsInstallationTests: XCTestCase {

	/// Read from the app's own factory, for the reason `MapProbeInstallationTests` exists: AIA-0817
	/// shipped a script that only its own tests installed, and stayed green while doing nothing.
	func testPageDiagnosticsScript_IsInstalledByTheApp() {
		let scripts = MLWebView.makeUserContentController().userScripts
		XCTAssertTrue(
			scripts.contains { $0.source.contains("aiaPageDiagnostics") },
			"the page-error counter is not installed, so no page can ever report one"
		)
	}

	/// It must run before the page's own scripts, or the errors it exists to count have already been
	/// thrown, and in every frame, because a broken iframe is what leaves a shell looking blank.
	func testPageDiagnosticsScript_RunsAtDocumentStartInEveryFrame() {
		let script = MLWebView.makeUserContentController().userScripts
			.first { $0.source.contains("aiaPageDiagnostics") }
		XCTAssertEqual(script?.injectionTime, .atDocumentStart)
		XCTAssertEqual(script?.isForMainFrameOnly, false)
	}

	/// Nothing but a number may cross the bridge: an error message routinely carries a URL or a
	/// fragment of the page's own source, and this script runs on every page the user visits.
	func testPageDiagnosticsScript_SendsACountAndNeverAMessage() {
		let source = MLWebView.makeUserContentController().userScripts
			.first { $0.source.contains("aiaPageDiagnostics") }?.source ?? ""
		XCTAssertTrue(source.contains("postMessage(count)"), "the count is what is posted")
		// The listener takes NO parameter, which is the strongest form of this guarantee: there is no
		// event object in scope to read a message, a filename or a line out of.
		XCTAssertTrue(
			source.contains("addEventListener('error', function () {"),
			"the error listener must not even bind the event it is handed"
		)
		XCTAssertFalse(source.contains("e.message"), "an error's message must never leave the page")
		XCTAssertFalse(source.contains("event.message"), "an error's message must never leave the page")
		XCTAssertFalse(source.contains("location"), "no address may leave the page")
	}
}

// MARK: - The site name has to survive redaction

/// Naming the site is only useful if the name arrives. `LogRedactor` strips URLs from everything on
/// its way to Sentry — which is *why* the host is added as a bare token — so these pin that the
/// token survives while the address it came from does not.
final class SiteNameRedactionTests: XCTestCase {

	func testABareHostSurvivesRedaction() {
		let redacted = LogRedactor.redactingSensitiveData("Web page rendered nothing [site: mapy.geoportal.gov.pl]")
		XCTAssertTrue(
			redacted.contains("mapy.geoportal.gov.pl"),
			"the site name was stripped, so every Sentry issue would read the same"
		)
	}

	/// The other half, and the reason the host is added at all: the full address in the same message
	/// is redacted, viewport and all. Without the bare token there would be nothing left to identify
	/// the site by.
	func testTheAddressInTheSameMessageIsStillRedacted() {
		let message = "WebView loading error [site: ags.cuzk.cz]: could not load "
			+ "https://ags.cuzk.cz/av/?extent=-831002.32,-1032569.72,-826473.74,-1029973.39"
		let redacted = LogRedactor.redactingSensitiveData(message)

		XCTAssertTrue(redacted.contains("[site: ags.cuzk.cz]"), "the site name must survive")
		XCTAssertFalse(redacted.contains("extent="), "the viewport must not travel")
		XCTAssertFalse(redacted.contains("https://"), "the address must not travel")
	}

	/// A host with a port survives the redactor as text. Noted because `URL.host` does NOT include
	/// the port, so what the app actually puts in a message is the bare host — this pins the
	/// redactor, not the caller.
	func testAHostWithAPortSurvivesRedaction() {
		let redacted = LogRedactor.redactingSensitiveData("Web page rendered nothing [site: localhost:8080]")
		XCTAssertTrue(redacted.contains("localhost:8080"), redacted)
	}
}

// MARK: - The page a failure is about

/// The address reaches the crash service as structured context rather than as message text, because
/// message text is redacted on the way out. These pin what that context contains.
final class PageContextTests: XCTestCase {

	func testTheWholeAddressTravels() {
		let url = URL(string: "https://ags.cuzk.cz/av/?extent=-831002.32,-1032569.72&zvd=dmr5g#top")
		let context = LoggingPolicy.pageContext(url)

		XCTAssertEqual(context["page_host"], "ags.cuzk.cz")
		XCTAssertEqual(
			context["page_url"],
			"https://ags.cuzk.cz/av/?extent=-831002.32,-1032569.72&zvd=dmr5g#top",
			"the query and fragment are what make a failure reproducible"
		)
	}

	/// The host is carried separately from the address on purpose: it is short and low-cardinality,
	/// so it can be an indexed tag that filters the issue stream, while the address cannot.
	func testTheHostIsCarriedSeparatelyFromTheAddress() {
		let context = LoggingPolicy.pageContext(URL(string: "https://mapy.geoportal.gov.pl/imap/Imgp_2.html"))
		XCTAssertEqual(context["page_host"], "mapy.geoportal.gov.pl")
		XCTAssertNotEqual(context["page_url"], context["page_host"])
	}

	/// A password in a crash report is a leaked password, whatever was decided about addresses.
	func testCredentialsAreStrippedEvenThoughTheAddressIsNot() {
		let context = LoggingPolicy.pageContext(URL(string: "https://user:hunter2@portal.example.org/view?x=1"))

		let address = context["page_url"] ?? ""
		XCTAssertFalse(address.contains("hunter2"), "a password must never reach the crash service")
		XCTAssertFalse(address.contains("user@"), "nor the account it belongs to")
		XCTAssertTrue(address.contains("portal.example.org/view?x=1"), "the address itself still travels")
		XCTAssertEqual(context["page_host"], "portal.example.org")
	}

	/// Percent-encoded credentials cannot be decoded, so `URLComponents.user` reads nil while the
	/// encoded form is present and would have travelled verbatim. Found in review.
	func testPercentEncodedCredentialsAreAlsoStripped() {
		let context = LoggingPolicy.pageContext(URL(string: "https://%FF:%FE@portal.example.org/view"))
		let address = context["page_url"] ?? ""

		XCTAssertFalse(address.contains("%FE"), "an undecodable password is still a password")
		XCTAssertFalse(address.contains("%FF"), "and an undecodable user is still an account")
		XCTAssertFalse(address.contains("@"), address)
	}

	/// A relative URL sees no credentials in its own components, while the string that would travel
	/// includes its base's. Resolving first is what makes the check apply to what is actually sent.
	func testCredentialsInABaseURLAreStripped() {
		let base = URL(string: "https://user:hunter2@portal.example.org/")
		let context = LoggingPolicy.pageContext(URL(string: "view?x=1", relativeTo: base))
		let address = context["page_url"] ?? ""

		XCTAssertFalse(address.contains("hunter2"), address)
		XCTAssertTrue(address.contains("portal.example.org/view?x=1"), address)
	}

	/// A `data:` URL **is** the document, and a `file:` URL is a path on the device. Neither is a
	/// site anyone can open, so neither travels — while the failure is still reported.
	func testOnlyWebAddressesTravel() {
		XCTAssertNil(
			LoggingPolicy.pageContext(URL(string: "data:text/html,<h1>secret</h1>"))["page_url"],
			"a data URL would ship the page's own contents"
		)
		XCTAssertNil(
			LoggingPolicy.pageContext(URL(string: "file:///Users/someone/Documents/private.html"))["page_url"],
			"a file URL is a path on this device"
		)
	}

	func testNoPageMeansNoContext() {
		XCTAssertTrue(LoggingPolicy.pageContext(nil).isEmpty)
	}

	/// An address with no host must not invent one — and `about:blank` is not a web address, so it
	/// carries nothing at all. The failure is still reported; only its subject is omitted.
	func testAnAddressWithNoHostCarriesNothing() {
		let context = LoggingPolicy.pageContext(URL(string: "about:blank"))
		XCTAssertNil(context["page_host"])
		XCTAssertNil(context["page_url"])
	}
}
