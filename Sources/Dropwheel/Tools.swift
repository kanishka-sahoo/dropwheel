import Foundation

/// The advanced file tools shown on the Shift+Option wheel.
enum Tool: String, CaseIterable {
    case compress, removeMetadata, editImage, frameImage, cropImage, redactImage, annotateImage, createPDF, createCollage
    case normalizeAudio, trimAudio, audioChannels, audioToVideo, redactAudio
    case muteVideo, trimVideo, cropVideo, changeVideoSpeed, joinVideos, videoSnapshots, splitVideo, redactVideo
    case splitPDF, organizePDF, mergePDF
    case extractArchive

    /// Short uppercase label drawn on the wheel.
    var title: String {
        switch self {
        case .compress: return "COMPRESS"
        case .removeMetadata: return "METADATA"
        case .editImage: return "EDIT"
        case .frameImage: return "ADD BG"
        case .cropImage, .cropVideo: return "CROP"
        case .redactImage, .redactVideo: return "REDACT"
        case .annotateImage: return "ANNOTATE"
        case .createPDF: return "CREATE PDF"
        case .createCollage: return "COLLAGE"
        case .normalizeAudio: return "NORMALIZE"
        case .trimAudio, .trimVideo: return "TRIM"
        case .audioChannels: return "CHANNELS"
        case .audioToVideo: return "VISUALIZE"
        case .redactAudio: return "BLEEP"
        case .muteVideo: return "MUTE"
        case .changeVideoSpeed: return "SPEED"
        case .joinVideos: return "JOIN"
        case .videoSnapshots: return "SNAPSHOT"
        case .splitVideo, .splitPDF: return "SPLIT"
        case .organizePDF: return "ORGANIZE"
        case .mergePDF: return "MERGE PDF"
        case .extractArchive: return "EXTRACT"
        }
    }

    var name: String {
        switch self {
        case .compress: return "Compress"
        case .removeMetadata: return "Metadata"
        case .editImage: return "Edit Photo"
        case .frameImage: return "Add Background"
        case .cropImage: return "Crop Image"
        case .redactImage: return "Redact Photo"
        case .annotateImage: return "Annotate Photo"
        case .createPDF: return "Create PDF"
        case .createCollage: return "Create Collage"
        case .normalizeAudio: return "Normalize Volume"
        case .trimAudio: return "Trim Audio"
        case .audioChannels: return "Convert Audio Channels"
        case .audioToVideo: return "Audio Visualizer"
        case .redactAudio: return "Bleep Audio"
        case .muteVideo: return "Remove Audio"
        case .trimVideo: return "Trim Video"
        case .cropVideo: return "Crop Video"
        case .changeVideoSpeed: return "Change Video Speed"
        case .joinVideos: return "Join Videos"
        case .videoSnapshots: return "Video Snapshots"
        case .splitVideo: return "Split Video"
        case .redactVideo: return "Redact Video"
        case .splitPDF: return "Split PDF"
        case .organizePDF: return "Organize PDF"
        case .mergePDF: return "Merge PDFs"
        case .extractArchive: return "Extract Archive"
        }
    }

    /// SF Symbol drawn above the label on the wheel.
    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: return "tag"
        case .editImage: return "slider.horizontal.3"
        case .frameImage: return "photo.artframe"
        case .cropImage, .cropVideo: return "crop"
        case .redactImage, .redactVideo: return "eye.slash"
        case .annotateImage: return "pencil.tip.crop.circle"
        case .createPDF: return "doc.badge.plus"
        case .createCollage: return "rectangle.3.group"
        case .normalizeAudio, .audioToVideo: return "waveform"
        case .trimAudio, .trimVideo: return "scissors"
        case .audioChannels: return "hifispeaker.2"
        case .redactAudio: return "waveform.badge.minus"
        case .muteVideo: return "speaker.slash.fill"
        case .changeVideoSpeed: return "speedometer"
        case .joinVideos: return "film.stack"
        case .videoSnapshots: return "camera"
        case .splitVideo: return "film"
        case .splitPDF: return "rectangle.split.2x1"
        case .organizePDF: return "square.grid.2x2"
        case .mergePDF: return "doc.on.doc"
        case .extractArchive: return "archivebox"
        }
    }

    /// Tools that consume the whole selection as one input.
    var takesMultipleFiles: Bool {
        [.createPDF, .mergePDF, .joinVideos, .createCollage].contains(self)
    }

    /// Tools that can be applied to each file of a selection without a UI.
    var supportsBatch: Bool {
        [.compress, .normalizeAudio, .muteVideo, .splitPDF, .extractArchive, .createPDF, .mergePDF, .joinVideos, .createCollage].contains(self)
    }

    private static func candidates(for kind: String, count: Int) -> [Tool] {
        let multi = count > 1
        switch kind {
        case "jpg", "png", "webp", "heic", "tiff", "avif", "bmp":
            return multi ? [.compress, .removeMetadata, .createPDF, .createCollage]
                         : [.compress, .removeMetadata, .editImage, .frameImage, .cropImage, .redactImage, .annotateImage]
        case "svg":
            return multi ? [.createPDF, .createCollage] : []
        case _ where Formats.audio.contains(kind):
            return [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio]
        case _ where Formats.video.contains(kind):
            return multi ? [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos]
                         : [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots, .splitVideo, .redactVideo]
        case "gif": return [.removeMetadata]
        case "pdf":
            return multi ? [.compress, .removeMetadata, .splitPDF, .mergePDF] : [.compress, .removeMetadata, .splitPDF, .organizePDF]
        case _ where Formats.archives.contains(kind): return [.extractArchive]
        default: return []
        }
    }

    /// Tools offered for a selection. Multi-file selections only get batch-capable tools shared by all files.
    static func tools(for urls: [URL]) -> [Tool] {
        guard let first = urls.first else { return [] }
        var result = candidates(for: Formats.kind(of: first), count: urls.count)
        if urls.count > 1 {
            result = result.filter { $0.supportsBatch }
            for url in urls.dropFirst() {
                let set = Set(candidates(for: Formats.kind(of: url), count: urls.count))
                result = result.filter { set.contains($0) }
            }
        }
        return result
    }
}
