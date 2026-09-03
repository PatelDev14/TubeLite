import UIKit
import Foundation

class PlaylistViewController: UITableViewController {
    /// Passes back the full item list + the index the user tapped, so the
    /// caller can build an autoplay queue instead of just loading one video.
    var onSelectFromQueue: (([PlaylistItem], Int) -> Void)?

    private var playlists: [Playlist] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismiss_))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addPlaylist))
        tableView.register(PlaylistCoverCell.self, forCellReuseIdentifier: "cover")
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 76
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "cover", for: indexPath) as! PlaylistCoverCell
        cell.configure(with: playlists[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let pl = playlists[indexPath.row]
        let detail = PlaylistDetailViewController(playlistID: pl.id)
        detail.onSelectFromQueue = { [weak self] items, index in
            self?.dismiss(animated: true) { self?.onSelectFromQueue?(items, index) }
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

// MARK: - Cover cell: rounded thumbnail, title, count, chevron
class PlaylistCoverCell: UITableViewCell {
    private let cover = UIImageView()
    private let icon = UIImageView(image: UIImage(systemName: "music.note.list"))
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private var task: URLSessionDataTask?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        cover.layer.cornerRadius = 10
        cover.clipsToBounds = true
        cover.contentMode = .scaleAspectFill
        cover.backgroundColor = UIColor(red: 0.22, green: 0.06, blue: 0.06, alpha: 1)

        icon.tintColor = UIColor.white.withAlphaComponent(0.35)
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: cover.centerYAnchor)
        ])

        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        countLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        countLabel.font = .systemFont(ofSize: 13, weight: .regular)

        let textStack = UIStackView(arrangedSubviews: [nameLabel, countLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor.white.withAlphaComponent(0.3)

        let row = UIStackView(arrangedSubviews: [cover, textStack, chevron])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            cover.widthAnchor.constraint(equalToConstant: 60),
            cover.heightAnchor.constraint(equalToConstant: 60),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with playlist: Playlist) {
        nameLabel.text = playlist.name
        countLabel.text = "\(playlist.items.count) video\(playlist.items.count == 1 ? "" : "s")"
        cover.image = nil
        icon.isHidden = playlist.items.first?.thumb != nil
        task?.cancel()
        if let thumbStr = playlist.items.first?.thumb, let url = URL(string: thumbStr) {
            task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async { self?.cover.image = img }
            }
            task?.resume()
        }
    }
}

// MARK: - Detail view: videos inside one playlist, with Play All
class PlaylistDetailViewController: UITableViewController {
    var onSelectFromQueue: (([PlaylistItem], Int) -> Void)?
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
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        title = PlaylistManager.shared.playlists.first(where: { $0.id == playlistID })?.name ?? "Playlist"
        tableView.register(VideoRowCell.self, forCellReuseIdentifier: "video")
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 84
        tableView.tableHeaderView = makeHeader()
        reload()
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 52))
        let btn = UIButton(type: .system)
        btn.setTitle("▶  Play All", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        btn.backgroundColor = UIColor(red: 0.85, green: 0.08, blue: 0.08, alpha: 1)
        btn.layer.cornerRadius = 10
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(playAll), for: .touchUpInside)
        header.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            btn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            btn.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            btn.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
            btn.heightAnchor.constraint(equalToConstant: 40)
        ])
        return header
    }

    @objc private func playAll() {
        guard !items.isEmpty else { return }
        onSelectFromQueue?(items, 0)
    }

    func reload() {
        items = PlaylistManager.shared.playlists.first(where: { $0.id == playlistID })?.items ?? []
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "video", for: indexPath) as! VideoRowCell
        cell.configure(with: items[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelectFromQueue?(items, indexPath.row)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            PlaylistManager.shared.deleteItem(playlistID: playlistID, itemIndex: indexPath.row)
            items.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
    }
}

// MARK: - Video row with thumbnail
class VideoRowCell: UITableViewCell {
    private let thumb = UIImageView()
    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private var task: URLSessionDataTask?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        thumb.layer.cornerRadius = 8
        thumb.clipsToBounds = true
        thumb.contentMode = .scaleAspectFill
        thumb.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.numberOfLines = 2

        dateLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        dateLabel.font = .systemFont(ofSize: 12, weight: .regular)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, dateLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let row = UIStackView(arrangedSubviews: [thumb, textStack])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 112),
            thumb.heightAnchor.constraint(equalToConstant: 64),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: PlaylistItem) {
        titleLabel.text = item.title
        dateLabel.text = item.savedAt.formatted(date: .abbreviated, time: .shortened)
        thumb.image = nil
        task?.cancel()
        if let thumbStr = item.thumb, let url = URL(string: thumbStr) {
            task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async { self?.thumb.image = img }
            }
            task?.resume()
        }
    }
}
