//
//  VisitTrail.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import Foundation
import CoreData
import Combine

extension WebVisit: CoreDataManageable {
}

extension WebVisit: CoreDataManagableWithState {
	func validationReport() -> CoreDataManagableValidationReport {
		guard lifeCycle == .draft || lifeCycle == .ready else { return .init(issues: nil) }

		var issues: [CoreDataManagableValidationIssue] = []

		if page.isNil {
			issues.append(.init(key: "url", message: "Visit page URL is nil."))
		}

		if creationDate_.isNil {
			issues.append(.init(key: "creationDate", message: "Creation date is nil."))
		}

		return .init(issues: issues)
	}
}

/// Persists the browsing trail: every URL the web view settles on — including the
/// same-document History-API changes map applications make on every pan/zoom — so the
/// location sheet's per-site detail can replay how the user moved around a page.
@MainActor
final class VisitTrailRecorder {
	/// Global cap; the oldest visits are pruned first. Generous enough for many map
	/// sessions while keeping the table and the detail list bounded.
	nonisolated static let maxVisits = 1000

	private let dataController: DataController
	private var subscription: AnyCancellable?

	init(browserState: BrowserState, dataController: DataController) {
		self.dataController = dataController
		// Debounced: a continuous drag fires KVO per frame; recording after a 1 s
		// settle captures resting viewpoints — the points worth replaying.
		subscription = browserState.$currentURL
			.debounce(for: .seconds(1), scheduler: DispatchQueue.main)
			.removeDuplicates()
			.compactMap { $0 }
			.filter { $0.host != nil && ($0.scheme == "https" || $0.scheme == "http") }
			.sink { [weak self] url in
				self?.record(url)
			}
	}

	/// Internal (not private) so unit tests can exercise persistence without driving
	/// a real web view through the debounce.
	func record(_ url: URL) {
		dataController.performBackgroundTask { context in
			let visit: WebVisit = WebVisit.create(in: context)
			visit.creationDate_ = .now
			visit.page = url
			visit.host = url.host
			visit.transition(to: .draft)
			do {
				try visit.validateForInsert()
				visit.transition(to: .ready)
				try WebVisit.save(in: context)
			} catch {
				WebVisit.delete(visit, in: context)
				LoggingPolicy.error("Web visit validation/save failed", error: error, logger: .state)
				return
			}
			Self.prune(in: context)
		}
	}

	/// Deletes the oldest visits beyond `maxVisits`. Runs on the caller's context queue —
	/// nonisolated because it is called from background-context blocks and only touches
	/// the passed context.
	nonisolated static func prune(in context: NSManagedObjectContext) {
		let count = WebVisit.count(in: context)
		guard count > maxVisits else { return }

		let request = WebVisit.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \WebVisit.creationDate_, ascending: true)]
		request.fetchLimit = count - maxVisits
		do {
			let stale = try context.fetch(request)
			stale.forEach(context.delete)
			try WebVisit.save(in: context)
		} catch {
			LoggingPolicy.error("Pruning the visit trail failed", error: error, logger: .state)
		}
	}
}
