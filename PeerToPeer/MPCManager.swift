//
//  MPCManager.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 23/04/2025.
//

@preconcurrency
import MultipeerConnectivity

import Foundation

struct PendingFileTransfer {
    let fileURL: URL
    let peerIDs: [MCPeerID]
}

struct FileTransferMetadata: Codable {
    let filename: String
    let contentType: String
    let fileSize: Int64
    var resumeOffset: Int64
}

@MainActor
protocol MPCManagerDelegate: AnyObject {
    func mpcManager(_ manager: MPCManager, didSendFile fileURL: URL, metadata: FileTransferMetadata, to peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didReceiveFile fileURL: URL, data: Data?, metadata: FileTransferMetadata, filesize: UInt64, from peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didStartSendingFile fileURL: URL, metadata: FileTransferMetadata, to peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didUpdateProgress progress: Double, forFile fileURL: URL, to peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didFinishSendingFile fileURL: URL, metadata: FileTransferMetadata, to peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didFailToSendFile fileURL: URL, metadata: FileTransferMetadata?, to peer: MCPeerID, error: Error)
    func mpcManager(_ manager: MPCManager, didStartReceivingFileNamed filename: String, metadata: FileTransferMetadata, from peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didUpdateProgress progress: Double, forReceivingFileNamed filename: String, from peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didFinishReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID)
    func mpcManager(_ manager: MPCManager, didFailToReceiveFileNamed filename: String, metadata: FileTransferMetadata?, from peer: MCPeerID, error: Error)
}

final class MPCManager: NSObject, @unchecked Sendable {
    
    enum MessageKind: String {
        case metadata = "Metadata"
        case resumeRequest = "ResumeRequest"
        case cancelRequest = "CancelRequest"
        case fileChunk = "FileChunk" // Optional if you ever want it
    }
    
    private let serviceType = "fileshareios"

    private(set) var peerID: MCPeerID?
    private(set) var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    var foundPeers: [MCPeerID] = []
    var onPeerDiscovered: ((_ isAvailable: Bool) -> Void)?
    weak var delegate: MPCManagerDelegate?
    
    private var pendingInvitationHandler: ((Bool, MCSession?) -> Void)?
    private var pendingPeerID: MCPeerID?
    
    private var pendingSends: [PendingFileTransfer] = []
    private var isSending = false
    
    private let resumeManager = ResumeManager()
    private var streamingPeer: MCPeerID?
    private var streamingMetaData: FileTransferMetadata?
    
    override init() {
        super.init()
        
        let originalName = UIDevice.current.name
        let safeName = originalName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        peerID = MCPeerID(displayName: safeName)
        
        if let peerID {
            session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
            session?.delegate = self
        }
    }

    func startHosting() {
        if let peerID {
            advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
            advertiser?.delegate = self
            advertiser?.startAdvertisingPeer()
        }
    }
    
    func stopHosting() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    func startBrowsing() {
        if let peerID {
            browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
            browser?.delegate = self
            browser?.startBrowsingForPeers()
        }
    }
    
    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }
    
    // MARK: Send/Receive
    
    @MainActor
    func sendFile(url fileURL: URL, to peers: [MCPeerID]) {
        guard let session else { return }
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
            if let metadataHeader = createMetadataHeader(fileURL),
               let mdata = metadataHeader.data {
                do {
                    var data = try Data(contentsOf: fileURL)
                    data.insert(contentsOf: mdata, at: data.startIndex)
                    try session.send(data, toPeers: readyPeers, with: .reliable)
                    print("Sent to: \(readyPeers.map(\.displayName))")
                    delegate?.mpcManager(self, didSendFile: fileURL, metadata: metadataHeader.metadata, to: readyPeers[0])
                }
                catch {
                    print("Error sending file: \(error)")
                    delegate?.mpcManager(self, didFailToSendFile: fileURL, metadata: metadataHeader.metadata, to: readyPeers[0], error: error)
                }
            }
            else {
                delegate?.mpcManager(self, didFailToSendFile: fileURL, metadata: nil, to: readyPeers[0], error: NSError(domain: "Can't create metadata", code: 1, userInfo: nil))
            }
        }

        // Queue for waiting peers
        if !waitingPeers.isEmpty {
            print("Queuing for: \(waitingPeers.map(\.displayName))")
            pendingSends.append(PendingFileTransfer(fileURL: fileURL, peerIDs: waitingPeers))
        }
    }
    
    @MainActor
    func sendFileWithMetadataAndProgress(at fileURL: URL, to peer: MCPeerID, resumeFromOffset: Int64 = 0) {
        guard let session = self.session,
              let outputStream = try? session.startStream(withName: fileURL.lastPathComponent, toPeer: peer) else {
            self.delegate?.mpcManager(self, didFailToSendFile: fileURL, metadata: nil, to: peer, error: NSError(domain: "StreamError", code: 1))
            return
        }
        
        // Copy necessary variables before entering detached task
        outputStream.schedule(in: .current, forMode: .default)
        outputStream.delegate = self
        outputStream.open()

        Task.detached(priority: .userInitiated) {
            defer {
                outputStream.close()
            }
            let contentType = self.contentType(for: fileURL)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            let metadata = FileTransferMetadata(filename: fileURL.lastPathComponent, contentType: contentType, fileSize: fileSize, resumeOffset: resumeFromOffset)

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

                await self.delegate?.mpcManager(self, didStartSendingFile: fileURL, metadata: metadata, to: peer)

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
                    let progress = Double(bytesSent) / Double(fileSize)
                    await self.delegate?.mpcManager(self, didUpdateProgress: progress, forFile: fileURL, to: peer)
                }

                await self.delegate?.mpcManager(self, didFinishSendingFile: fileURL, metadata: metadata, to: peer)
            }
            catch {
                await self.delegate?.mpcManager(self, didFailToSendFile: fileURL, metadata: metadata, to: peer, error: error)
            }
        }
    }
   
    private func receiveFileWithProgress(from inputStream: InputStream, metadata: FileTransferMetadata, from peer: MCPeerID) {
        inputStream.schedule(in: .current, forMode: .default)
        inputStream.delegate = self
        inputStream.open()
        self.streamingPeer = peer
        self.streamingMetaData = metadata
        
        // Pass as param to avoid capturing from outer scope
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            
            // Now OK: you're not "capturing" it
            do {
                try await self.readFromStream(inputStream, metadata: metadata, from: peer)
            }
            catch {
                print("Error reading file: \(error)")
            }
        }
    }
    
    private func readFromStream(_ stream: InputStream, metadata: FileTransferMetadata?, from peer: MCPeerID) async throws {
        // Read 4 bytes: metadata length
        var lengthBuffer = [UInt8](repeating: 0, count: 4)
        _ = stream.read(&lengthBuffer, maxLength: 4)
        let metadataLength = Int(UInt32(bigEndian: lengthBuffer.withUnsafeBytes { $0.load(as: UInt32.self) }))

        // Read metadata JSON
        var metadataBuffer = [UInt8](repeating: 0, count: metadataLength)
        var totalRead = 0
        while totalRead < metadataLength {
            metadataBuffer.withUnsafeMutableBytes { rawBuffer in
                let pointer = rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let bytesRead = stream.read(pointer.advanced(by: totalRead), maxLength: metadataLength - totalRead)
                if bytesRead <= 0 { return }
                totalRead += bytesRead
            }
        }

        guard let metadata = try? JSONDecoder().decode(FileTransferMetadata.self, from: Data(metadataBuffer)) else {
            return
        }

        // Now proceed to stream file content
        try await self.readFileBodyStream(stream, filename: metadata.filename, metadata: metadata, from: peer)
    }
    
    private func readFileBodyStream(_ stream: InputStream, filename: String, metadata: FileTransferMetadata, from peer: MCPeerID) async throws {
        var receivedData = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        let (fileHandle, resumeFromOffset) = try prepareForReceiving(fileMetadata: metadata, from: peer)
        
        var totalBytesReceived: Int64 = resumeFromOffset
        
        try fileHandle.seek(toOffset: UInt64(resumeFromOffset))
        
        await MainActor.run {
            self.delegate?.mpcManager(self, didStartReceivingFileNamed: filename, metadata: metadata, from: peer)
        }

        while stream.hasBytesAvailable {
            let bytesReceived = stream.read(&buffer, maxLength: bufferSize)
            if bytesReceived > 0 {
                receivedData.append(buffer, count: bytesReceived)
                
                fileHandle.write(receivedData)
                totalBytesReceived += Int64(bytesReceived)

                let progress = Double(totalBytesReceived) / Double(metadata.fileSize)
                await self.delegate?.mpcManager(self, didUpdateProgress: progress, forReceivingFileNamed: filename, from: peer)
            }
            else if bytesReceived < 0 {
                await self.delegate?.mpcManager(self, didFailToReceiveFileNamed: filename, metadata: metadata, from: peer, error: stream.streamError ?? NSError(domain: "Unknown Error", code: 1, userInfo: nil))
                return
            }
            else {
                break
            }
        }

        stream.close()
        
        // Save to file system
        if let destinationURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(filename) {
            do {
                try receivedData.write(to: destinationURL)
                stream.close()
                await self.delegate?.mpcManager(self, didFinishReceivingFile: destinationURL, metadata: metadata, from: peer)
            }
            catch {
                stream.close()
                await self.delegate?.mpcManager(self, didFailToReceiveFileNamed: filename, metadata: metadata, from: peer, error: error)
            }
        }
        else {
            await self.delegate?.mpcManager(self, didFailToReceiveFileNamed: filename, metadata: metadata, from: peer, error: NSError(domain: "Unknown Error", code: 1, userInfo: nil))
        }
    }
    
    private func prepareForReceiving(fileMetadata: FileTransferMetadata, from peer: MCPeerID) throws -> (FileHandle, Int64) {
        if let destinationURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(fileMetadata.filename) {
            
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
        else {
            throw NSError(domain: "Can't prepare file handle", code: 1, userInfo: nil)
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
    
    // MARK: - Invitations
    
    func invitePeer(_ peer: MCPeerID) {
        if let session {
            browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        }
    }
    
    func clearPendingInvitation() {
        self.pendingInvitationHandler = nil
        self.pendingPeerID = nil
    }
        
    // MARK: - Transfers
    
    @MainActor
    func processPendingTransfers(for peerID: MCPeerID) {
        guard let session = session else { return }

        var stillPending: [PendingFileTransfer] = []

        for transfer in pendingSends {
            if transfer.peerIDs.contains(peerID), session.connectedPeers.contains(peerID) {
                let url = transfer.fileURL
                if let metadataHeader = createMetadataHeader(url),
                   let mdata = metadataHeader.data {
                    do {
                        var data = try Data(contentsOf: url)
                        data.insert(contentsOf: mdata, at: data.startIndex)
                        
                        try session.send(data, toPeers: [peerID], with: .reliable)
                        print("Sent pending file to \(peerID.displayName)")
                        self.delegate?.mpcManager(self, didSendFile: url, metadata: metadataHeader.metadata, to: peerID)
                    }
                    catch {
                        print("Error sending pending file to \(peerID.displayName): \(error)")
                        self.delegate?.mpcManager(self, didFailToSendFile: url, metadata: metadataHeader.metadata, to: peerID, error: error)
                    }
                }
                else {
                    self.delegate?.mpcManager(self, didFailToSendFile: url, metadata: nil, to: peerID, error: NSError(domain: "Can't create metadata", code: 1, userInfo: nil))
                }
                // If more peers are waiting, keep the transfer
                let remainingPeers = transfer.peerIDs.filter { $0 != peerID }
                if !remainingPeers.isEmpty {
                    stillPending.append(PendingFileTransfer(fileURL: url, peerIDs: remainingPeers))
                }
            }
            else {
                stillPending.append(transfer)
            }
        }

        pendingSends = stillPending
    }
    
    // MARK: - create MetaHeader
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
}

// MARK: - Extensions

extension MPCManager: MCSessionDelegate {
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        print("Receiving file: \(resourceName), progress: \(progress.fractionCompleted)")
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard let localURL = localURL else { return }

        let destinationURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(UUID().uuidString).appendingPathComponent(resourceName)
        
        try? FileManager.default.removeItem(at: destinationURL) // remove existing file if any
        try? FileManager.default.copyItem(at: localURL, to: destinationURL)

        print("File received and saved to: \(destinationURL)")
    }

    // Empty implementations for protocol completeness
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
            case .connected:
                print("Connected to: \(peerID.displayName)")
                Task {
                    await processPendingTransfers(for: peerID)
                }
            case .connecting:
                print("Connecting to: \(peerID.displayName)")
            case .notConnected:
                print("Disconnected from: \(peerID.displayName)")
            @unknown default:
                print("Unknown state for: \(peerID.displayName)")
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
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
            guard let metadata = try? JSONDecoder().decode(FileTransferMetadata.self, from: Data(metadataBuffer)) else {
                return
            }
            do {
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destinationURL)
                await MainActor.run {
                    self.delegate?.mpcManager(self, didReceiveFile: destinationURL, data: data, metadata: metadata, filesize: UInt64(data.count), from: peerID)
                }
            } catch {
                print("Failed to save received file: \(error)")
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        
//        if let receivedString = String(data: data, encoding: .utf8) {
//            if receivedString.hasPrefix("\(MessageKind.resumeRequest.rawValue):") {
//                if resumeAttempts[request.transferID, default: 0] < maxResumeAttempts {
//                    resumeAttempts[request.transferID, default: 0] += 1
//                    let jsonString = receivedString.dropFirst("\(MessageKind.resumeRequest.rawValue):".count)
//                    if let jsonData = jsonString.data(using: .utf8) {
//                        let request = try JSONDecoder().decode(ResumeRequest.self, from: jsonData)
//                        handleResumeRequest(request, from: peerID)
//                    }
//                }
//                else {
//                    // ❌ Too many retries, fail the transfer cleanly
//                    await delegate?.mpcManager(self, didFailToResumeFile: filename, error: ResumeError.tooManyAttempts)
//                }
//            }
//        }
        
        Task {
            stream.delegate = self
            stream.open()

            let destinationURL = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(streamName)

            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            guard let fileHandle = try? FileHandle(forWritingTo: destinationURL) else { return }

            defer {
                stream.close()
                try? fileHandle.close()
            }

            // Read 4 bytes for metadata length
            var metadataLengthBuffer = [UInt8](repeating: 0, count: 4)
            try readFully(stream: stream, into: &metadataLengthBuffer)

            let metadataLength = UInt32(bigEndian: metadataLengthBuffer.withUnsafeBytes { $0.load(as: UInt32.self) })

            // Read metadata payload
            var metadataBuffer = [UInt8](repeating: 0, count: Int(metadataLength))
            try readFully(stream: stream, into: &metadataBuffer)

            let metadataData = Data(metadataBuffer)
            let metadata = try JSONDecoder().decode(FileTransferMetadata.self, from: metadataData)

            var totalBytesReceived = 0
            let chunkSize = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: chunkSize)

            while true {
                let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0 {
                    try fileHandle.write(contentsOf: buffer.prefix(bytesRead))
                    totalBytesReceived += bytesRead
                } else if bytesRead == 0 {
                    // EOF
                    break
                } else {
                    throw stream.streamError ?? NSError(domain: "StreamReadError", code: 1)
                }
            }

            await self.delegate?.mpcManager(self, didReceiveFile: destinationURL, data: nil, metadata: metadata, filesize: UInt64(totalBytesReceived), from: peerID)
        }
    }

    // Helper function to fully fill a buffer
    private func readFully(stream: InputStream, into buffer: inout [UInt8]) throws {
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

// MARK: - Extensions

extension MPCManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task {
            if !foundPeers.contains(peerID) {
                foundPeers.append(peerID)
                await MainActor.run {
                    self.onPeerDiscovered?(true)
                }
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task {
            if let index = foundPeers.firstIndex(of: peerID) {
                foundPeers.remove(at: index)
                await MainActor.run {
                    self.onPeerDiscovered?(false)
                }
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Browsing failed: \(error.localizedDescription)")
    }
}

extension MPCManager: MCNearbyServiceAdvertiserDelegate {
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Advertising failed: \(error.localizedDescription)")
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("Advertising did receive invitation from \(peerID.displayName)")
            
        // Store handler and peer
        self.pendingInvitationHandler = invitationHandler
        self.pendingPeerID = peerID
            
        Task { [weak self] in
            guard let self else { return }
            let peerID = peerID
            let handler = invitationHandler
            guard let session = self.session, let delegate = self.delegate else { return }
            
            await MainActor.run {
                guard let viewController = delegate as? UIViewController else { return }

                let alert = UIAlertController(title: "Connection Request",
                                              message: "\(peerID.displayName) wants to connect.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Accept", style: .default) { _ in
                    handler(true, session)
                    self.clearPendingInvitation()
                })
                alert.addAction(UIAlertAction(title: "Decline", style: .cancel) { _ in
                    handler(false, nil)
                    self.clearPendingInvitation()
                })

                viewController.present(alert, animated: true)
            }
        }
    }
}

extension MPCManager: StreamDelegate {
    
    nonisolated func stream(_ stream: Stream, handle event: Stream.Event) {
        
        guard stream is InputStream else { return }
        guard let streamingPeer, let streamingMetaData else { return }
        switch event {
            case .hasBytesAvailable:
                Task {
                    resumeManager.receive(stream: stream as! InputStream, from: streamingPeer, progressUpdate: { _progress in
                        // Directly use _progress in the delegate call, no need for an intermediate variable
                        Task { @MainActor in
                            self.delegate?.mpcManager(self, didUpdateProgress: _progress, forReceivingFileNamed: streamingMetaData.filename, from: streamingPeer)
                        }
                    }, completion: { result in
                        switch result {
                        case .success(let fileURL):
                            print("File received successfully: \(fileURL.path)")
                        case .failure(let error):
                            print("Failed to receive file: \(error.localizedDescription)")
                        }
                    })
                }

            case .endEncountered:
                Task {
//                    do {
                        let fileURL = resumeManager.completeTransfer(for: streamingPeer)
                        if let fileURL = fileURL {
                            await MainActor.run {
                                delegate?.mpcManager(self, didFinishReceivingFile: fileURL, metadata: streamingMetaData, from: streamingPeer)
                            }
                        }
//                    }
//                    catch {
//                        await MainActor.run {
//                            delegate?.mpcManager(self, didFailToReceiveFileNamed: "unknown", metadata: streamingMetaData, from: streamingPeer, error: error)
//                        }
//                    }
                }
            case .errorOccurred:
                Task {
                    resumeManager.cancelTransfer(for: streamingPeer)
                    let streamError: Error = stream.streamError ??  NSError(domain: "Unknown stream error", code: 999)
                    await MainActor.run {
                        delegate?.mpcManager(self, didFailToReceiveFileNamed: "unknown", metadata: streamingMetaData, from: streamingPeer, error: streamError)
                    }
                }
            default:
                break
        }
    }
    
}

