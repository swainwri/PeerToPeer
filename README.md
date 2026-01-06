![PeerToPeer Logo](Peer2Peer/Assets.xcassets/AppIcon.appiconset/256.png)

# PeerToPeer / Peer2Peer

Peer-to-peer file and photo transfer examples for iOS

This repository contains two related iOS sample apps that demonstrate peer-to-peer communication between nearby devices using Apple’s frameworks.

## Projects in this repository

### 🔹 PeerToPeer (Swift 5)
A straightforward Multipeer Connectivity example written in Swift 5.
	•	Browse and connect to nearby iOS devices
	•	Select and send files or photos to a peer
	•	Uses classic delegate-based APIs
	•	Intended as a clear, minimal reference implementation

### 🔹 Peer2Peer (Swift 6)
A modernised version rewritten to be Swift 6 concurrency compliant.
	•	Uses structured concurrency and actor isolation
	•	Demonstrates safe integration of MultipeerConnectivity with Swift 6
	•	Explicit handling of async state, threading, and lifecycle
	•	Highlights the additional complexity introduced by strict concurrency rules

This version exists to show what is required to make legacy peer-to-peer APIs work correctly under Swift 6.

⸻

## Important note on reliability

These projects are provided for educational and experimental purposes.

MultipeerConnectivity (and related peer-to-peer technologies such as AirDrop) relies on opportunistic networking (Bluetooth, peer-to-peer Wi-Fi, radio power management). As a result:
	•	Peer discovery may be intermittent
	•	Connections may drop without warning
	•	Behaviour can vary between devices and iOS versions

For production apps where reliable file transfer is required, an infrastructure-based approach (e.g. Wi-Fi networking via Network.framework, HTTP, or WebSockets) is often more predictable.

⸻

## About the logo

The logo represents direct device-to-device communication:
	•	Two devices
	•	A simple, explicit connection
	•	No implication of cloud services or background magic

It reflects the intent of the project: clear examples, not abstraction-heavy solutions.

⸻

## Why this repository exists

Apple provides peer-to-peer APIs, but real-world usage—especially under Swift 6—comes with trade-offs that are rarely documented.

This repository aims to:
	•	Show working peer-to-peer examples
	•	Contrast Swift 5 vs Swift 6 approaches
	•	Help developers make informed architectural decisions
