import Foundation
import Combine

//class ViewModel: ObservableObject {
//
//    @Published var input = ""
//    private var cancellables = Set<AnyCancellable>()
//
//    init() {
//        configureCancellables()
//    }
//
//    private func configureCancellables() {
//        $input
//            .debounce(for: 1, scheduler: DispatchQueue.main)
//            .filter({ $0.count >= 3 })
//            .removeDuplicates()
//            .sink { value in
//                self.search(text: value)
//            }
//            .store(in: &cancellables)
//    }
//
//    private func search(text: String) {
//        print("*** Searching \(text) ***")
//    }
//}

class TextViewModel: ObservableObject {
    @Published var input: String = ""
    var cancellables: Set<AnyCancellable> = []
    @Published var debouncedInput: String = ""

    init() {
        $input
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.debouncedInput = $0 }
            .store(in: &cancellables)
    }
}
