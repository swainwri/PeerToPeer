//
//  ContentView.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 07/05/2025.
//


import SwiftUI

struct ContentView: View {
    @StateObject var peerSessionManager = PeerSessionManager(serviceType: "myService")

    var body: some View {
        VStack {
            Text("Peer-to-Peer Connection")
            Button("Start Browsing and Advertising") {
                // You can add methods to control browsing/advertising
            }
            Button("Send Message") {
                // You could implement sending messages here
            }
        }
        .onAppear {
            peerSessionManager.setMessageDelegate(delegate: self)
        }
    }
}

extension ContentView: MPCMessageHandler {
    func didReceiveMessage(data: Data, fromPeer peerID: MCPeerID) {
        // Handle the received message
    }

    func didReceiveFile(url: URL, fromPeer peerID: MCPeerID) {
        // Handle the received file
    }
}