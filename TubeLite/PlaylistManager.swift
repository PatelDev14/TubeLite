import Foundation

struct PlaylistItem: Codable, Equatable {
    let title: String
    let url: String
    let thumb: String?
    let savedAt: Date
}

struct Playlist: Codable {
    let id: String
    var name: String
    var items: [PlaylistItem]
}

class PlaylistManager {
    static let shared = PlaylistManager()
    private let key = "yt_playlists_v2"
    private let defaultPlaylistID = "default"

    var playlists: [Playlist] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([Playlist].self, from: data),
                  !decoded.isEmpty
            else {
                return [Playlist(id: defaultPlaylistID, name: "Watch Later", items: [])]
            }
            return decoded
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    func createPlaylist(name: String) {
        var current = playlists
        current.append(Playlist(id: UUID().uuidString, name: name, items: []))
        playlists = current
    }

    func renamePlaylist(id: String, to newName: String) {
        var current = playlists
        guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
        current[idx].name = newName
        playlists = current
    }

    func deletePlaylist(id: String) {
        playlists = playlists.filter { $0.id != id }
    }

    /// Saves a video into a specific playlist (defaults to "Watch Later").
    /// Dedupes by VIDEO ID rather than full URL, since YouTube URLs often
    /// carry extra params (timestamp, list, index) that change between
    /// visits to the "same" video — matching on the full URL let
    /// duplicates slip through.
    func save(title: String, url: String, thumb: String? = nil, toPlaylist playlistID: String? = nil) {
        var current = playlists
        let targetID = playlistID ?? defaultPlaylistID
        guard let idx = current.firstIndex(where: { $0.id == targetID }) else { return }
        let newID = Self.extractVideoID(from: url)
        current[idx].items.removeAll { Self.extractVideoID(from: $0.url) == newID }
        current[idx].items.insert(PlaylistItem(title: title, url: url, thumb: thumb, savedAt: Date()), at: 0)
        playlists = current
    }

    func deleteItem(playlistID: String, itemIndex: Int) {
        var current = playlists
        guard let idx = current.firstIndex(where: { $0.id == playlistID }) else { return }
        current[idx].items.remove(at: itemIndex)
        playlists = current
    }

    func isSaved(url: String) -> Bool {
        let vid = Self.extractVideoID(from: url)
        return playlists.contains { pl in pl.items.contains { Self.extractVideoID(from: $0.url) == vid } }
    }

    static func extractVideoID(from url: String) -> String {
        if let range = url.range(of: "v="),
           let ampRange = url.range(of: "&", range: range.upperBound..<url.endIndex) {
            return String(url[range.upperBound..<ampRange.lowerBound])
        } else if let range = url.range(of: "v=") {
            return String(url[range.upperBound...])
        } else if let range = url.range(of: "/shorts/") {
            let rest = url[range.upperBound...]
            return String(rest.prefix(while: { $0 != "?" && $0 != "/" }))
        }
        return url
    }
}

