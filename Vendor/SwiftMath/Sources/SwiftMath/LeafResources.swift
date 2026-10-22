// Leaf packaging adaptation. Original SwiftMath source retains its MIT license.
import Foundation
extension Bundle {
    static let leafMathResources: Bundle = {
        if let url = Bundle.main.url(forResource: "SwiftMath_SwiftMath", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}
