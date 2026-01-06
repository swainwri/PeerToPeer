//
//  MPCActor.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 06/05/2025.
//


import Foundation
@preconcurrency import MultipeerConnectivity

// MARK: - MPCActor

enum FileTransferError: Error {
    case connectionLost
    case error(description: String)
    case sendFileFailed(description: String)
    case receiveFileFailed(description: String)
    case sendMessageFailed(description: String)
    case unknown(Error)
    
    var localizedDescription: String {
        switch self {
            case .connectionLost:
                return "The connection was lost."
            case .error(description: let err):
                return "Error: \(err)"
            case .sendFileFailed(description: let filename):
                return "File '\(filename)' was not sent."
            case .receiveFileFailed(description: let filename):
                return "File '\(filename)' was not received."
            case .sendMessageFailed(description: let message):
                return "Message: '\(message)' was not sent."
            case .unknown(let error):
                return "Unknown error: \(error.localizedDescription)"
        }
    }
}

protocol MPCActorDelegate: AnyObject {
    // MARK: - Session Events
    func mpcActor(_ actor: MPCActor, didConnectTo peer: MCPeerID)
    func mpcActor(_ actor: MPCActor, didDisconnectFrom peer: MCPeerID)
    func mpcActor(_ actor: MPCActor, didReceiveInvitationFrom peer: MCPeerID, context: Data?, handler: @escaping @Sendable (Bool, MCSession?) -> Void)
    // MARK: - Transfer Events
    func mpcActor(_ actor: MPCActor, didFailSendingMessage message: String, to peers: [MCPeerID]?, error: Error)
    func mpcActor(_ actor: MPCActor, didFailReceivingMessage message: String, from peer: MCPeerID?, error: Error)
    //func mpcActor(_ actor: MPCActor, didReceiveStreamEvent stream: Stream, event: Stream.Event)
    func mpcActor(_ actor: MPCActor, didUpdateProgress progress: Progress, metadata: FileTransferMetadata, forPeers peers: [MCPeerID])
    func mpcActor(_ actor: MPCActor, didStartSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID])
    func mpcActor(_ actor: MPCActor, didFinishSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID])
    func mpcActor(_ actor: MPCActor, didStartReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID)
    func mpcActor(_ actor: MPCActor, didFinishReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID)
    func mpcActor(_ actor: MPCActor, didFailSendingFile fileURL: URL, metadata: FileTransferMetadata?, to peers: [MCPeerID]?, error: Error)
    func mpcActor(_ actor: MPCActor, didFailReceivingFileName fileName: String, metadata: FileTransferMetadata?, from peer: MCPeerID?, error: Error)
    // MARK: - Resume Support
    func mpcActor(_ actor: MPCActor, didFailProcessingPendingTransfersFor peer: MCPeerID, error: Error)
}

struct PendingFileTransfer {
    let fileURL: URL
    let peerIDs: [MCPeerID]
}


public struct StreamHandle: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case input
        case output
    }

    /// Stable logical ID (e.g., per transfer/session)
    let uuid: UUID

    /// Stream instance identity (used for delegate lookups)
    let objectID: ObjectIdentifier

    /// Whether the stream is for input or output
    let kind: Kind

    init(stream: Stream, kind: Kind) {
        self.uuid = UUID()
        self.objectID = ObjectIdentifier(stream)
        self.kind = kind
    }
}

public actor MPCActor: NSObject {
    
    var deviceName: String?
    nonisolated(unsafe) weak var delegate: MPCActorDelegate?
    
    private var _presentingViewController: (@MainActor () -> UIViewController)? = nil
    
    func setPresentingViewController(_ block: @escaping @MainActor () -> UIViewController) {
        self._presentingViewController = block
    }

    var presentingViewController: (@MainActor () -> UIViewController)? {
        return _presentingViewController
    }
    
    private var progressHandler: (@Sendable (Progress) -> Void)? = nil
    nonisolated(unsafe) var onProgress: ( (_ filename: String, _ peerName: String, _ progress: Double) async -> Void)?
    
    private(set) var session: MCSession?
    private var peerID: MCPeerID?
    
    private var pendingSends: [PendingFileTransfer] = []
    
    private var streamingPeer: MCPeerID?
    private var streamingMetaData: FileTransferMetadata?
    private let resumeManager = ResumeManager()
    
    // MARK: - Initialistion
    
    override init() {
        super.init()
    }
    
    func setup() async {
        let name = await UIDevice.current.name
        self.setDeviceName(name)

        do {
            try await self.setPeerID()
        }
        catch let error as FileTransferError {
            print(error.localizedDescription)
        }
        catch {
            print(error.localizedDescription)
        }
    }
    
    // Start browsing and advertising services
    func start() {
        if let peerID {
            self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
            session?.delegate = self
        }
        else {
            print("Cannot start: peerID is not set")
        }
    }
    
    func stop() {
        self.session?.disconnect()
    }
    
    // MARK: - Stream Handling
    
    private var streamRegistry: [ObjectIdentifier: Stream] = [:]
    private var handleRegistry: [ObjectIdentifier: StreamHandle] = [:]

    func register(_ stream: Stream) -> StreamHandle {
        let id = ObjectIdentifier(stream)

        if let existing = handleRegistry[id] {
            return existing
        }

        let handle = StreamHandle(stream: stream, kind: stream is InputStream ? .input : .output)
        streamRegistry[id] = stream
        handleRegistry[id] = handle
        stream.delegate = self
        return handle
    }
    
    func deregister(_ handle: StreamHandle) {
        let id = handle.objectID
//        textPasteRegistry.removeValue(forKey: id)
        handleRegistry.removeValue(forKey: id)
    }
    
    func setStream(_ stream: Stream) async {
        let id = ObjectIdentifier(stream)
        streamRegistry[id] = stream
        handleRegistry[id] = StreamHandle(stream: stream, kind: stream is InputStream ? .input : .output)
        stream.delegate = self  // Set AFTER registration
    }
    
    func stream(for handle: StreamHandle) -> Stream? {
        handleRegistry.first { $0.value == handle }.flatMap { streamRegistry[$0.key] }
    }
    
    // MARK: - Send / Receive
    
    func sendMessage(_ message: String, to peers: [MCPeerID]) async {
        guard let session = session else {
            //throw FileTransferError.error(description: "No MCSession setup yet")
            self.delegate?.mpcActor(self, didFailSendingMessage: message, to: peers, error: NSError(domain: "MCSession Error: not yet setup", code: 999))
            return
        }
        do {
            let data = Data(message.utf8)
            try session.send(data, toPeers: peers, with: .reliable)
            print("Sent to: \(peers.map(\.displayName))")
        }
        catch {
            print("Error sending message: \(error)")
            //throw FileTransferError.sendMessageFailed(description: "Error sending message: \(error.localizedDescription)")
            self.delegate?.mpcActor(self, didFailSendingMessage: message, to: peers, error: NSError(domain: "Failed to send message, \(error.localizedDescription)", code: 999))
        }
    }
    
    func sendFile(url: URL, to peers: [MCPeerID]) async {
        guard let session else {
            //throw FileTransferError.error(description: "No MCSession setup yet")
            self.delegate?.mpcActor(self, didFailSendingFile: url, metadata: nil, to: peers, error: NSError(domain: "MCSession Error: not yet setup", code: 999))
            return
        }

        let connected = session.connectedPeers
        let (readyPeers, waitingPeers) = peers.reduce(into: ([MCPeerID](), [MCPeerID]())) { result, peer in
            if connected.contains(peer) {
                result.0.append(peer)
            } else {
                result.1.append(peer)
            }
        }
        
        // Send immediately to connected peers
        if !readyPeers.isEmpty {
            if let metadataHeader = createMetadataHeader(url),
               let mdata = metadataHeader.data {
                do {
                    var data = try Data(contentsOf: url)
                    data.insert(contentsOf: mdata, at: data.startIndex)
                    self.delegate?.mpcActor(self, didStartSendingFile: url, metadata: metadataHeader.metadata, to: readyPeers)
                    try session.send(data, toPeers: readyPeers, with: .reliable)
                    print("Sent to: \(readyPeers.map(\.displayName))")
                    self.delegate?.mpcActor(self, didFinishSendingFile: url, metadata: metadataHeader.metadata, to: readyPeers)
                }
                catch {
                    print("Error sending file: \(error)")
                    //throw FileTransferError.sendFileFailed(description: "Error sending file: \(error.localizedDescription)")
                    self.delegate?.mpcActor(self, didFailSendingFile: url, metadata: metadataHeader.metadata, to: readyPeers, error: NSError(domain: "MCSession Error: Failed to send file, \(error.localizedDescription)", code: 999))
                    return
                }
            }
            else {
//                throw FileTransferError.sendFileFailed(description: "Error can't create metadata")
                self.delegate?.mpcActor(self, didFailSendingFile: url, metadata: nil, to: readyPeers, error: NSError(domain: "MPCActor Error: Failed to create metadata", code: 999))
                return
            }
        }

        // Queue for waiting peers
        if !waitingPeers.isEmpty {
            print("Queuing for: \(waitingPeers.map(\.displayName))")
            pendingSends.append(PendingFileTransfer(fileURL: url, peerIDs: waitingPeers))
        }
    }
    
    func sendFileWithMetadataAndProgress(at fileURL: URL, to peer: MCPeerID, resumeFromOffset: Int64 = 0) async {
        guard let session = self.session,
              let outputStream = try? session.startStream(withName: fileURL.lastPathComponent, toPeer: peer) else {
//            throw FileTransferError.sendFileFailed(description: "StreamError: Output stream setup failed")
            self.delegate?.mpcActor(self, didFailSendingFile: fileURL, metadata: nil, to: [peer], error: NSError(domain: "MCSession Streaming Error: output stream setup failed", code: 999))
            return
        }
        
        // Copy necessary variables before entering detached task
        outputStream.schedule(in: .main, forMode: .default)
        outputStream.delegate = self
        outputStream.open()

        Task.detached(priority: .userInitiated) {
            defer {
                outputStream.close()
            }
            let contentType = await self.contentType(for: fileURL)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            let metadata = FileTransferMetadata(filename: fileURL.lastPathComponent, contentType: contentType, fileSize: fileSize, resumeOffset: resumeFromOffset)
//            let progress = Progress(totalUnitCount: Int64(fileSize))
            
            do {
                let metadataData = try JSONEncoder().encode(metadata)
                var metadataLength = UInt32(metadataData.count).bigEndian
                let metadataHeader = Data(bytes: &metadataLength, count: MemoryLayout<UInt32>.size)

                // Write the 4-byte length prefix
                // Write 4-byte metadata length
                try metadataHeader.withUnsafeBytes { buffer in
                    guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw NSError() }
                    if outputStream.write(pointer, maxLength: buffer.count) != buffer.count {
                        throw NSError(domain: "WriteError", code: 2)
                    }
                }

                let fileHandle = try FileHandle(forReadingFrom: fileURL)
                defer { try? fileHandle.close() }
                
                if resumeFromOffset > 0 {
                    try fileHandle.seek(toOffset: UInt64(resumeFromOffset))
                }
                let chunkSize = 64 * 1024
                var bytesSent: Int64 = resumeFromOffset
                self.delegate?.mpcActor(self, didStartSendingFile: fileURL, metadata: metadata, to: [peer])
                while true {
                    let data = try fileHandle.read(upToCount: chunkSize)
                    guard let chunk = data, !chunk.isEmpty else { break }
                    
                    try chunk.withUnsafeBytes { buffer in
                        guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw NSError() }
// DEBUG
//                        if bytesSent > (fileSize / 2) { // After 50% sent
//                            print("💥 Simulating network error after 50%")
//                            outputStream.close() // forcibly break the stream
//                            throw NSError(domain: "TestError", code: 999)
//                        }
// DEBUG
                        if outputStream.write(pointer, maxLength: buffer.count) != buffer.count {
                            throw NSError(domain: "WriteError", code: 3)
                        }
                    }
                    
                    bytesSent += Int64(chunk.count)
//                    progress.completedUnitCount = bytesSent
                    let fraction = Double(bytesSent) / Double(fileSize)
                    if let onProgress = self.onProgress {
                        await onProgress(fileURL.lastPathComponent, peer.displayName, fraction)
                    }
                }
                self.delegate?.mpcActor(self, didFinishSendingFile: fileURL, metadata: metadata, to: [peer])
            }
            catch {
//                throw FileTransferError.sendFileFailed(description: "WriteError: Unable to write due to \(error.localizedDescription)")
                self.delegate?.mpcActor(self, didFailSendingFile: fileURL, metadata: metadata, to: [peer], error: NSError(domain: "MCSession Streaming Error: output stream  Unable to write due to \(error.localizedDescription)", code: 999))
            }
        }
    }
    
//    private func receiveFileWithProgress(from inputStream: InputStream, metadata: FileTransferMetadata, from peer: MCPeerID) throws {
//        
//        inputStream.schedule(in: .main, forMode: .default)
//        inputStream.delegate = self
//        inputStream.open()
//        self.streamingPeer = peer
//        self.streamingMetaData = metadata
//        
//        let iStream = inputStream
//        
//        // Pass as param to avoid capturing from outer scope
//        Task.detached(priority: .userInitiated) { [weak self] in
//            guard let self else { return }
//            
//            // Now OK: you're not "capturing" it
//            do {
//                try await self.readFromStream(iStream, metadata: metadata, from: peer)
//            }
//            catch {
//                throw FileTransferError.receiveFileFailed(description: "Error reading file: \(error)")
//            }
//        }
//    }
//    
//    private func readFromStream(_ stream: InputStream, metadata: FileTransferMetadata?, from peer: MCPeerID) async throws {
//        // Read 4 bytes: metadata length
//        var lengthBuffer = [UInt8](repeating: 0, count: 4)
//        _ = stream.read(&lengthBuffer, maxLength: 4)
//        let metadataLength = Int(UInt32(bigEndian: lengthBuffer.withUnsafeBytes { $0.load(as: UInt32.self) }))
//
//        // Read metadata JSON
//        var metadataBuffer = [UInt8](repeating: 0, count: metadataLength)
//        var totalRead = 0
//        while totalRead < metadataLength {
//            metadataBuffer.withUnsafeMutableBytes { rawBuffer in
//                let pointer = rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
//                let bytesRead = stream.read(pointer.advanced(by: totalRead), maxLength: metadataLength - totalRead)
//                if bytesRead <= 0 { return }
//                totalRead += bytesRead
//            }
//        }
//
//        guard let metadata = try? JSONDecoder().decode(FileTransferMetadata.self, from: Data(metadataBuffer)) else {
//            return
//        }
//
//        // Now proceed to stream file content
//        try await self.readFileBodyStream(stream, filename: metadata.filename, metadata: metadata, from: peer)
//    }
//    
//    private func readFileBodyStream(_ stream: InputStream, filename: String, metadata: FileTransferMetadata, from peer: MCPeerID) async throws {
//        var receivedData = Data()
//        let bufferSize = 64 * 1024
//        var buffer = [UInt8](repeating: 0, count: bufferSize)
//        
////        let progress = Progress(totalUnitCount: metadata.fileSize)
//        if let (fileHandle, resumeFromOffset) = prepareForReceiving(fileMetadata: metadata, from: peer) {
//            var totalBytesReceived: Int64 = resumeFromOffset
//            
//            do {
//                try fileHandle.seek(toOffset: UInt64(resumeFromOffset))
//                
//                while stream.hasBytesAvailable {
//                    let bytesReceived = stream.read(&buffer, maxLength: bufferSize)
//                    if bytesReceived > 0 {
//                        receivedData.append(buffer, count: bytesReceived)
//                        
//                        fileHandle.write(receivedData)
//                        totalBytesReceived += Int64(bytesReceived)
//                        
////                        progress.completedUnitCount = totalBytesReceived
////                        await self.progressHandler?(progress)
//                        
//                        let fraction = Double(totalBytesReceived) / Double(metadata.fileSize)
//                        if let onProgress = self.onProgress {
//                            await onProgress(filename, peer.displayName, fraction)
//                        }
//                    }
//                    else if bytesReceived < 0 {
//                        //throw FileTransferError.receiveFileFailed(description: stream.streamError?.localizedDescription ?? "Bytes received less than zero")
//                        self.delegate?.mpcActor(self, didFailReceivingFileName: filename, metadata: metadata, from: peer, error: stream.streamError ?? NSError(domain: "Bytes received less than zero", code: 999, userInfo: nil))
//                    }
//                    else {
//                        break
//                    }
//                }
//            }
//            catch {
//                self.delegate?.mpcActor(self, didFailReceivingFileName: filename, metadata: metadata, from: peer, error: stream.streamError ?? NSError(domain: "Couldn't seek offset \(resumeFromOffset) in file handle", code: 999, userInfo: nil))
//            }
//        }
//        
//        stream.close()
//        
//        // Save to file system
//        if let destinationURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(filename) {
//            do {
//                try receivedData.write(to: destinationURL)
//                stream.close()
//                self.delegate?.mpcActor(self, didFinishReceivingFile: destinationURL, metadata: metadata, from: peer)
//            }
//            catch {
//                stream.close()
//                //throw FileTransferError.receiveFileFailed(description: error.localizedDescription)
//                self.delegate?.mpcActor(self, didFailReceivingFileName: filename, metadata: metadata, from: peer, error: stream.streamError ?? NSError(domain: "Bytes received less than zero", code: 999, userInfo: nil))
//            }
//        }
//        else {
//            //throw FileTransferError.receiveFileFailed(description: "Couldn't locate URL in caches directory")
//            self.delegate?.mpcActor(self, didFailReceivingFileName: filename, metadata: metadata, from: peer, error: NSError(domain: "Couldn't locate URL in caches directory", code: 999, userInfo: nil))
//        }
//    }
    
    private func prepareForReceiving(fileMetadata: FileTransferMetadata, from peer: MCPeerID) -> (FileHandle, Int64)? {
        if let destinationURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(fileMetadata.filename) {
            do {
                // Check if partial file exists
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
                    if let fileSize = attributes[.size] as? Int64 {
                        if fileSize < fileMetadata.fileSize {
                            // Partial file found, resume
                            let fileHandle = try FileHandle(forUpdating: destinationURL)
                            try fileHandle.seekToEnd()
                            return (fileHandle, fileSize)
                        }
                    }
                    // (Optional) if fileSize >= expectedSize, maybe delete & re-download
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                // If not exists or can't resume, create new
                FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
                let fileHandle = try FileHandle(forWritingTo: destinationURL)
                return (fileHandle, 0)
            }
            catch {
                self.delegate?.mpcActor(self, didFailReceivingFileName: fileMetadata.filename, metadata: fileMetadata, from: peer, error: NSError(domain: "File Manager Error: \(error.localizedDescription)", code: 999, userInfo: nil))
                return nil
            }
        }
        else {
//            throw FileTransferError.receiveFileFailed(description: "Can't prepare file handle for stream receiving")
            self.delegate?.mpcActor(self, didFailReceivingFileName: fileMetadata.filename, metadata: fileMetadata, from: peer, error: NSError(domain: "Can't prepare file handle for stream receiving", code: 999, userInfo: nil))
            return nil
        }
    }
    
    // MARK: - Transfer Progress
    
    func setProgressHandler(_ handler: @Sendable @escaping (Progress) -> Void) {
        self.progressHandler = handler
    }
    
    // MARK: - Pending Transfers

    func processPendingTransfers(for peerID: MCPeerID) async {
        guard let session else {
            delegate?.mpcActor(self, didFailProcessingPendingTransfersFor: peerID, error: NSError(domain: "No session available", code: 901))
            return
        }

        var updatedPendingSends: [PendingFileTransfer] = []

        for transfer in pendingSends {
            if transfer.peerIDs.contains(peerID), session.connectedPeers.contains(peerID) {
                let url = transfer.fileURL

                // Only send to that peer
                await sendFile(url: url, to: [peerID])

                // Keep transfer if other peers are pending
                let remainingPeers = transfer.peerIDs.filter { $0 != peerID }
                if !remainingPeers.isEmpty {
                    updatedPendingSends.append(PendingFileTransfer(fileURL: url, peerIDs: remainingPeers))
                }
            } else {
                updatedPendingSends.append(transfer)
            }
        }

        pendingSends = updatedPendingSends
    }
    
    
    // MARK: - Create MetaHeader
    
    func createMetadataHeader(_ url: URL) -> (data: Data?, metadata: FileTransferMetadata)? {
        let contentType = self.contentType(for: url)
        do {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let metadata = FileTransferMetadata(filename: url.lastPathComponent, contentType: contentType, fileSize: fileSize, resumeOffset: 0)
            
            let metadataData = try JSONEncoder().encode(metadata)
            var metadataLength = UInt32(metadataData.count).bigEndian
            let metadataHeader = Data(bytes: &metadataLength, count: MemoryLayout<UInt32>.size)
            return (data: metadataHeader + metadataData, metadata: metadata)
        }
        catch {
            return nil
        }
    }
    
    private func contentType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
            case "txt": return "text/plain"
            case "csv": return "text/csv"
            case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "zip": return "application/zip"
            case "archive": return "application/vnd.peertopeer.bundle"
            default: return "application/octet-stream"
        }
    }
    
    // MARK: - Handle the stream events isolated actor methods
    
    func handleStreamHasBytesAvailable(for handle: StreamHandle) async {
        guard let stream = streamRegistry[handle.objectID] as? InputStream else {
            // Handle missing or incorrect type
            return
        }
        // Send next chunk, or finish sending
        guard let streamingPeer, let streamingMetaData else { return }
        Task {
            await resumeManager.receive(stream: stream, from: streamingPeer, progressUpdate: { _progress in
                // Directly use _progress in the delegate call, no need for an intermediate variable
                self.delegate?.mpcActor(self, didUpdateProgress: _progress, metadata: streamingMetaData, forPeers: [streamingPeer])
                }, completion: { result in
                    switch result {
                    case .success(let fileURL):
                        print("File received successfully: \(fileURL.path)")
                    case .failure(let error):
                        print("Failed to receive file: \(error.localizedDescription)")
                    }
                })
        }
    }
    
    func handleStreamHasSpaceAvailable(for handle: StreamHandle) async {
       // guard let stream = inputStreams[handle] else { return }
        
        // Send next chunk, or finish sending
    }

    func handleStreamError(for handle: StreamHandle) async {
        guard let stream = streamRegistry[handle.objectID] as? InputStream else {
            // Handle missing or incorrect type
            return
        }
        // Close and cleanup
        guard let streamingPeer, let streamingMetaData else { return }
        Task {
            await resumeManager.cancelTransfer(for: streamingPeer)
            let streamError: Error = stream.streamError ??  NSError(domain: "Unknown stream error", code: 999)
            self.delegate?.mpcActor(self, didFailReceivingFileName: streamingMetaData.filename, metadata: streamingMetaData, from: streamingPeer, error: streamError)
        }
    }

    func handleStreamEnd(for handle: StreamHandle) async {
        
        // Finalize
        guard let streamingPeer, let streamingMetaData else { return }
        Task {
            let fileURL = await resumeManager.completeTransfer(for: streamingPeer)
            if let fileURL = fileURL {
                await MainActor.run {
                    delegate?.mpcActor(self, didFinishReceivingFile: fileURL, metadata: streamingMetaData, from: streamingPeer)
                }
            }
        }
    }
    
    // MARK: - Invitation
    
    func respondToInvitation(accepted: Bool, handler: @Sendable @escaping (Bool, MCSession?) -> Void
    ) {
        let sessionToUse = accepted ? self.session : nil
        handler(accepted, sessionToUse)
    }
    
    // MARK: - Accessors
    
    func setSession(_ session: MCSession) async {
        self.session = session
        session.delegate = self // Important: set delegate if handling session events here
    }

    // Optional: expose connectedPeers safely
    func connectedPeers() -> [MCPeerID] {
        session?.connectedPeers ?? []
    }
    
    func setDeviceName(_ name: String) {
        self.deviceName = name
        print("Device Name: \(name)")
    }
    
    func setPeerID() async throws {
        guard let deviceName else {
            throw FileTransferError.error(description: "Device Unavailable")
        }
        self.peerID = MCPeerID(displayName: PeerSessionManager.makeSafeDeviceName(deviceName))
    }
    
    func getSession() async throws -> MCSession {
        guard let session else {
            throw FileTransferError.error(description: "No MCSession setup yet")
        }
        return session
    }
    
    // Optional: expose connectedPeers safely
    func getConnectedPeers() -> [MCPeerID] {
        return session?.connectedPeers ?? []
    }
}

// MARK: - MCSessionDelegate

extension MPCActor: MCSessionDelegate {
    
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            print("Peer \(peerID.displayName) changed state: \(state.rawValue)")
        }
        switch state {
            case .connected:
                print("Connected to: \(peerID.displayName)")
                delegate?.mpcActor(self, didConnectTo: peerID)

                Task {
                    /*do {
                        try*/ await self.processPendingTransfers(for: peerID)
                    /*} catch {
                        print("Error processing transfers for \(peerID.displayName):", error)
                        delegate?.mpcActor(self, didFailProcessingPendingTransfersFor: peerID, error: error)
                    }*/
                }
            case .connecting:
                print("Connecting to: \(peerID.displayName)")
            case .notConnected:
                print("Disconnected from: \(peerID.displayName)")
                self.delegate?.mpcActor(self, didDisconnectFrom: peerID)
            @unknown default:
                print("Unknown state for: \(peerID.displayName)")
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            print("Received data from \(peerID.displayName): \(data.count) bytes")
        }
        // Save the file somewhere, e.g., Caches
        Task {
            let destinationURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(UUID().uuidString)
            // Read 4 bytes: metadata length
            var startIndex = data.startIndex
            var endIndex = data.index(startIndex, offsetBy: 4)
            let lengthBuffer = data[data.startIndex..<endIndex]
            let metadataLength = Int(UInt32(bigEndian: lengthBuffer.withUnsafeBytes { $0.load(as: UInt32.self) }))
            startIndex = endIndex
            endIndex = data.index(startIndex, offsetBy: Int(metadataLength))
            // Read metadata JSON
            let metadataBuffer = data[startIndex..<endIndex]
            guard let _/*metadata*/ = try? JSONDecoder().decode(FileTransferMetadata.self, from: Data(metadataBuffer)) else {
                return
            }
            do {
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destinationURL)
//                await MainActor.run {
//                    self.delegate?.peerSessionManager(self, didReceiveFile: destinationURL, data: data, metadata: metadata, filesize: UInt64(data.count), from: peerID)
//                }
            } catch {
                print("Failed to save received file: \(error)")
            }
        }
    }
    
    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        let destinationURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(streamName)
        
        let streamID = ObjectIdentifier(stream)

        // SAFELY forward work to the actor
        Task {
            await self.receive(streamID: streamID, from: peerID, destinationURL: destinationURL)
        }
    }

    
    // This method lives inside MPCActor
    func receive(streamID: ObjectIdentifier,from peerID: MCPeerID, destinationURL: URL) async {
        guard let handle = handleRegistry[streamID] else {
                print("Stream handle not registered for streamID:", streamID)
                return
            }

        do {
            let metadata = try await self.handleDidReceiveStream(for: handle, destinationURL: destinationURL)

            if let delegate, let metadata = metadata {
                await MainActor.run {
                    delegate.mpcActor(self, didFinishReceivingFile: destinationURL, metadata: metadata, from: peerID)
                }
            }
        } catch {
            print("Stream handling error:", error)
        }
    }
    
    private func handleDidReceiveStream(for handle: StreamHandle, destinationURL: URL) async throws -> FileTransferMetadata? {
        guard let stream = streamRegistry[handle.objectID] as? InputStream else {
            // Handle missing or incorrect type
            return nil
        }
          
        stream.open()
        defer { stream.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)

        guard let fileHandle = try? FileHandle(forWritingTo: destinationURL) else { return nil }
        defer { try? fileHandle.close() }

        // Read 4-byte metadata length
        var metadataLengthBuffer = [UInt8](repeating: 0, count: 4)
        try await self.readFully(for: handle/*stream: stream*/, into: &metadataLengthBuffer)

        let metadataLength = UInt32(bigEndian: metadataLengthBuffer.withUnsafeBytes { $0.load(as: UInt32.self) })

        // Read metadata
        var metadataBuffer = [UInt8](repeating: 0, count: Int(metadataLength))
        try await self.readFully(for: handle/*stream: stream*/, into: &metadataBuffer)

        let metadataData = Data(metadataBuffer)
        let metadata = try JSONDecoder().decode(FileTransferMetadata.self, from: metadataData)

        // Read data
        var totalBytesReceived = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                try fileHandle.write(contentsOf: buffer.prefix(bytesRead))
                totalBytesReceived += bytesRead
            } else if bytesRead == 0 {
                break
            } else {
                throw stream.streamError ?? NSError(domain: "StreamReadError", code: 1)
            }
        }
        return metadata
    }
    
    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        print("Receiving file: \(resourceName), progress: \(progress.fractionCompleted)")
    }
    
    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard let localURL = localURL else { return }

        if let error = error {
            print("Error receiving file: \(error.localizedDescription)")
        }
        else {
            let destinationURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(UUID().uuidString).appendingPathComponent(resourceName)
            
            try? FileManager.default.removeItem(at: destinationURL) // remove existing file if any
            try? FileManager.default.copyItem(at: localURL, to: destinationURL)
            
            print("File received and saved to: \(destinationURL)")
        }
    }
    
    // Helper function to fully fill a buffer
    private func readFully(for handle: StreamHandle/*stream: InputStream*/, into buffer: inout [UInt8]) async throws {
        guard let stream = streamRegistry[handle.objectID] as? InputStream else {
            // Handle missing or incorrect type
            return
        }
        var totalRead = 0
        let bufferSize = buffer.count // Copy size to avoid overlapping access
        while totalRead < bufferSize {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    return stream.read(baseAddress.advanced(by: totalRead), maxLength: bufferSize - totalRead)
                }
                return -1
            }
            if bytesRead > 0 {
                totalRead += bytesRead
            } else if bytesRead == 0 {
                throw NSError(domain: "StreamClosedEarly", code: 2)
            } else {
                throw stream.streamError ?? NSError(domain: "StreamReadError", code: 2)
            }
        }
    }
    
    // MARK: - MetaHeader
    
    /// Read exactly `length` bytes from the input stream into a Data buffer
    private func readExactly(_ stream: InputStream, length: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: length)
        var totalRead = 0
        
        while totalRead < length && stream.hasBytesAvailable {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    return stream.read(baseAddress.advanced(by: totalRead), maxLength: length - totalRead)
                }
                return -1
            }
            if bytesRead < 0 {
                return nil // Error occurred
            } else if bytesRead == 0 {
                break // EOF
            }
            totalRead += bytesRead
        }

        guard totalRead == length else { return nil }
        return Data(buffer)
    }
}

extension MPCActor: MCNearbyServiceAdvertiserDelegate {
    
    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @Sendable @escaping (Bool, MCSession?) -> Void) {
        print("Received invitation from \(peerID.displayName)")
        self.delegate?.mpcActor(self, didReceiveInvitationFrom: peerID, context: context, handler: invitationHandler)
    }
}

extension MPCActor: StreamDelegate {
    
    nonisolated public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        let streamID = ObjectIdentifier(aStream)
        let eventCopy = eventCode

        Task {
            await self.handleStreamEvent(eventCopy, from: streamID)
        }
    }
    
    private func handleStreamEvent(_ event: Stream.Event, from id: ObjectIdentifier) async {
        guard let handle = handleRegistry[id] else { return }

        switch event {
            case .hasBytesAvailable:
                await handleStreamHasBytesAvailable(for: handle)
            case .hasSpaceAvailable:
                await handleStreamHasSpaceAvailable(for: handle)
            case .errorOccurred:
                await handleStreamError(for: handle)
            case .endEncountered:
                await handleStreamEnd(for: handle)
            default:
                break
        }
    }

}
