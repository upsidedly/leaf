// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Leaf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Leaf", targets: ["Leaf"]), .executable(name: "LeafChecks", targets: ["LeafChecks"])],
    dependencies: [.package(path: "Vendor/MarkdownEngine")],
    targets: [
        .target(name: "LeafCore"),
        .target(name: "LeafRender", resources: [.process("Resources")]),
        .executableTarget(name: "Leaf", dependencies: [
            "LeafCore", "LeafRender",
            .product(name: "MarkdownEngine", package: "MarkdownEngine"),
            .product(name: "MarkdownEngineCodeBlocks", package: "MarkdownEngine"),
            .product(name: "MarkdownEngineLatex", package: "MarkdownEngine")
        ]),
        .executableTarget(name: "LeafChecks", dependencies: ["LeafCore", "LeafRender"])
    ],
    swiftLanguageModes: [.v6]
)
