/*
See the License.txt file for this sample’s licensing information.
*/

import SwiftUI

struct ItemG: Identifiable {

    let id = UUID()
    let url: URL

}

extension ItemG: Equatable {
    static func == (lhs: ItemG, rhs: ItemG) -> Bool {
        return lhs.id == rhs.id && lhs.id == rhs.id
    }
}
