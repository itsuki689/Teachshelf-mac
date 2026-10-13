import SwiftUI
import AppKit
import QuickLookUI
import QuickLookThumbnailing
import TeachshelfCore

@MainActor final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var item: URL?
    func show(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        item = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { item as NSURL? }
}

@MainActor final class ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 48 }
    func image(for url: URL) async -> NSImage? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 210, height: 280), scale: 2, representationTypes: .thumbnail)
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct CoverThumbnail: View {
    let material: MaterialRecord
    let url: URL?
    let color: Color
    @ViewState private var image: NSImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(color.gradient)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(8).frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TEACHSHELF").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(2)
                        Rectangle().fill(.white.opacity(0.5)).frame(height: 0.5)
                        Text(material.title).font(.system(size: 21, weight: .semibold, design: .serif)).lineLimit(5)
                        Spacer(minLength: 4)
                        Text(material.category).font(.caption)
                        Text(material.fileExtension).font(.system(size: 9, weight: .medium)).tracking(2)
                    }.foregroundStyle(.white.opacity(0.95)).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Rectangle().fill(.black.opacity(0.12)).frame(width: 5); Spacer() }
            }.clipShape(RoundedRectangle(cornerRadius: 5))
        }.task(id: "\(url?.path ?? "")-\(material.size)") {
            image = nil
            if let url {
                let loaded = await ThumbnailService.shared.image(for: url)
                if !Task.isCancelled { image = loaded }
            }
        }
    }
}
