//
//  FilePickerViewController.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 23/04/2025.
//

import UIKit

enum FilePickerFolderOption {
    case exportFolder
    case importFolder
}

class FilePickerViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    struct FileItem {
        let name: String
        let url: URL
        let size: Int64
        let modified: Date
    }
    
    private let headerLabel: UILabel = {
            let label = UILabel()
            label.text = "Select a File"
            label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

    var files: [FileItem] = []
    var onFileSelected: ((URL) -> Void)?
    var folderOption: FilePickerFolderOption = .exportFolder
    
    private let tableView = UITableView()

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemBackground
        setupHeader()
        setupTableView()
        
        title = "Exported Files"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "FileCell")
        tableView.rowHeight = 72
        tableView.separatorStyle = .singleLine
        loadFiles()
    }
    
    private func setupHeader() {
        view.addSubview(headerLabel)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            headerLabel.heightAnchor.constraint(equalToConstant: 28)
        ])
        
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.bottomAnchor.constraint(equalTo: headerLabel.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadFiles() {
        var folder: URL
        if folderOption == .exportFolder {
            folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exports")
        }
        else {
            folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Imports")
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles)

            self.files = urls.compactMap { url in
                guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = attrs.fileSize,
                      let modified = attrs.contentModificationDate else { return nil }
                return FileItem(name: url.lastPathComponent, url: url, size: Int64(size), modified: modified)
            }.sorted(by: { $0.modified > $1.modified }) // Most recent first

            tableView.reloadData()
        } catch {
            print("Error loading files: \(error)")
        }
    }

    // MARK: - Table View

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = files[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "FileCell", for: indexPath)

        var config = cell.defaultContentConfiguration()
        config.text = item.name
        config.secondaryText = "\(formatFileSize(item.size)) • \(formatDate(item.modified))"
        config.image = iconForFile(url: item.url)
        config.imageProperties.cornerRadius = 4

        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selectedURL = files[indexPath.row].url
        dismiss(animated: true) {
            self.onFileSelected?(selectedURL)
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 70.0
    }

    // MARK: - Helpers

    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func iconForFile(url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "jpg", "jpeg", "png", "heic":
            return UIImage(systemName: "photo")
        case "pdf":
            return UIImage(systemName: "doc.richtext")
        case "txt":
            return UIImage(systemName: "doc.plaintext")
        case "zip":
            return UIImage(systemName: "archivebox")
        default:
            return UIImage(systemName: "doc")
        }
    }
}
