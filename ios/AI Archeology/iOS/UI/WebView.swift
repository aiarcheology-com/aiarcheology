//
//  WebView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 22.09.23.
//
//
//import SwiftUI
//import WebKit

//struct WebView: UIViewRepresentable {
//    @Binding var urlString: String
//    @Binding var isLoading: Bool
//
//    func makeUIView(context: Context) -> WKWebView  {
//        let wkwebView = WKWebView()
//        wkwebView.navigationDelegate = context.coordinator
//        return wkwebView
//    }
//
//    func updateUIView(_ uiView: WKWebView, context: Context) {
//        guard let url = URL(string: urlString) else { return }
//        uiView.load(URLRequest(url: url))
//    }
//
//    class Coordinator: NSObject, WKNavigationDelegate {
//        var parent: WebView
//        init(_ parent: WebView) {
//            self.parent = parent
//        }
//        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
//            parent.isLoading = true
//        }
//        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
//            parent.isLoading = false
//        }
//    }
//
//    func makeCoordinator() -> Coordinator {
//        Coordinator(self)
//    }
//}

//
//  AntWebView.swift
//
//
//  Created by HyunseokShim on 2023/07/12.
//

import Foundation
import SwiftUI
import WebKit
import Combine

extension WKWebView {
    func snapshotWebView(completion: @escaping (UIImage?) -> Void) {
        takeSnapshot(with: nil) { image, error in
            guard let image = image, error == nil else {
                completion(nil)
                return
            }
            completion(image)
        }
    }
}


@available(iOS 13, *)
public struct AntWebView: UIViewRepresentable {
    var urlString: String
//    var shouldCapture: Bool
    var loadStatusChanged: ((Bool, Error?) -> Void)? = nil
    var capturedImageChanged: ((UIImage) -> Void)? = nil
    var webView: WKWebView?

    public init(_ urlString: String,
//                shouldCapture: Bool,
                capturedImageChanged: ((UIImage) -> Void)? = nil,
                loadStatusChanged: ((Bool, Error?) -> Void)? = nil
    ) {
        self.urlString = urlString
        self.loadStatusChanged = loadStatusChanged
        self.capturedImageChanged = capturedImageChanged
//        self.shouldCapture = shouldCapture
    }

    public func makeCoordinator() -> AntWebView.Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> WKWebView {
        guard let url = URL(string: urlString)
        else {
            return WKWebView()
        }

        let webView = WKWebView(frame: CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1))
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator

        DispatchQueue.main.async {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    public func updateUIView(
        _ uiView: WKWebView,
        context: UIViewRepresentableContext<AntWebView>
    ) {
//        guard shouldCapture.not else {
//            uiView.takeSnapshot(with: nil, completionHandler: { image, error in
//                if let image = image {
//                    self.capturedImageChanged?(image)
//                }
//            })
//            return
//        }


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
        let parent: AntWebView
        var lastContentOffsetY: CGFloat = 0
        init(_ parent: AntWebView) {
            self.parent = parent
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.loadStatusChanged?(true, nil)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loadStatusChanged?(false, nil)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loadStatusChanged?(false, error)
        }
    }
}

