import Foundation
import AppKit

@MainActor
final class PlaylistManager: ObservableObject {

    @Published var tracks: [URL] = []
    @Published var currentIndex: Int = 0
    @Published var searchQuery: String = "" { didSet { applyFilter() } }

    enum Order { case alpha, shuffle }
    var order: Order = .alpha { didSet { sort() } }

    private let audioExts = Set(["mp3","m4a","aac","wav","flac","ogg","aiff","alac"])

    var currentTrack: URL? { tracks.isEmpty ? nil : tracks[currentIndex] }

    var filteredTracks: [URL] {
        searchQuery.isEmpty ? tracks :
        tracks.filter { $0.deletingPathExtension().lastPathComponent
                           .localizedCaseInsensitiveContains(searchQuery) }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }

        tracks = items.filter { audioExts.contains($0.pathExtension.lowercased()) }
        sort()
        currentIndex = 0
    }

    @discardableResult
    func next() -> URL? {
        guard !tracks.isEmpty else { return nil }
        currentIndex = (currentIndex + 1) % tracks.count
        return tracks[currentIndex]
    }

    @discardableResult
    func prev() -> URL? {
        guard !tracks.isEmpty else { return nil }
        currentIndex = (currentIndex - 1 + tracks.count) % tracks.count
        return tracks[currentIndex]
    }

    func select(index: Int) -> URL? {
        guard index >= 0, index < tracks.count else { return nil }
        currentIndex = index
        return tracks[index]
    }

    private func sort() {
        switch order {
        case .alpha:   tracks.sort { $0.lastPathComponent < $1.lastPathComponent }
        case .shuffle: tracks.shuffle()
        }
    }

    private func applyFilter() { objectWillChange.send() }
}
