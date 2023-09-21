/*
See the License.txt file for this sample’s licensing information.
*/

import SwiftUI

struct DetailView: View {
    let item: ItemG

    var body: some View {
        AsyncImage(url: item.url) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            ProgressView()
        }
    }
}

struct ImageView_Previews: PreviewProvider {
    static var previews: some View {
        if let url = Bundle.main.url(forResource: "mushy1", withExtension: "jpg") {
            DetailView(item: ItemG(url: url))
        }
    }
}
