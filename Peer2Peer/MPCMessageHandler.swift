//
//  MPCMessageHandler.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 06/05/2025.
//
import Foundation
import MultipeerConnectivity

// MARK: - Codable Message

/// A serializable message model
struct MPCMessage: Codable {
    enum MessageType: String, Codable {
        case hello
        case text
        case fileTransferRequest
        case fileTransferResponse
    }

    let type: MessageType
    let payload: String
}

protocol MPCMessageHandler {
    func mpcMessagingHandler(didReceiveMessage data: Data, fromPeer peerID: MCPeerID)
    func mpcMessagingHandler(didReceiveFile url: URL, fromPeer peerID: MCPeerID)
}

// MARK: - MPCMessagingHandler

final class MPCMessagingHandler: NSObject, MCSessionDelegate {
    private let session: MCSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: MCSession) {
        self.session = session
        super.init()
        self.session.delegate = self
    }

    func sendMessage(_ message: MPCMessage, to peers: [MCPeerID]? = nil) {
        do {
            let data = try encoder.encode(message)
            let targetPeers = peers ?? session.connectedPeers
            try session.send(data, toPeers: targetPeers, with: .reliable)
        } catch {
            print("Failed to send message: \(error.localizedDescription)")
        }
    }

    private func handleReceivedMessage(_ message: MPCMessage, from peer: MCPeerID) {
        switch message.type {
        case .hello:
            print("Received hello from \(peer.displayName): \(message.payload)")
        case .text:
            print("Received text from \(peer.displayName): \(message.payload)")
        case .fileTransferRequest:
            print("File transfer request: \(message.payload)")
        case .fileTransferResponse:
            print("File transfer response: \(message.payload)")
        }
    }

    // MARK: - MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("Peer \(peerID.displayName) changed state: \(state.rawValue)")
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let message = try decoder.decode(MPCMessage.self, from: data)
            handleReceivedMessage(message, from: peerID)
        } catch {
            print("Failed to decode message: \(error.localizedDescription)")
        }
    }

    // MARK: - Unused MCSessionDelegate

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true) // Accept all peers by default (you can customize this)
    }
}
