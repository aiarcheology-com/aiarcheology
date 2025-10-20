//
//  WebView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 22.09.23.
//
//

import Foundation
import SwiftUI
import WebKit
import Combine
import Vision
import OSLog

@available(iOS 13, *)
public struct MLWebView: UIViewRepresentable, WebViewRenderable, Equatable {
	@EnvironmentObject var webViewRenderer: WebViewRenderer
    var urlString: String
    var loadStatusChanged: ((Bool, Error?) -> Void)? = nil
	var lastPage: ((URL) -> Void)? = nil

	public init(_ urlString: String, lastPage: ((URL) -> Void)? = nil,
                loadStatusChanged: ((Bool, Error?) -> Void)? = nil
    ) {
        self.urlString = urlString
        self.loadStatusChanged = loadStatusChanged
		self.lastPage = lastPage
    }

    public func makeCoordinator() -> Self.Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> WKWebView {
        guard let url = URL(string: urlString)
        else {
			let webView = WKWebView()
			webViewRenderer.webView = webView
            return webView
        }

		let webView = WKWebView(frame: .point)
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator

        DispatchQueue.main.async {
			webView.load(URLRequest(url: url))
        }
		webViewRenderer.webView = webView
        return webView
    }

    public func updateUIView(
        _ uiView: WKWebView,
        context: UIViewRepresentableContext<Self>
    ) {
        func load(_ urlString: String) {
            guard let url = URL(string: urlString.withHTTPS) else { return }
            DispatchQueue.main.async {
				uiView.load(URLRequest(url: url))
            }
        }

        switch urlString.browserInputType {
        case .searchTerm:
            load(urlString.search(using: .google))
        case .url:
            load(urlString)
        case .unusable:
            return
        }
    }


    func onLoadStatusChanged(perform: ((Bool, Error?) -> Void)?) -> some View {
        var copy = self
        copy.loadStatusChanged = perform
        return copy
    }

    public class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        let parent: MLWebView
		var lastContentOffsetY: CGFloat = 0

        init(_ parent: MLWebView) {
            self.parent = parent
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.loadStatusChanged?(true, nil)
        }

		public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.loadStatusChanged?(false, nil)

			guard let url = webView.url, let domain = url.host else {
				return
			}

			func removeJSObjects_agsCuzkCz() {
				let jsRemoveButton = "document.querySelector('.esri-component.esri-compass.esri-widget').remove();"
				webView.evaluateJavaScript(jsRemoveButton) { (result, error) in
					if let error = error {
						Logger.ui.debug("Error removing compass button via JavaScript: \(error.localizedDescription, privacy: .public)")
					}
				}
			}
			switch domain {
			case "ags.cuzk.cz":
				removeJSObjects_agsCuzkCz()
			default:
				break
			}

			parent.lastPage?(url)
		}

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loadStatusChanged?(false, error)
        }
    }

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.urlString == rhs.urlString
	}
}
