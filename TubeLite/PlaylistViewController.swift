import UIKit
import Foundation

class PlaylistViewController: UITableViewController {
    var onSelect: ((PlaylistItem) -> Void)?
    private var playlists: [Playlist] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismiss_))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addPlaylist))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.1)
        reload()
    }

    func reload() {
        playlists = PlaylistManager.shared.playlists
        tableView.reloadData()
    }

    @objc func dismiss_() { dismiss(animated: true) }

    @objc func addPlaylist() {
        let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Playlist name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            PlaylistManager.shared.createPlaylist(name: name)
            self?.reload()
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        playlists.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let pl = playlists[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = pl.name
        content.textProperties.color = .white
        content.secondaryText = "\(pl.items.count) video\(pl.items.count == 1 ? "" : "s")"
        content.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.5)
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let pl = playlists[indexPath.row]
        let detail = PlaylistDetailViewController(playlistID: pl.id)
        detail.onSelect = { [weak self] item in
            self?.dismiss(animated: true) { self?.onSelect?(item) }
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return playlists[indexPath.row].id == "default" ? .none : .delete
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, playlists[indexPath.row].id != "default" else { return }
        PlaylistManager.shared.deletePlaylist(id: playlists[indexPath.row].id)
        reload()
    }
}

class PlaylistDetailViewController: UITableViewController {
    var onSelect: ((PlaylistItem) -> Void)?
    private let playlistID: String
    private var items: [PlaylistItem] = []

    init(playlistID: String) {
        self.playlistID = playlistID
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        title = PlaylistManager.shared.playlists.first(where: { $0.id == playlistID })?.name ?? "Playlist"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.backgroundColor = .clear
        reload()
    }

    func reload() {
        items = PlaylistManager.shared.playlists.first(where: { $0.id == playlistID })?.items ?? []
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = items[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.textProperties.color = .white
        content.textProperties.numberOfLines = 2
        content.secondaryText = item.savedAt.formatted(date: .abbreviated, time: .shortened)
        content.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.5)

        if let thumbStr = item.thumb, let url = URL(string: thumbStr) {
            content.imageProperties.maximumSize = CGSize(width: 100, height: 56)
            content.imageProperties.cornerRadius = 6
            cell.contentConfiguration = content
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    // Guard against cell reuse showing a stale image
                    guard tableView.indexPath(for: cell) == indexPath else { return }
                    var updated = content
                    updated.image = img
                    cell.contentConfiguration = updated
                }
            }.resume()
        } else {
            cell.contentConfiguration = content
        }

        cell.backgroundColor = .clear
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(items[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            PlaylistManager.shared.deleteItem(playlistID: playlistID, itemIndex: indexPath.row)
            items.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
    }
}
