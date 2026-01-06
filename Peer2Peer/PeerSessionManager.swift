//
//  MPCMessage.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 07/05/2025.
//


import Foundation
@preconcurrency import MultipeerConnectivity


/// Stream metadata, in case you want to use structured stream management later
struct StreamMetadata: Codable, Sendable {
    let filename: String
    let contentType: String
    let filesize: Int
    var resumeOffset: Int
}

struct FileTransferMetadata: Codable {
    let filename: String
    let contentType: String
    let fileSize: Int64
    var resumeOffset: Int64
}


protocol PeerSessionManagerDelegate: AnyObject {
    func peerSessionManager(_ manager: PeerSessionManager?, didUpdateStatus status: String, filename: String?, with peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didConnectTo peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didDisconnectFrom peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didFindPeer peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didLosePeer peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didChangeState state: MCSessionState, with peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didSendFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID])
    func peerSessionManager(_ manager: PeerSessionManager?, didReceiveFile url: URL, metadata: FileTransferMetadata, from peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didStartSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID])
    func peerSessionManager(_ manager: PeerSessionManager?, didUpdateProgress progress: Progress, forSendingFileNamed filename: String, to peers: [MCPeerID])
    func peerSessionManager(_ manager: PeerSessionManager?, didFinishSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID])
    func peerSessionManager(_ manager: PeerSessionManager?, didFailToSendFile fileURL: URL, metadata: FileTransferMetadata?, to peers: [MCPeerID]?, error: Error)
    func peerSessionManager(_ manager: PeerSessionManager?, didStartReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didUpdateProgress progress: Progress, forReceivingFileNamed filename: String, from peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didFinishReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID)
    func peerSessionManager(_ manager: PeerSessionManager?, didFailToReceiveFile fileURL: URL, metadata: FileTransferMetadata?, from peer: MCPeerID?, error: Error)
}

/// Handles peer-to-peer sessions, messaging, and file streaming.
final class PeerSessionManager: NSObject, ObservableObject, @unchecked Sendable {
    
    var onPeerDiscovered: ((_ isAvailable: Bool) -> Void)?
    var onInvitationReceived: ((String, UIViewController, @escaping (Bool) -> Void) -> Void)?
    var progressForPeer: [MCPeerID: Progress] = [:]
    
    @MainActor
    var onProgress: ((_ filename: String, _ peerName: String, _ progress: Double) -> Void)?
    
    private var serviceType: String?
    private var peerID: MCPeerID?
    private(set) var session: MCSession?
    private var serviceAdvertiser: MCNearbyServiceAdvertiser?
    private var serviceBrowser: MCNearbyServiceBrowser?

    private var discoveredPeers: [MCPeerID] = []
    private var hostName: String?
    
    public var mpcActor: MPCActor?
    private var messageDelegate: MPCMessageHandler?
    private var delegate: PeerSessionManagerDelegate?
    

    override init() {
        super.init()
    }

    func setup() async {
        // Fetch hostName synchronously for use in peerID
        let name = await UIDevice.current.name
        self.hostName = name
        self.peerID = MCPeerID(displayName: PeerSessionManager.makeSafeDeviceName(name))

        let defaultServiceType: String = {
            let raw = (Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])?.first ?? "_fallback._tcp"
            let trimmed = raw
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                .components(separatedBy: ".")
                .first ?? "fallback"
            return trimmed.lowercased()
        }()
        self.serviceType = defaultServiceType

        guard let peerID = self.peerID, let serviceType = self.serviceType else { return }

        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        self.serviceBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        
        self.mpcActor = MPCActor()
        
        self.serviceBrowser?.delegate = self
        if let mpcActor {
            self.serviceAdvertiser?.delegate = mpcActor
            self.wireProgressCallback(from: mpcActor)
        }
    }
    
    @MainActor
    func start() async {
        guard let session else {
            print("session not set")
            return
        }
        
        self.serviceAdvertiser?.startAdvertisingPeer()
        self.serviceBrowser?.startBrowsingForPeers()
        
        // Now it's safe to use async work
//        Task {
            await self.setMessageDelegate(delegate: self)
            self.mpcActor?.delegate = self
            await self.mpcActor?.setup()
            await self.mpcActor?.setSession(session)
            await self.mpcActor?.start()
            await MainActor.run {
                self.delegate?.peerSessionManager(self, didUpdateStatus: "Started browsing and advertising.", filename: nil, with: peerID ?? MCPeerID(displayName: "Unknown"))
            }
//        }
    }
    
    func stop() {
        self.serviceAdvertiser?.stopAdvertisingPeer()
        self.serviceBrowser?.stopBrowsingForPeers()
        
        Task {
            await self.mpcActor?.stop()
            await MainActor.run {
                self.delegate?.peerSessionManager(self, didUpdateStatus: "Stopped browsing and advertising.", filename: nil, with: peerID ?? MCPeerID(displayName: "Unknown"))
            }
        }
    }
 
    func send(message: String) {
        Task {
//            do {
                /*try*/ await mpcActor?.sendMessage(message, to: discoveredPeers)
//            }
//            catch let error as FileTransferError {
//                print(error)
//            }
        }
    }
    
    func send(message: MPCMessage, to peers: [MCPeerID]? = nil) async throws {
        guard let session = session else { throw FileTransferError.unknown("Session not started." as! Error) }
        let data = try JSONEncoder().encode(message)
        do {
            try session.send(data, toPeers: peers ?? session.connectedPeers, with: .reliable)
        }
        catch let error as FileTransferError {
            print("Error sending message: \(error)")
        }
    }
    
    func startSendingStream(filename: String, to peer: MCPeerID) throws -> OutputStream {
        guard let session = session else { throw FileTransferError.unknown("Session not started." as! Error) }
        let stream = try session.startStream(withName: filename, toPeer: peer)
        stream.schedule(in: .current, forMode: .default)
        stream.open()
        return stream
    }
    
    // MARK: - Invitations
    
    func invitePeer(_ peer: MCPeerID, context: Data? = nil) {
        guard let session = session else { print("Session not started."); return }
        self.serviceBrowser?.invitePeer(peer, to: session, withContext: context, timeout: 15)
    }
    
    func clearPendingInvitation() {
        //        self.pendingInvitationHandler = nil
        //        self.pendingPeerID = nil
    }
    
    // MARK: - Progress
    
    func wireProgressCallback(from actor: MPCActor) {
        actor.onProgress = { [weak self] filename, peerName, progress in
            guard let strongSelf = self else { return }
            await MainActor.run {
//                self?.onProgress?(filename, peerName, progress)
                strongSelf.onProgress?(filename, peerName, progress)
            }
        }
    }
    
    @MainActor
    private func handleProgress(filename: String, peerName: String, progress: Double) {
        onProgress?(filename, peerName, progress)
    }
    
    // MARK: - Administrative Work
    
    func setDelegate(delegate: PeerSessionManagerDelegate?) async {
        self.delegate = delegate
    }
    
    func getDiscoveredPeers() async -> [MCPeerID] {
        let peers: [MCPeerID] = self.discoveredPeers
        return peers
    }
    
    private func setMessageDelegate(delegate: MPCMessageHandler?) async {
        self.messageDelegate = delegate
    }
    
    private func fetchDeviceName() {
        Task {
            self.hostName = await mpcActor?.deviceName
            print("Device Name: \(hostName ?? "Unknown")")
        }
    }
    
    static func makeSafeDeviceName(_ rawName: String?) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(.whitespaces)
        if let safeName = rawName?
            .components(separatedBy: allowedCharacters.inverted)
            .joined()
            .replacingOccurrences(of: " ", with: "-")
            .lowercased() {
            
            return safeName
        }
        else {
            return UUID().uuidString
        }
    }
}

//// MARK: - MCSessionDelegate
//extension PeerSessionManager: MCSessionDelegate {
//    
//    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
//        Task {
//            print("Peer \(peerID.displayName) state changed to \(state.rawValue)")
//            switch state {
//            case .connected:
//                print("Connected to: \(peerID.displayName)")
//            case .connecting:
//                print("Connecting to: \(peerID.displayName)")
//            case .notConnected:
//                print("Disconnected from: \(peerID.displayName)")
//            @unknown default:
//                print("Unknown state for: \(peerID.displayName)")
//            }
//        }
//    }
//    
//    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
//        Task {
//            if let message = try? JSONDecoder().decode(MPCMessage.self, from: data) {
//                print("Received message from \(peerID.displayName): \(message)")
//            } else {
//                print("Received unknown data from \(peerID.displayName)")
//            }
//        }
//    }
//    
//    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
//        print("Received stream: \(streamName) from \(peerID.displayName)")
//        
//        // Schedule and open the stream synchronously (outside Task)
//        stream.schedule(in: .current, forMode: .default)
//        stream.open()
//        
//        // Perform async reading inside a Task
//        Task {
//            await readIncomingStream(stream, from: peerID, name: streamName)
//        }
//    }
//    
//    private func readIncomingStream(_ stream: InputStream, from peerID: MCPeerID, name: String) async {
//        let bufferSize = 4096
//        var data = Data()
//        var buffer = [UInt8](repeating: 0, count: bufferSize)
//        
//        while stream.hasBytesAvailable {
//            let read = stream.read(&buffer, maxLength: bufferSize)
//            if read > 0 {
//                data.append(buffer, count: read)
//            } else if read == 0 {
//                break
//            } else if read < 0 {
//                print("Error reading stream: \(stream.streamError?.localizedDescription ?? "Unknown")")
//                break
//            }
//        }
//        
//        stream.close()
//        print("Finished reading stream \(name) from \(peerID.displayName), size: \(data.count) bytes")
//    }
//    
//    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
//    
//    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
//    
//    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
//                             certificateHandler: @escaping (Bool) -> Void) {
//        certificateHandler(true)
//    }
//}

// MARK: - MCNearbyService Advertiser Delegate

extension PeerSessionManager: MCNearbyServiceAdvertiserDelegate {
    
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("Advertising did receive invitation from \(peerID.displayName)")
        // Store handler and peer
        //        self.pendingInvitationHandler = invitationHandler
        //        self.pendingPeerID = peerID
//        Task { @MainActor in
//            guard let viewController = delegate as? UIViewController else { return }
//            let session = self.session
//            let alert = UIAlertController(title: "Connection Request",
//                                          message: "\(peerID.displayName) wants to connect.",
//                                          preferredStyle: .alert)
//            
//            alert.addAction(UIAlertAction(title: "Accept", style: .default) { _ in
//                invitationHandler(true, session)
//                // self.clearPendingInvitation()  // If needed
//            })
//            
//            alert.addAction(UIAlertAction(title: "Decline", style: .cancel) { _ in
//                invitationHandler(false, nil)
//                // self.clearPendingInvitation()  // If needed
//            })
//            
//            viewController.present(alert, animated: true)
//        }
//        Task {
//            let accepted = await showInvitationAlert(from: peerID.displayName)
//            invitationHandler(accepted, accepted ? self.session : nil)
//        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            print("Failed to advertise: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCNearbyService Browser Delegate

extension PeerSessionManager: MCNearbyServiceBrowserDelegate {
    
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor in
            print("Found peer: \(peerID.displayName)")
            if !self.discoveredPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
            self.onPeerDiscovered?(true)
        }
    }
    
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let _peerID = peerID
        Task { @MainActor in
            print("Lost peer: \(_peerID.displayName)")
            self.discoveredPeers.removeAll { $0 == _peerID }
            self.onPeerDiscovered?(false)
        }
    }
    
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            print("Failed to browse: \(error.localizedDescription)")
        }
    }
}

extension PeerSessionManager: MPCActorDelegate {
    
    nonisolated func mpcActor(_ actor: MPCActor, didConnectTo peer: MCPeerID) {
        self.delegate?.peerSessionManager(self, didConnectTo: peer)
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didDisconnectFrom peer: MCPeerID) {
        self.delegate?.peerSessionManager(self, didDisconnectFrom: peer)
    }

    nonisolated func mpcActor(_ actor: MPCActor, didReceiveInvitationFrom peer: MCPeerID, context: Data?, handler: @escaping @Sendable (Bool, MCSession?) -> Void
    ) {
        // Capture all values before entering async context
        let peerDisplayName = peer.displayName
        let wrappedHandler: @Sendable (Bool, MCSession?) -> Void = { accepted, session in
            handler(accepted, session)
        }

        let invitationHandler = self.onInvitationReceived
        
        Task { @MainActor in
            let presentingVC =  await actor.presentingViewController?()
            guard let viewController = presentingVC else {
                wrappedHandler(false, nil)
                return
            }

            if let invitationHandler {
                invitationHandler(peerDisplayName, viewController) { accepted in
                    Task {
                        await actor.respondToInvitation(accepted: accepted, handler: wrappedHandler)
                    }
                }
            } else {
                wrappedHandler(false, nil)
            }
        }
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didFailSendingMessage message: String, to peers: [MCPeerID]?, error: any Error) {
        
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didFailReceivingMessage message: String, from peer: MCPeerID?, error: any Error) {
        
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didUpdateProgress progress: Progress, metadata: FileTransferMetadata, forPeers peers: [MCPeerID]) {
        guard let session = self.session else {
            print( "Session is not set")
            return
        }
        if peers.contains(where: { $0 == session.myPeerID }) {
            self.delegate?.peerSessionManager(self, didUpdateProgress: progress, forSendingFileNamed: metadata.filename, to: peers)
        }
        else {
            self.delegate?.peerSessionManager(self, didUpdateProgress: progress, forReceivingFileNamed: metadata.filename, from: peers[0])
        }
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didStartSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID]) {
        self.delegate?.peerSessionManager(self, didStartSendingFile: fileURL, metadata: metadata, to: peers)
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didFinishSendingFile fileURL: URL, metadata: FileTransferMetadata, to peers: [MCPeerID]) {
        self.delegate?.peerSessionManager(self, didFinishSendingFile: fileURL, metadata: metadata, to: peers)
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didStartReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID) {
        self.delegate?.peerSessionManager(self, didStartReceivingFile: fileURL, metadata: metadata, from: peer)
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didFinishReceivingFile fileURL: URL, metadata: FileTransferMetadata, from peer: MCPeerID) {
        self.delegate?.peerSessionManager(self, didFinishReceivingFile: fileURL, metadata: metadata, from: peer)
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didFailSendingFile fileURL: URL, metadata: FileTransferMetadata?, to peers: [MCPeerID]?, error: Error) {
        self.delegate?.peerSessionManager(self, didFailToSendFile: fileURL, metadata: metadata, to: peers, error: error)
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didFailReceivingFileName fileName: String, metadata: FileTransferMetadata?, from peer: MCPeerID?, error: Error) {
        self.delegate?.peerSessionManager(self, didFailToReceiveFile: URL(fileURLWithPath: fileName), metadata: metadata, from: peer, error: error)
    }
    
    nonisolated func mpcActor(_ actor: MPCActor, didFailProcessingPendingTransfersFor peer: MCPeerID, error: Error) {
        
    }
}

// MARK: - MPCMessageHandler Delegate methods
extension PeerSessionManager: MPCMessageHandler {
    
    nonisolated func mpcMessagingHandler(didReceiveMessage data: Data, fromPeer peerID: MCPeerID) {
        guard let localPeerID = self.peerID else {
            print("peerID not set")
            return
        }
        self.messageDelegate?.mpcMessagingHandler(didReceiveMessage: data, fromPeer: peerID)
        let message = String(decoding: data, as: UTF8.self)
        self.delegate?.peerSessionManager(self, didUpdateStatus: "Message from \(peerID.displayName): \(message)", filename: nil, with: localPeerID)
    }
    
    nonisolated func mpcMessagingHandler(didReceiveFile url: URL, fromPeer peerID: MCPeerID) {
        guard let localPeerID = self.peerID else {
            print("peerID not set")
            return
        }
        self.messageDelegate?.mpcMessagingHandler(didReceiveFile: url, fromPeer: peerID)
        self.delegate?.peerSessionManager(self, didUpdateStatus: "Received file from \(peerID.displayName)", filename: url.lastPathComponent, with: localPeerID)
    }
}
