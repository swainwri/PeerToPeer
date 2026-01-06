//
//  ResumeManager.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 27/04/2025.
//

import Foundation
import MultipeerConnectivity

final class ResumeManager {

    struct Transfer {
        let fileHandle: FileHandle
        let totalBytesExpected: Int64
        var bytesReceived: Int64
        let destinationURL: URL
        var transferID: UUID
    }
    
    struct ResumeRequest: Codable {
        let transferID: UUID
        let filename: String
        let resumeOffset: Int64
    }
    
    enum MessageKind: String {
        case metadata = "MetaData"
        case resumeRequest = "ResumeRequest"
        case transferData = "TransferData"
        case transferComplete = "TransferComplete"
        case error = "Error"
        
        // Method to parse the message kind from the data
        static func parse(data: Data) -> MessageKind? {
            // Try to convert the data to a string, then parse the prefix
            if let messageString = String(data: data, encoding: .utf8) {
                // Split the string at the first colon (:) to get the message kind part
                let components = messageString.split(separator: ":")
                
                // Check if the first component is a valid MessageKind
                if let firstComponent = components.first,
                   let kind = MessageKind(rawValue: String(firstComponent)) {
                    return kind
                }
            }
            
            // Return nil if no valid message kind is found
            return nil
        }
    }

    private var activeTransfers: [MCPeerID: Transfer] = [:]
    
    // MARK: - Start New Transfer
    
    func startTransfer(for peer: MCPeerID, metadata: FileTransferMetadata) {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(metadata.filename)

        // Create empty file if needed
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: destinationURL)
            let transfer = Transfer(fileHandle: handle, totalBytesExpected: metadata.fileSize, bytesReceived: 0, destinationURL: destinationURL, transferID: UUID())
            activeTransfers[peer] = transfer
        } catch {
            print("Failed to prepare file for receiving: \(error)")
        }
    }

    // MARK: - Handle Resume Request
    
    func handleResumeRequest(_ request: ResumeRequest, for peer: MCPeerID) {
        guard var transfer = activeTransfers[peer] else {
            print("No active transfer for peer \(peer)")
            return
        }

        do {
            try transfer.fileHandle.seek(toOffset: UInt64(request.resumeOffset))
            transfer.bytesReceived = request.resumeOffset
            activeTransfers[peer] = transfer
            print("Resumed transfer at offset: \(request.resumeOffset)")
        }
        catch {
            print("Failed to seek for resume: \(error)")
        }
    }

    // MARK: - Receive Data from Stream
    
    func receive(stream: InputStream, from peer: MCPeerID, progressUpdate: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {

        guard var transfer = activeTransfers[peer] else {
            completion(.failure(NSError(domain: "No active transfer", code: 1)))
            return
        }

        stream.open()

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: bufferSize)

                if bytesRead > 0 {
                    let dataChunk = Data(bytes: buffer, count: bytesRead)

                    do {
                        try transfer.fileHandle.write(contentsOf: dataChunk)
                        transfer.bytesReceived += Int64(bytesRead)
                        self.activeTransfers[peer] = transfer

                        let progress = Double(transfer.bytesReceived) / Double(transfer.totalBytesExpected)
                        await MainActor.run {
                            progressUpdate(progress)
                        }
                    }
                    catch {
                        let error = stream.streamError ?? NSError(domain: "Stream error", code: 2)
                        await MainActor.run {
                            completion(.failure(error))
                        }
                        return
                    }
                }
                else if bytesRead < 0 {
                    let error = stream.streamError ?? NSError(domain: "Stream error", code: 2)
                    await MainActor.run {
                        completion(.failure(error))
                    }
                    return
                }
                else {
                    // End of stream
                    break
                }
            }

            stream.close()

            do {
                try transfer.fileHandle.close()
                self.activeTransfers.removeValue(forKey: peer)
                let transferURL = transfer.destinationURL
                await MainActor.run {
                    completion(.success(transferURL))
                }
            }
            catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Cancel Transfer
    
    func cancelTransfer(for peer: MCPeerID) {
        if let transfer = activeTransfers[peer] {
            try? transfer.fileHandle.close()
            activeTransfers.removeValue(forKey: peer)
        }
    }
    
    // MARK: - Complete Transfer
    
    func completeTransfer(for peer: MCPeerID) -> URL? {
        var fileURL: URL?
        if let transfer = activeTransfers[peer] {
            fileURL = transfer.destinationURL
            try? transfer.fileHandle.close()
            activeTransfers.removeValue(forKey: peer)
        }
        return fileURL
    }
}

import Foundation

//actor ResumeManager {
//    struct ActiveTransfer {
//        var filename: String
//        var transferID: UUID
//        var peerID: String // Or MCPeerID.displayName
//        var bytesReceived: Int64
//        var resumeAttempts: Int
//    }
//
//    private var activeTransfers: [UUID: ActiveTransfer] = [:]
//    private let maxResumeAttempts = 3
//    
//    func trackNewTransfer(filename: String, transferID: UUID, peerID: String) {
//        activeTransfers[transferID] = ActiveTransfer(
//            filename: filename,
//            transferID: transferID,
//            peerID: peerID,
//            bytesReceived: 0,
//            resumeAttempts: 0
//        )
//    }
//    
//    func updateProgress(transferID: UUID, bytesReceived: Int64) {
//        guard var transfer = activeTransfers[transferID] else { return }
//        transfer.bytesReceived = bytesReceived
//        activeTransfers[transferID] = transfer
//    }
//    
//    func handleStreamError(transferID: UUID) -> ActiveTransfer? {
//        guard var transfer = activeTransfers[transferID] else { return nil }
//        
//        transfer.resumeAttempts += 1
//        if transfer.resumeAttempts > maxResumeAttempts {
//            print("🚫 Max resume attempts reached for \(transfer.filename)")
//            activeTransfers.removeValue(forKey: transferID)
//            return nil
//        } else {
//            activeTransfers[transferID] = transfer
//            print("🔄 Attempting resume #\(transfer.resumeAttempts) for \(transfer.filename)")
//            return transfer
//        }
//    }
//    
//    func completeTransfer(transferID: UUID) {
//        activeTransfers.removeValue(forKey: transferID)
//    }
//}
