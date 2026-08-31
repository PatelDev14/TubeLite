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

    func deletePlaylist(id: String) {
        playlists = playlists.filter { $0.id != id }
    }

    /// Saves a video into a specific playlist (defaults to "Watch Later")
    func save(title: String, url: String, thumb: String? = nil, toPlaylist playlistID: String? = nil) {
        var current = playlists
        let targetID = playlistID ?? defaultPlaylistID
        guard let idx = current.firstIndex(where: { $0.id == targetID }) else { return }
        current[idx].items.removeAll { $0.url == url }
        current[idx].items.insert(PlaylistItem(title: title, url: url, thumb: thumb, savedAt: Date()), at: 0)
        playlists = current
    }

    func deleteItem(playlistID: String, itemIndex: Int) {
        var current = playlists
        guard let idx = current.firstIndex(where: { $0.id == playlistID }) else { return }
        current[idx].items.remove(at: itemIndex)
        playlists = current
    }
}
