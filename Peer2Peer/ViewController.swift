//
//  ViewController.swift
//  Peer2Peer
//
//  Created by Steve Wainwright on 06/05/2025.
//

import UIKit
import Photos
import AudioToolbox
import ZIPFoundation
import QuickLook
@preconcurrency import MultipeerConnectivity

let AVAILABLE_SOUND_FILE_NAME = "available"
let UNAVAILABLE_SOUND_FILE_NAME = "unavailable"

class ViewController: UIViewController, UINavigationControllerDelegate {

    @IBOutlet weak var toolbar: UIToolbar?
    @IBOutlet weak var photoBarButtonItem: UIBarButtonItem?
    @IBOutlet weak var cameraBarButtonItem: UIBarButtonItem?
    @IBOutlet weak var exportFileButtonItem: UIBarButtonItem?
    @IBOutlet weak var importFilesButtonItem: UIBarButtonItem?
    @IBOutlet var selectTransferFileButton: UIBarButtonItem?
    
    @IBOutlet weak var searchingForDevicesView: UIView?
    @IBOutlet weak var labelApplicationNameDescription: UILabel?
    @IBOutlet weak var devicesTable: UITableView?
    @IBOutlet weak var progressView: UIView?
    @IBOutlet weak var circularProgressView: KDCircularProgress?
    @IBOutlet weak var circularProgressButton: UIButton?
    @IBOutlet weak var circularProgressLabel: UILabel?
    @IBOutlet weak var backgroundImageHighlighted: UIImageView?
    @IBOutlet weak var noDevicesLabel: UILabel?
    @IBOutlet weak var myFileToTransferLabel: UILabel?
    @IBOutlet weak var myDeviceNameLabel: UILabel?
    @IBOutlet weak var statusLabel: UILabel?
   
    private let deviceHasCamera: Bool = UIImagePickerController.isSourceTypeAvailable(.camera)
    private var transferFileURL: URL?
    private var filesize: Int64 = 0
    private var fileContentType: String = "application/octet-stream"
    
    private var availableSound: SystemSoundID = 0
    private var unavailableSound: SystemSoundID = 0
    
    private var previewItem: URL?
    
    /// File types that are actually ZIP containers but should just be saved directly
    private let zipWrappedButSaveDirectly: Set<String> = [
        "xlsx", "docx", "pptx", // Microsoft Office
        "pages", "numbers", "key" // Apple iWork
    ]

    private let sessionManager = PeerSessionManager()
    private var peers: [MCPeerID] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let status = PHPhotoLibrary.authorizationStatus()
        if status != .authorized {
            PHPhotoLibrary.requestAuthorization() {
                status in
            }
        }
    
        if !deviceHasCamera {
            self.cameraBarButtonItem?.isEnabled = false
        }
        
        self.circularProgressButton?.layer.cornerRadius = 10.0
        self.circularProgressButton?.layer.borderColor = UIColor.white.cgColor
        self.circularProgressButton?.layer.borderWidth = 1.0
        loadBackgroundImage()
        loadSounds()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.circularProgressButton?.addTarget(self, action: #selector(onCircularProgressViewTouchUpInside(_ :)), for: .touchUpInside)
        
        self.progressView?.isHidden = true
        
        let animateOptions = UIView.AnimationOptions.init(rawValue: UIView.AnimationOptions.beginFromCurrentState.rawValue | UIView.AnimationOptions.autoreverse.rawValue | UIView.AnimationOptions.curveEaseOut.rawValue)
        UIView.animate(withDuration: 5.0, delay: 0.0, options: animateOptions, animations: {() -> Void in
            self.backgroundImageHighlighted?.alpha = 0.0
        }, completion: nil)
        
        self.myDeviceNameLabel?.text = "Local Name: \(UIDevice.current.name)"
        self.myFileToTransferLabel?.text = "File to Transfer: " + (transferFileURL?.lastPathComponent ?? "No File Selected")
        self.statusLabel?.text = "Waiting..."
        
        sessionManager.onPeerDiscovered = { isAvailable in
            Task {
                self.peers.removeAll()
                self.peers.append(contentsOf: await self.sessionManager.getDiscoveredPeers())
                await MainActor.run {
                    if isAvailable {
                        AudioServicesPlaySystemSound(self.availableSound)
                    }
                    else {
                        AudioServicesPlaySystemSound(self.unavailableSound)
                    }
                    self.devicesTable?.reloadData()
                    self.updateTableVisibility()
                }
            }
        }
        
        sessionManager.onInvitationReceived = { [weak self] displayName, vc, completion in
            Task { @MainActor in
                let accepted = await self?.showInvitationAlert(from: displayName, on: vc) ?? false
                completion(accepted)
            }
        }
        
        Task {
            await restartSession()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        sessionManager.stop()
        sessionManager.onPeerDiscovered = nil
    }
    
    // MARK: - Actions
    
    @IBAction func didTapTransferFile(_ sender: UIBarButtonItem?) {
        Task {
            let peers = await sessionManager.getDiscoveredPeers()
            if let transferFileURL,
               peers.count > 0 {
                await sessionManager.mpcActor?.sendFile(url: transferFileURL, to: peers)
            }
        }
    }
    
    @IBAction func didTapAddImage(_ sender: UIBarButtonItem?) {
        if let _sender = sender {
            let imagePicker = UIImagePickerController()
            imagePicker.delegate = self
            
            let imageSource: UIImagePickerController.SourceType = _sender.tag == 1 ? .photoLibrary : .camera
            switch imageSource {
                case .camera:
                    print("User chose take new pic button")
                    imagePicker.sourceType = .camera
                    imagePicker.cameraDevice = .front
                case .photoLibrary:
                    print("User chose select pic button")
                    imagePicker.sourceType = .savedPhotosAlbum
                default:
                    break
            }
            imagePicker.view.isUserInteractionEnabled = true
            imagePicker.modalPresentationStyle = .pageSheet
            
            if UIDevice.current.userInterfaceIdiom == .pad {
                if imageSource == .camera {
                    self.present(imagePicker, animated: true) {
                        //println("In image picker completion block")
                    }
                }
                else {
                    self.present(imagePicker, animated: true) {
                        //println("In image picker completion block")
                    }
                }
            }
            else {
                self.present(imagePicker, animated: true) {
                    print("In image picker completion block")
                }
            }
        }
    }
    
    @IBAction func didTapAddExportFile(_ sender: UIBarButtonItem?) {
        if let _ = sender {
            let picker = FilePickerViewController()
            picker.modalPresentationStyle = .formSheet // or .popover if on iPad
            picker.onFileSelected = { fileURL in
                print("Selected file: \(fileURL.path)")
                self.transferFileURL = fileURL
                Task {
                    await MainActor.run {
                        self.myFileToTransferLabel?.text = "File to Transfer: " + (self.transferFileURL?.lastPathComponent ?? "No file selected")
                    }
                }
            }
            present(picker, animated: true)
        }
    }
    
    @IBAction func didTapShowImportFiles(_ sender: UIBarButtonItem?) {
        if let _ = sender {
            let picker = FilePickerViewController()
            picker.folderOption = .importFolder
            picker.modalPresentationStyle = .formSheet // or .popover if on iPad
            picker.onFileSelected = { [weak self] fileURL in
                print("Selected file: \(fileURL.path)")
                self?.previewItem = fileURL
                self?.showPreview()
            }
            present(picker, animated: true)
        }
    }
    
    func showPreview() {
        guard let _ = previewItem else { return }
        let previewController = QLPreviewController()
        previewController.dataSource = self
        present(previewController, animated: true)
    }
    
    // MARK: - Invitations
    
    func showInvitationAlert(from displayName: String, on vc: UIViewController) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "Invitation",
                                          message: "Accept invitation from \(displayName)?",
                                          preferredStyle: .alert)

            var didResume = false
            
            let accept = UIAlertAction(title: "Accept", style: .default) { _ in
                if !didResume {
                    didResume = true
                    continuation.resume(returning: true)
                }
            }

            let decline = UIAlertAction(title: "Decline", style: .cancel) { _ in
                if !didResume {
                    didResume = true
                    continuation.resume(returning: false)
                }
            }

            alert.addAction(accept)
            alert.addAction(decline)

            vc.present(alert, animated: true) {
                // If the peer disconnects before user taps, make sure to dismiss alert and cancel continuation
                Task {
                    try? await Task.sleep(nanoseconds: 15 * NSEC_PER_SEC) // 15 sec timeout
                    if !didResume {
                        didResume = true
                        vc.dismiss(animated: true)
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }
    
    // MARK: - Save File
    
    private func saveFile(_ data: Data?, metadata: FileTransferMetadata, fileCacheURL: URL, peer: MCPeerID) {
//        let appearance = SCLAlertView.SCLAppearance(
//                kWindowWidth: UIDevice.current.userInterfaceIdiom == .phone ? 240.0 : 320.0,
//                kTitleFont: UIFont(name: "HelveticaNeue", size: 20)!,
//                kTextFont: UIFont(name: "HelveticaNeue", size: 16)!,
//                kButtonFont: UIFont(name: "HelveticaNeue-Bold", size: 16)!,
//                showCloseButton: false,
//                shouldAutoDismiss: true,
//                contentViewCornerRadius: CGFloat(5.0),
//                buttonCornerRadius: CGFloat(5.0),
//                contentViewColor: UIColor(red: 0.69, green: 0.769, blue: 0.871, alpha: 1.0),
//                contentViewBorderColor: UIColor(red: 1.00, green: 0.75, blue: 0.793, alpha: 1.0),
//                contentViewAlignment: .left,
//                buttonsLayout: .horizontal
//            )
//        // Initialize SCLAlertView using custom Appearance
//        let alert = SCLAlertView(appearance: appearance)
        var message = ""
        var title = ""
        var defaultAction: UIAlertAction?
        var okAction: UIAlertAction?
            
        let filename = metadata.filename
        let filemgr = FileManager.default

        let dirPaths: [String] = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let directoryName = "Imports"
        let docsDir = URL(fileURLWithPath: dirPaths[0] + "/" + directoryName)

        
        if filemgr.changeCurrentDirectoryPath(docsDir.path),
           let finalCacheURL = finalizeReceivedFile(at: fileCacheURL, metadata: metadata) {
            let saved_url = docsDir.appendingPathComponent(filename)
            if filemgr.fileExists(atPath: saved_url.path) {
                message = "The file '\(filename)' already exists in the \(directoryName) directory! Do you wish to overwrite it?"
                title = "P2P Transfer Alert"
                defaultAction = UIAlertAction(title: "No", style: .default, handler: {(_ action: UIAlertAction?) -> Void in })
                okAction = UIAlertAction(title: "Yes", style: .default, handler: {(_ action: UIAlertAction?) -> Void in
                
                    self.waitToDismissAlert()

                    var alert: UIAlertController
                    var defaultAction: UIAlertAction
                    var message = ""
                    do {
                        try self.saveFileWithoutMetadata(from: finalCacheURL, to: saved_url)
                        try filemgr.removeItem(at: fileCacheURL)
                        try filemgr.removeItem(at: finalCacheURL)
                        message = "File '\(filename)' transfered from \(peer.displayName) from cache to \(directoryName) directory"
                        alert = UIAlertController(title: "P2P Transfer Complete", message: message, preferredStyle: .alert)
                        defaultAction = UIAlertAction(title: "OK", style: .default, handler: {(_ action: UIAlertAction?) -> Void in })
                    }
                    catch {
                        message = "Unable to copy transfered file '\(filename)' from \(peer.displayName) from cache to \(directoryName) directory"
                        alert = UIAlertController(title: "P2P Transfer Error", message: message, preferredStyle: .alert)
                        defaultAction = UIAlertAction(title: "OK", style: .default, handler: {(_ action: UIAlertAction?) -> Void in })
                    }
                    alert.addAction(defaultAction)
                    self.present(alert, animated: true) {() -> Void in }
                })
    //                _ = alert.addButton("No", backgroundColor: UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.8), textColor: UIColor.white) {
    //                    alert.hideView()
    //                }
    //                _ = alert.addButton("Yes", backgroundColor: UIColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.8), textColor: UIColor.white) {
    //                    self.waitToDismissAlert()
    //                    let alert = SCLAlertView(appearance: appearance)
    //                    //                                        var alert: UIAlertController?
    //                    //                                        var defaultAction: UIAlertAction?
    //                    var message = ""
    //                    var title = ""
    //                    do {
    //                        try self.saveFileWithoutMetadata(from: finalCacheURL, to: saved_url)
    //                        try filemgr.removeItem(at: fileCacheURL)
    //                        try filemgr.removeItem(at: finalCacheURL)
    //
    //                        message = "File '\(filename)' transfered from \(peer.displayName) from cache to \(directoryName) directory"
    //                        title = "P2P Transfer Complete"
    //                    }
    //                    catch {
    //                        message = "Unable to copy transfered file '\(filename)' from \(peer.displayName) from cache to \(directoryName) directory"
    //                        //                                            alert = UIAlertController(title: "P2P Transfer Error", message: message, preferredStyle: .alert)
    //                        title = "P2P Transfer Error"
    //                        //                                            defaultAction = UIAlertAction(title: "OK", style: .default, handler: {(_ action: UIAlertAction?) -> Void in })
    //                        
    //                    }
    //                    _ = alert.addButton("OK", backgroundColor: UIColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.8), textColor: UIColor.white) {
    //                        alert.hideView()
    //                    }
    //                    if title.contains("Error") {
    //                        _ = alert.showError(title, subTitle: message)
    //                    }
    //                    else {
    //                        _ = alert.showSuccess(title, subTitle: message)
    //                    }
    //                }
            }
            else {
                do {
                    try self.saveFileWithoutMetadata(from: fileCacheURL, to: saved_url)
                    try filemgr.removeItem(at: fileCacheURL)
                    try filemgr.removeItem(at: finalCacheURL)
                    message = "File '\(filename)' transfered from \(peer.displayName) from cache to \(directoryName) directory"
                    title = "P2P Transfer Complete"
                }
                catch {
                    message = "Unable to copy transfered file '\(filename)' from \(peer.displayName) from cache to \(directoryName) directory"
                    title = "P2P Transfer Error"
                }
            }
        }
        else {
            message = "Unable to change to the \(directoryName) directory!!"
            title = "P2P Transfer Error"
        }
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let okAction = okAction {
            alert.addAction(okAction)
        }
        if let defaultAction = defaultAction {
            alert.addAction(defaultAction)
        }
    
        present(alert, animated: true, completion: nil)
//        if title.contains("Error") {
//            _ = alert.addButton("OK", backgroundColor: UIColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.8), textColor: UIColor.white) {
//                alert.hideView()
//            }
//            _ = alert.showError(title, subTitle: message)
//        }
//        else if title.contains("Alert") {
//            _ = alert.showInfo(title, subTitle: message)
//        }
//        else {
//            _ = alert.addButton("OK", backgroundColor: UIColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.8), textColor: UIColor.white) {
//                alert.hideView()
//            }
//            _ = alert.showSuccess(title, subTitle: message)
//        }
    }
    
    func saveFileWithoutMetadata(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        // Read 4-byte metadata length prefix
        let lengthData = try input.read(upToCount: 4)
        guard let lengthData, lengthData.count == 4 else {
            throw NSError(domain: "InvalidHeader", code: 1)
        }

        let metadataLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        // Skip metadata JSON
        try input.seek(toOffset: 4 + UInt64(metadataLength))

        // Prepare output file
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        let chunkSize = 64 * 1024
        while true {
            let chunk = try input.read(upToCount: chunkSize)
            if let chunk, !chunk.isEmpty {
                output.write(chunk)
            } else {
                break // no more data
            }
        }
    }
    
    func finalizeReceivedFile(at url: URL, metadata: FileTransferMetadata) -> URL? {
        var cleanedURL: URL?
        do {
            cleanedURL = try stripMetadataHeaderIfPresent(from: url)
        }
        catch {
            print("Not an archive, returning original file.")
            return url
        }
        
        // If it's a plain file type, return immediately
        let plainTypes = ["csv", "txt", "jpg", "jpeg", "png", "pdf", "mp4"]
        if let _cleanedURL = cleanedURL,
           let ext = detectFileType(from: _cleanedURL) {
            if ext == "zip",
               let metaExt = metadata.filename.fileExtension()?.lowercased(),
               zipWrappedButSaveDirectly.contains(metaExt) {
                return url
            }
            else if fileContentType == "zip" {
                do {
                    let archive = try Archive(url: _cleanedURL, accessMode: .read)
                    for entry in archive {
                        let entryExt = (entry.path as NSString).pathExtension.lowercased()
                        if plainTypes.contains(entryExt) {
                            let destinationURL = url.deletingLastPathComponent()
                                .appendingPathComponent((entry.path as NSString).lastPathComponent)
                            do {
                                _ = try archive.extract(entry) { data in
                                    try data.write(to: destinationURL, options: .atomic)
                                }
                                print("Extracted embedded file to: \(destinationURL.path)")
                                return destinationURL
                            } catch {
                                print("❌ Failed to extract embedded file: \(error)")
                            }
                        }
                    }
                }
                catch let error as Archive.ArchiveError {
                    print("Not an archive, returning original file.\(error)")
                    return url
                }
                catch {
                    print("Not an archive, returning original file.")
                    return url
                }
            } else {
                // Other file types: png, jpg, csv, etc
                return url
            }
        }
        else {
            return url
        }
        

        // Fallback
        return url
    }
    
    /// Strips custom metadata header from a received file and returns a cleaned file URL
    func stripMetadataHeaderIfPresent(from url: URL) throws -> URL {
        let inputHandle = try FileHandle(forReadingFrom: url)
        defer { try? inputHandle.close() }

        // Read first 4 bytes -> metadata length
        let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
        guard lengthData.count == 4 else { throw NSError(domain: "MetadataError", code: 1) }

        let metadataLength = lengthData.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
        
        // Skip metadata block
        try inputHandle.seek(toOffset: UInt64(4 + metadataLength))

        // Now the real file starts
        let cleanedTempURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: cleanedTempURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: cleanedTempURL)
        defer { try? outputHandle.close() }
        
        let chunkSize = 64 * 1024
        while let chunk = try inputHandle.read(upToCount: chunkSize), !chunk.isEmpty {
            try outputHandle.write(contentsOf: chunk)
        }
        
        return cleanedTempURL
    }
    
    func detectFileType(from url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }

//        // Read 4 bytes for metadata length
//        guard let lengthData = try? fileHandle.read(upToCount: 4),
//              lengthData.count == 4 else {
//            return nil
//        }
//
//        let metadataLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
//
//        // Skip metadata bytes
//        try? fileHandle.seek(toOffset: 4 + UInt64(metadataLength))
        
        if let data = try? fileHandle.read(upToCount: 16) {
            let magic = [UInt8](data)
            if magic.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if magic.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
            if magic.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
            if magic.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" } // also xlsx/docx
            if magic.count >= 12 && magic[4...7] == [0x66, 0x74, 0x79, 0x70] { return "mp4" }
            
            if let text = String(data: data, encoding: .utf8),
               let firstChar = text.first,
               firstChar.isLetter {
                return "text"
            }
        }
        return "unknown"
    }
    
    func waitToDismissAlert() {
        guard presentedViewController is UIAlertController else { return }

        dismiss(animated: false)

        Task {
            // Sleep 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            await MainActor.run {
                if self.presentedViewController is UIAlertController {
                    print("UIAlertController isn't dismissed yet (P2PViewController)")
                } else {
                    print("Waited for UIAlertController to be dismissed fully (P2PViewController)")
                }
            }
        }
    }
    
    // MARK: - UITableView visibility
    
    func updateTableVisibility() {
        self.noDevicesLabel?.isHidden = peers.count > 0
        self.devicesTable?.isHidden = peers.count == 0
        self.searchingForDevicesView?.isHidden = peers.count > 0
    }
    
    
    // MARK: - CircularProgressView Action
    
    @objc func onCircularProgressViewTouchUpInside(_ sender: Any?) {
        sessionManager.stop()
    }
    
    // MARK: - Load Resources
    
    private func loadSounds() {
        let mainBundle = CFBundleGetMainBundle()
        if let availableURL = CFBundleCopyResourceURL(mainBundle, AVAILABLE_SOUND_FILE_NAME as CFString, "aiff" as CFString, nil) {
            AudioServicesCreateSystemSoundID(availableURL, &availableSound)
        }
        if let unavailableURL = CFBundleCopyResourceURL(mainBundle, UNAVAILABLE_SOUND_FILE_NAME as CFString, "aiff" as CFString, nil) {
            AudioServicesCreateSystemSoundID(unavailableURL, &unavailableSound)
        }
    }
    
    private func loadBackgroundImage() {
        if let image = UIImage(named: "whichtoolface")?.trimmedWhite(tolerance: 243)?.tinted(with: UIColor(red: 0.69, green: 0.769, blue: 0.871, alpha: 1), alpha: 0.6) {
            view.backgroundColor = UIColor(patternImage: image)
        }
    }
    
    // MARK: - Alerts
    
    private func showAlert(title: String, message: String, actions: [UIAlertAction]? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let actions = actions {
            for action in actions {
                alert.addAction(action)
            }
        }
        else {
            alert.addAction(UIAlertAction(title: "OK", style: .default))
        }
        present(alert, animated: true)
        
        if actions == nil {
            Task {
                try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
                await MainActor.run {
                    alert.dismiss(animated: true)
                }
            }
        }
    }
    
    // MARK: - Restart Session
    
    @MainActor
    func restartSession() async {
        sessionManager.stop()
        try? await Task.sleep(nanoseconds: 2_000_000_000) // wait 2 second
        await sessionManager.setup()
        await sessionManager.setDelegate(delegate: self)
        await sessionManager.start()
        if let mpcActor = sessionManager.mpcActor {
            sessionManager.wireProgressCallback(from: mpcActor) //{ [weak self] filename, peerName, progress in
            //            guard let strongSelf = self else { return }
            //            strongSelf.updateProgress(for: peerName, filename: filename, progress: progress)
            //        }
        }
        await sessionManager.mpcActor?.setPresentingViewController { [weak self] in
            self ?? UIViewController()
        }
    }
}

// MARK: - Extensions

// MARK: - UIImagePickerController Delegates

extension ViewController: UIImagePickerControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        print("In \(#function)")
        if let imageURL = info[UIImagePickerController.InfoKey.imageURL] as? URL {
            self.transferFileURL = imageURL
            Task {
                await MainActor.run {
                    self.myFileToTransferLabel?.text = "File to Transfer: " + (self.transferFileURL?.lastPathComponent ?? "No file selected")
                }
            }
            picker.dismiss(animated: true, completion: nil)
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        print("In \(#function)")
        Task {
            await MainActor.run {
                self.myFileToTransferLabel?.text = "File to Transfer: " + (self.transferFileURL?.lastPathComponent ?? "No file selected")
            }
        }
        picker.dismiss(animated: true, completion: nil)
    }

    
//    private func updateImage() async {
//        await MainActor.run {
//            // Update the UI
//            self.imageView?.image = self.image
//            if let _ = self.image {
//                self.selectTransferFileButton?.isEnabled = true
//            }
//            else {
//                self.selectTransferFileButton?.isEnabled = false
//            }
//        }

}

// MARK: - PeerSession TableView DataSource & Delegate
extension ViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return peers.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row < peers/*mpcManager.foundPeers*/.count {
            let cell = tableView.dequeueReusableCell(withIdentifier: "PeerCell") ?? UITableViewCell(style: .default, reuseIdentifier: "PeerCell")
            cell.textLabel?.text = peers[indexPath.row].displayName
            return cell
        }
        else {
            return UITableViewCell()
        }
    }
    
    
}

// MARK: - PeerSession TableView Delegates Extensions
extension ViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return 65.0
        }
        else {
            return 50.0
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
//        let peer = mpcManager.foundPeers[indexPath.row]
//        mpcManager.invitePeer(peer)
        let peer = peers[indexPath.row]
        Task {
            sessionManager.invitePeer(peer, context: nil)
            await MainActor.run {
                self.statusLabel?.text = "Inviting \(peer.displayName)…"
            }
        }
    }
}

// MARK: - UIImage Extensions
extension UIImage {
    /// Returns a new image with a solid background color.
    /// - Parameters:
    ///   - color: The background color to fill behind the image.
    ///   - opaque: Whether the background is fully opaque. Defaults to `true`.
    func withBackground(color: UIColor, opaque: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = opaque
        format.scale = self.scale

        let renderer = UIGraphicsImageRenderer(size: self.size, format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: self.size))
            self.draw(at: .zero)
        }
    }
    
    func tinted(with color: UIColor, alpha: CGFloat = 0.4) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(at: .zero)
            color.withAlphaComponent(alpha).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        }
    }
    
    /// Trims transparent or uniform-colored padding from the image.
    func trimmed() -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        var minX = width
        var minY = height
        var maxX: Int = 0
        var maxY: Int = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let alpha = bytes[offset + 3] // Assuming RGBA

                if alpha > 0 { // non-transparent pixel
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard minX <= maxX && minY <= maxY else {
            // Image is fully transparent
            return nil
        }

        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        return UIImage(cgImage: cropped, scale: self.scale, orientation: self.imageOrientation)
    }
    
    /// Trims white (or nearly white) padding from an image.
        /// - Parameter tolerance: Value from 0–255 for how "white" a pixel must be to be considered background.
        func trimmedWhite(tolerance: UInt8 = 250) -> UIImage? {
            guard let cgImage = self.cgImage else { return nil }

            let width = cgImage.width
            let height = cgImage.height

            guard let data = cgImage.dataProvider?.data,
                  let bytes = CFDataGetBytePtr(data) else { return nil }

            let bytesPerPixel = cgImage.bitsPerPixel / 8
            let bytesPerRow = cgImage.bytesPerRow

            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0

            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * bytesPerPixel

                    let r = bytes[offset]
                    let g = bytes[offset + 1]
                    let b = bytes[offset + 2]

                    if r < tolerance || g < tolerance || b < tolerance {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }

            guard minX < maxX && minY < maxY else {
                return nil // Fully white image
            }

            let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            guard let croppedCG = cgImage.cropping(to: cropRect) else { return nil }

            return UIImage(cgImage: croppedCG, scale: self.scale, orientation: self.imageOrientation)
        }
}

// MARK: - String Extensions
extension String {
    func fileExtension() -> String? {
        return (self as NSString).pathExtension.lowercased()
    }
}

// MARK: - QLPreviewController DataSource
extension ViewController: QLPreviewControllerDataSource {
    
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return previewItem != nil ? 1 : 0
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return previewItem! as NSURL
    }
}

// MARK: - PeerSessionManager Delegate
extension ViewController: PeerSessionManagerDelegate {
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didUpdateStatus status: String, filename: String?, with peer: MCPeerID) {
        Task { @MainActor in
            self.showAlert(title: "Status", message: status)
            self.statusLabel?.text = status + "\(peer.displayName)"
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didConnectTo peer: MCPeerID) {
        Task { @MainActor in
            self.showAlert(title: "Status", message: "Connected to \(peer.displayName)")
            self.statusLabel?.text = "Connected to \(peer.displayName)"
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didDisconnectFrom peer: MCPeerID) {
        Task { @MainActor in
            let cancel = UIAlertAction(title: "Cancel", style: .cancel)
            let reconnect = UIAlertAction(title: "Reconnect", style: .default) { _ in
                Task {
                    await self.restartSession()
                }
            }
            self.showAlert(title: "Status", message: "Disconnected from \(peer.displayName).  Would you like to restart the session?", actions: [cancel, reconnect])
            self.statusLabel?.text = "Disconnected from \(peer.displayName)"
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didFindPeer peer: MCPeerID) {
        Task { @MainActor in
            if !self.peers.contains(peer) {
                self.peers.append(peer)
                self.devicesTable?.reloadData()
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didLosePeer peer: MCPeerID) {
        Task { @MainActor in
            if let index = self.peers.firstIndex(of: peer) {
                self.peers.remove(at: index)
                self.devicesTable?.reloadData()
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didChangeState state: MCSessionState, with peer: MCPeerID) {
        let description: String
        switch state {
            case .connected: 
                description = "Connected to \(peer.displayName)"
            case .connecting: 
                description = "Connecting to \(peer.displayName)..."
            case .notConnected: 
                description = "Disconnected from \(peer.displayName)"
            @unknown default: 
                description = "Unknown state with \(peer.displayName)"
        }
//        Task { @MainActor in
//            self.statusLabel?.text = description
////            if state == .connected {
////                self.activityIndicator.stopAnimating()
////            }
//        }
        MainActor.assumeIsolated {
            self.statusLabel?.text = description
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didSendFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID]) {
        
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didReceiveFile url: URL, metadata: FileTransferMetadata, from peer: MCPeerID) {
        Task { @MainActor in
            self.statusLabel?.text = "Received file from \(peer.displayName): \(url.lastPathComponent)"
            
            //saveFile(data, metadata: metadata, fileCacheURL: fileURL, peer: peer)
            if let progressView {
                self.view.bringSubviewToFront(progressView)
                circularProgressLabel?.text = "Current Transfer: ending"
                circularProgressView?.angle = 360.0
                circularProgressView?.animate(toAngle: 360.0, duration: 0.5, completion: nil)
                progressView.isHidden = true
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didStartSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID]) {
        Task { @MainActor in
            self.statusLabel?.text = "Started sending file: \(fileURL.lastPathComponent)"
            if let progressView {
                self.view.sendSubviewToBack(progressView)
                progressView.isHidden = false
                circularProgressLabel?.text = "Current Transfer: starting"
                circularProgressView?.angle = 0.0
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didUpdateProgress progress: Progress, forSendingFileNamed filename: String, to peers: [MCPeerID]) {
        Task { @MainActor in
            self.statusLabel?.text = String(format: "Sending %@: %.0f%%", filename, progress.fractionCompleted * 100)
            circularProgressView?.progress = progress.fractionCompleted * 100.0
            if let _ = progressView {
                circularProgressLabel?.text = "Current Transfer: starting"
                //circularProgressView?.angle = 0.0
                let newAngleValue = progress.fractionCompleted * 360.0
                circularProgressView?.animate(toAngle: newAngleValue, duration: 0.5, completion: nil)
            }
        }
        
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didFinishSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID]) {
        Task { @MainActor in
            self.statusLabel?.text = "Finished sending file: \(fileURL.lastPathComponent)"
            if let progressView {
                self.view.bringSubviewToFront(progressView)
                circularProgressLabel?.text = "Current Transfer: ending"
                circularProgressView?.angle = 360.0
                circularProgressView?.animate(toAngle: 360.0, duration: 0.5, completion: nil)
                progressView.isHidden = true
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didFailToSendFile fileURL: URL, metadata: FileTransferMetadata?, to peers: [MCPeerID]?, error: any Error) {
        Task { @MainActor in
            self.statusLabel?.text = "Send Error: \(error.localizedDescription)"
            
            showAlert(title: "Send Failed", message: error.localizedDescription)
            self.fileContentType = ""
            if let progressView {
                self.view.bringSubviewToFront(progressView)
                circularProgressLabel?.text = "Current Transfer: ending"
                circularProgressView?.angle = 360.0
                circularProgressView?.animate(toAngle: 360.0, duration: 0.5, completion: nil)
                progressView.isHidden = true
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didStartReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID) {
        Task { @MainActor in
            if let progressView {
                self.view.bringSubviewToFront(progressView)
                progressView.isHidden = false
                circularProgressLabel?.text = "Current Transfer: ending"
                circularProgressView?.angle = 0.0
                circularProgressView?.animate(toAngle: 0.0, duration: 0.5, completion: nil)
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didUpdateProgress progress: Progress, forReceivingFileNamed filename: String, from peer: MCPeerID) {
        Task { @MainActor in
            self.statusLabel?.text = String(format: "Receiving %@ from %@: %.0f%%", filename, peer.displayName, progress.fractionCompleted * 100)
            circularProgressView?.progress = progress.fractionCompleted * 100.0
            if let _ = progressView {
                circularProgressLabel?.text = "Current Transfer: starting"
                //circularProgressView?.angle = 0.0
                let newAngleValue = progress.fractionCompleted * 360.0
                circularProgressView?.animate(toAngle: newAngleValue, duration: 0.5, completion: nil)
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didFinishReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID) {
        Task { @MainActor in
            saveFile(nil, metadata: metadata, fileCacheURL: fileURL, peer: peer)
            self.filesize = 0
            self.fileContentType = ""
            if let progressView {
                self.view.bringSubviewToFront(progressView)
                circularProgressLabel?.text = "Current Transfer: ending"
                circularProgressView?.angle = 360.0
                circularProgressView?.animate(toAngle: 360.0, duration: 0.5, completion: nil)
                progressView.isHidden = true
            }
        }
    }
    
    nonisolated func peerSessionManager(_ manager: PeerSessionManager?, didFailToReceiveFile fileURL: URL, metadata: FileTransferMetadata?, from peer: MCPeerID?, error: any Error) {
        guard let peer else { return }
        Task { @MainActor in
            self.statusLabel?.text = "Receive Error with \(peer.displayName): \(error.localizedDescription)"
            if let progressView {
                self.view.bringSubviewToFront(progressView)
                circularProgressLabel?.text = "Current Transfer: ending"
                circularProgressView?.angle = 360.0
                circularProgressView?.animate(toAngle: 360.0, duration: 0.5, completion: nil)
                progressView.isHidden = true
            }
        }
    }
    
}
