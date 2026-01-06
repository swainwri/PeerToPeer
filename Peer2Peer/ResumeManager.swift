//
//  ResumeManager.swift
//  Peer2Peer
//
//  Created by Steve Wainwright on 08/05/2025.
//


import Foundation
import MultipeerConnectivity

actor ResumeManager {
    
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

        static func parse(data: Data) -> MessageKind? {
            if let messageString = String(data: data, encoding: .utf8) {
                let components = messageString.split(separator: ":")
                if let firstComponent = components.first,
                   let kind = MessageKind(rawValue: String(firstComponent)) {
                    return kind
                }
            }
            return nil
        }
    }

    private var activeTransfers: [MCPeerID: Transfer] = [:]

    private subscript(peer: MCPeerID) -> Transfer? {
        get { activeTransfers[peer] }
        set { activeTransfers[peer] = newValue }
    }

    // MARK: - Start New Transfer

    func startTransfer(for peer: MCPeerID, metadata: FileTransferMetadata) {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(metadata.filename)
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: destinationURL)
            let transfer = Transfer(
                fileHandle: handle,
                totalBytesExpected: metadata.fileSize,
                bytesReceived: 0,
                destinationURL: destinationURL,
                transferID: UUID()
            )
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
        } catch {
            print("Failed to seek for resume: \(error)")
        }
    }

    // MARK: - Receive Data from Stream
    
    func receive(stream: InputStream, from peer: MCPeerID, progressUpdate: @Sendable @escaping (Progress) -> Void, completion: @Sendable @escaping (Result<URL, Error>) -> Void) {
        Task {
            await self.receiveInternal(stream: stream, from: peer, progressUpdate: progressUpdate, completion: completion)
        }
    }

    // MARK: - Actor-isolated helper

    private func receiveInternal(stream: InputStream, from peer: MCPeerID, progressUpdate: @Sendable @escaping (Progress) -> Void, completion: @Sendable @escaping (Result<URL, Error>) -> Void ) async {
        guard var transfer = self[peer] else {
            await MainActor.run {
                completion(.failure(NSError(domain: "No active transfer", code: 1)))
            }
            return
        }

        stream.open()

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let progress = Progress(totalUnitCount: transfer.totalBytesExpected)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)

            if bytesRead > 0 {
                let dataChunk = Data(bytes: buffer, count: bytesRead)

                do {
                    try transfer.fileHandle.write(contentsOf: dataChunk)
                    transfer.bytesReceived += Int64(bytesRead)

                    self[peer] = transfer

                    progress.completedUnitCount = transfer.bytesReceived
                    await MainActor.run {
                        progressUpdate(progress)
                    }
                } catch {
                    let error = stream.streamError ?? NSError(domain: "Stream error", code: 2)
                    await MainActor.run {
                        completion(.failure(error))
                    }
                    return
                }
            } else if bytesRead < 0 {
                let error = stream.streamError ?? NSError(domain: "Stream error", code: 2)
                await MainActor.run {
                    completion(.failure(error))
                }
                return
            } else {
                // End of stream
                break
            }
        }

        stream.close()

        do {
            try transfer.fileHandle.close()
            removeTransfer(for: peer)

            let transferURL = transfer.destinationURL
            await MainActor.run {
                completion(.success(transferURL))
            }
        } catch {
            await MainActor.run {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Cancel Transfer

    func cancelTransfer(for peer: MCPeerID) async {
        if let transfer = activeTransfers[peer] {
            try? transfer.fileHandle.close()
            activeTransfers.removeValue(forKey: peer)
        }
    }

    // MARK: - Complete Transfer

    func completeTransfer(for peer: MCPeerID) async -> URL? {
        var fileURL: URL?
        if let transfer = activeTransfers[peer] {
            fileURL = transfer.destinationURL
            try? transfer.fileHandle.close()
            activeTransfers.removeValue(forKey: peer)
        }
        return fileURL
    }

    // MARK: - Accessors for actor-safe external use

    func setTransfer(_ transfer: Transfer, for peer: MCPeerID) {
        activeTransfers[peer] = transfer
    }

    func removeTransfer(for peer: MCPeerID) {
        activeTransfers.removeValue(forKey: peer)
    }
}
