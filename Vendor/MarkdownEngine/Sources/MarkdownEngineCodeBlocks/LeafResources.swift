// Leaf packaging adaptation, Apache-2.0.
import Foundation
extension Bundle {
    static let leafCodeResources: Bundle = {
        if let url = Bundle.main.url(forResource: "MarkdownEngine_MarkdownEngineCodeBlocks", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}
