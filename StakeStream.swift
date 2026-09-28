// StakeStream.swift
// Headless Air-Gap Poker HUD Engine for J4 Clubs Live Streaming
// Zero on-screen windows. Zero chance of OBS stream leaks.
//
// Architecture:
// 1. Core Vision & AI: Apple Vision OCR + Local Qwen 2.5 on LM Studio (via StakeNativeWatcher)
// 2. Air-Gap Web Dashboard: Embedded HTTP server on port 8765 for Mac mini / iPhone / iPad
// 3. OBS Scene Controller: WebSocket v5 listener auto-pauses OCR on BRB/Away scenes
// 4. AirPod Whisper: Client-side Web Speech API speaks directly into AirPod connected to phone/remote Mac

import AppKit
import Combine
import CryptoKit
import Foundation
import SQLite3
import Vision

// MARK: - OBS WebSocket v5 Scene Controller

final class OBSSceneController {
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL
    private let onSceneChange: (String) -> Void
    private var isConnected = false
    private(set) var currentScene: String = "OBS Disconnected"
    private var shouldReconnect = true

    init(host: String = "127.0.0.1", port: Int = 4455, onSceneChange: @escaping (String) -> Void) {
        self.url = URL(string: "ws://\(host):\(port)")!
        self.onSceneChange = onSceneChange
    }

    func start() {
        connect()
    }

    func stop() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func connect() {
        guard shouldReconnect else { return }
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        listen()
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                if self.isConnected {
                    print("⚠️  [OBS WebSocket] Disconnected. Will retry in 5s...")
                }
                self.isConnected = false
                self.currentScene = "OBS Offline"
                DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    self?.connect()
                }
            case .success(let message):
                self.handleMessage(message)
                self.listen()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else { return }

        // OpCode 0: Hello from OBS
        if op == 0 {
            // OpCode 1: Identify — subscribe to Scenes (bit 2 = 4)
            let identify: [String: Any] = [
                "op": 1,
                "d": [
                    "rpcVersion": 1,
                    "eventSubscriptions": 4 // Scenes
                ]
            ]
            if let idData = try? JSONSerialization.data(withJSONObject: identify),
               let idStr = String(data: idData, encoding: .utf8) {
                webSocketTask?.send(.string(idStr)) { _ in }
            }
            isConnected = true
            currentScene = "OBS Connected"
            print("🎬 [OBS WebSocket] Connected & Subscribed to Scene Events (ws://127.0.0.1:4455)")
        } else if op == 5 {
            // OpCode 5: Event
            guard let d = json["d"] as? [String: Any],
                  let eventType = d["eventType"] as? String,
                  eventType == "CurrentProgramSceneChanged",
                  let eventData = d["eventData"] as? [String: Any],
                  let sceneName = eventData["sceneName"] as? String else { return }

            self.currentScene = sceneName
            print("🎬 [OBS Scene Changed] → '\(sceneName)'")
            self.onSceneChange(sceneName)
        }
    }
}

// MARK: - Air-Gap HTTP Server (POSIX Sockets, 0 Dependencies)

final class AirGapHTTPServer {
    private let port: UInt16
    private let adviceProvider: () -> [String: Any]
    private let onTogglePause: (Bool) -> Void
    private var serverSock: Int32 = -1
    private let queue = DispatchQueue(label: "com.stakelab.airgap.server", attributes: .concurrent)
    private var isRunning = false

    init(port: UInt16 = 8765,
         adviceProvider: @escaping () -> [String: Any],
         onTogglePause: @escaping (Bool) -> Void) {
        self.port = port
        self.adviceProvider = adviceProvider
        self.onTogglePause = onTogglePause
    }

    func start() {
        serverSock = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSock >= 0 else {
            print("❌ Failed to create Air-Gap socket")
            return
        }
        var opt: Int32 = 1
        setsockopt(serverSock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            print("❌ Air-Gap server failed to bind port \(port)")
            return
        }
        guard listen(serverSock, 32) == 0 else {
            print("❌ Air-Gap server failed to listen")
            return
        }

        isRunning = true
        print("🌐 [Air-Gap Web Dashboard] Live at: http://localhost:\(port)")
        print("📱 [Air-Gap Remote Access] Open http://<iMac-IP>:\(port) on your Mac mini or iPhone")

        queue.async { [weak self] in
            guard let self = self else { return }
            while self.isRunning && self.serverSock >= 0 {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSock = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.serverSock, $0, &addrLen)
                    }
                }
                guard clientSock >= 0 else { continue }
                self.queue.async {
                    self.handleClient(sock: clientSock)
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if serverSock >= 0 {
            close(serverSock)
            serverSock = -1
        }
    }

    private func handleClient(sock: Int32) {
        defer { close(sock) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(sock, &buf, buf.count, 0)
        guard bytesRead > 0 else { return }

        let reqStr = String(decoding: buf.prefix(bytesRead), as: UTF8.self)
        let firstLine = reqStr.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0])
        let path = String(parts[1])

        if path == "/" || path.hasPrefix("/?") {
            sendResponse(sock: sock, contentType: "text/html; charset=utf-8", body: AirGapDashboardHTML.content.data(using: .utf8) ?? Data())
        } else if path == "/api/advice" {
            let dict = adviceProvider()
            let jsonData = (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data("{}".utf8)
            sendResponse(sock: sock, contentType: "application/json", body: jsonData)
        } else if path == "/api/pause" && method == "POST" {
            onTogglePause(true)
            let body = Data("{\"status\":\"paused\"}".utf8)
            sendResponse(sock: sock, contentType: "application/json", body: body)
        } else if path == "/api/resume" && method == "POST" {
            onTogglePause(false)
            let body = Data("{\"status\":\"resumed\"}".utf8)
            sendResponse(sock: sock, contentType: "application/json", body: body)
        } else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            send(sock, notFound, notFound.utf8.count, 0)
        }
    }

    private func sendResponse(sock: Int32, contentType: String, body: Data) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: \(contentType)\r\n" +
                      "Content-Length: \(body.count)\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Connection: close\r\n\r\n"
        guard let headerData = headers.data(using: .utf8) else { return }
        headerData.withUnsafeBytes { ptr in
            _ = send(sock, ptr.baseAddress, headerData.count, 0)
        }
        body.withUnsafeBytes { ptr in
            _ = send(sock, ptr.baseAddress, body.count, 0)
        }
    }
}

// MARK: - Embedded Mobile / Mac mini Air-Gap Web Dashboard HTML

enum AirGapDashboardHTML {
    static let content = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <title>J4 Clubs // Air-Gap HUD</title>
        <style>
            :root {
                --bg: #0d0f14;
                --surface: #151821;
                --border: #262a36;
                --text-main: #f1f5f9;
                --text-muted: #94a3b8;
                --accent-emerald: #10b981;
                --accent-gold: #eab308;
                --accent-pink: #ff3fa4;
                --action-fold: #ef4444;
                --action-raise: #10b981;
                --action-call: #06b6d4;
                --action-check: #64748b;
                --suit-club: #10b981;
                --suit-diamond: #3b82f6;
                --suit-heart: #ef4444;
                --suit-spade: #e2e8f0;
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                background: var(--bg);
                color: var(--text-main);
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
                min-height: 100vh;
                display: flex;
                flex-direction: column;
                align-items: center;
                padding: 16px;
                user-select: none;
                -webkit-user-select: none;
            }
            .container {
                width: 100%;
                max-width: 520px;
                display: flex;
                flex-direction: column;
                gap: 14px;
            }
            /* Header & Status Bar */
            .header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                background: var(--surface);
                padding: 12px 16px;
                border-radius: 12px;
                border: 1px solid var(--border);
            }
            .brand {
                font-size: 15px;
                font-weight: 800;
                letter-spacing: 0.05em;
                color: var(--text-main);
                display: flex;
                align-items: center;
                gap: 6px;
            }
            .brand span { color: var(--accent-emerald); }
            .status-pill {
                display: flex;
                align-items: center;
                gap: 6px;
                font-size: 12px;
                font-weight: 600;
                padding: 4px 10px;
                border-radius: 20px;
                background: rgba(16, 185, 129, 0.15);
                color: var(--accent-emerald);
                border: 1px solid rgba(16, 185, 129, 0.3);
            }
            .status-pill.paused {
                background: rgba(234, 179, 8, 0.15);
                color: var(--accent-gold);
                border-color: rgba(234, 179, 8, 0.3);
            }
            .status-dot {
                width: 8px;
                height: 8px;
                border-radius: 50%;
                background: currentColor;
            }
            /* Action Banner */
            .action-card {
                background: var(--surface);
                border: 1px solid var(--border);
                border-radius: 16px;
                padding: 20px;
                text-align: center;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                position: relative;
                overflow: hidden;
            }
            .action-label {
                font-size: 13px;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.1em;
                color: var(--text-muted);
                margin-bottom: 4px;
            }
            .action-title {
                font-size: 42px;
                font-weight: 900;
                letter-spacing: -0.02em;
                line-height: 1.1;
                margin-bottom: 6px;
                color: var(--accent-emerald);
            }
            .action-rec {
                font-size: 16px;
                font-weight: 600;
                color: var(--text-main);
                max-width: 90%;
            }
            /* Cards Display */
            .cards-section {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 12px;
            }
            .card-box {
                background: var(--surface);
                border: 1px solid var(--border);
                border-radius: 14px;
                padding: 14px;
                display: flex;
                flex-direction: column;
                gap: 8px;
            }
            .box-label {
                font-size: 11px;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.08em;
                color: var(--text-muted);
            }
            .cards-row {
                display: flex;
                gap: 8px;
                min-height: 52px;
                align-items: center;
            }
            .poker-card {
                background: #1c202a;
                border: 1px solid #333846;
                border-radius: 8px;
                padding: 6px 10px;
                font-size: 20px;
                font-weight: 800;
                display: flex;
                align-items: center;
                gap: 3px;
                box-shadow: 0 4px 6px -1px rgba(0,0,0,0.3);
            }
            .suit-c { color: var(--suit-club); }
            .suit-d { color: var(--suit-diamond); }
            .suit-h { color: var(--suit-heart); }
            .suit-s { color: var(--suit-spade); }
            /* Stat Grid */
            .stats-grid {
                display: grid;
                grid-template-columns: repeat(3, 1fr);
                gap: 10px;
            }
            .stat-tile {
                background: var(--surface);
                border: 1px solid var(--border);
                border-radius: 12px;
                padding: 10px 12px;
                text-align: center;
            }
            .stat-val {
                font-size: 18px;
                font-weight: 800;
                color: var(--text-main);
                margin-top: 2px;
            }
            /* Tactical Rationale */
            .reason-box {
                background: var(--surface);
                border: 1px solid var(--border);
                border-radius: 14px;
                padding: 14px;
                font-size: 14px;
                line-height: 1.4;
                color: #cbd5e1;
            }
            .reason-box strong { color: var(--accent-gold); }
            /* Controls & Whisper */
            .controls {
                display: flex;
                gap: 10px;
            }
            .btn {
                flex: 1;
                padding: 14px;
                border-radius: 12px;
                font-size: 14px;
                font-weight: 700;
                border: 1px solid var(--border);
                background: var(--surface);
                color: var(--text-main);
                cursor: pointer;
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 6px;
                transition: all 0.15s ease;
            }
            .btn:active { transform: scale(0.98); }
            .btn-whisper.active {
                background: rgba(16, 185, 129, 0.2);
                border-color: var(--accent-emerald);
                color: var(--accent-emerald);
            }
            .btn-pause.active {
                background: rgba(234, 179, 8, 0.2);
                border-color: var(--accent-gold);
                color: var(--accent-gold);
            }
            .footer-info {
                text-align: center;
                font-size: 11px;
                color: #64748b;
                margin-top: 6px;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <!-- Header -->
            <div class="header">
                <div class="brand">J4 <span>CLUBS</span> // AIR-GAP</div>
                <div id="statusPill" class="status-pill">
                    <div class="status-dot"></div>
                    <span id="statusText">CONNECTING...</span>
                </div>
            </div>

            <!-- Action Banner -->
            <div class="action-card">
                <div class="action-label" id="actionSub">RECOMMENDED PLAY</div>
                <div class="action-title" id="actionTitle">—</div>
                <div class="action-rec" id="actionRec">Waiting for hand...</div>
            </div>

            <!-- Cards Row -->
            <div class="cards-section">
                <div class="card-box">
                    <div class="box-label">HERO HOLE CARDS</div>
                    <div class="cards-row" id="heroCards"><span style="color:#64748b;font-size:14px;">No cards detected</span></div>
                </div>
                <div class="card-box">
                    <div class="box-label">COMMUNITY BOARD</div>
                    <div class="cards-row" id="boardCards"><span style="color:#64748b;font-size:14px;">Pre-flop / clean</span></div>
                </div>
            </div>

            <!-- Stats Grid -->
            <div class="stats-grid">
                <div class="stat-tile">
                    <div class="box-label">POSITION</div>
                    <div class="stat-val" id="statPos">—</div>
                </div>
                <div class="stat-tile">
                    <div class="box-label">POT SIZE</div>
                    <div class="stat-val" id="statPot">—</div>
                </div>
                <div class="stat-tile">
                    <div class="box-label">CONFIDENCE</div>
                    <div class="stat-val" id="statConf">—</div>
                </div>
            </div>

            <!-- Tactical Rationale -->
            <div class="reason-box">
                <div class="box-label" style="margin-bottom:6px;">TACTICAL RATIONALE</div>
                <span id="reasonText">Evaluating table texture via local Qwen 2.5 co-pilot...</span>
            </div>

            <!-- AirPod Whisper & Pause Controls -->
            <div class="controls">
                <button id="whisperBtn" class="btn btn-whisper" onclick="toggleWhisper()">
                    <span>🔈</span> AirPod Whisper: OFF
                </button>
                <button id="pauseBtn" class="btn btn-pause" onclick="togglePause()">
                    <span>❚❚</span> Pause Engine
                </button>
            </div>

            <div class="footer-info">
                OBS Link: <span id="obsSceneName">Syncing...</span> • 100% Zero-Window Isolation
            </div>
        </div>

        <script>
            let whisperEnabled = false;
            let lastSpokenId = -1;
            let isEnginePaused = false;

            function renderCard(cardStr) {
                if (!cardStr || cardStr.length < 2) return '';
                const rank = cardStr.slice(0, -1).toUpperCase();
                const suit = cardStr.slice(-1).toLowerCase();
                let suitClass = 'suit-s';
                let suitSymbol = '♠';
                if (suit === 'c') { suitClass = 'suit-c'; suitSymbol = '♣'; }
                else if (suit === 'd') { suitClass = 'suit-d'; suitSymbol = '♦'; }
                else if (suit === 'h') { suitClass = 'suit-h'; suitSymbol = '♥'; }
                return `<div class="poker-card"><span class="${suitClass}">${rank}${suitSymbol}</span></div>`;
            }

            function parseCards(str) {
                if (!str || str.toLowerCase().includes('no card')) return [];
                const clean = str.replace(/[^a-zA-Z0-9]/g, '');
                const cards = [];
                for (let i = 0; i < clean.length; i += 2) {
                    if (i + 1 < clean.length) {
                        cards.push(clean.slice(i, i + 2));
                    }
                }
                return cards;
            }

            async function pollAdvice() {
                try {
                    const res = await fetch('/api/advice');
                    if (!res.ok) return;
                    const d = await res.json();
                    updateUI(d);
                } catch (e) {
                    document.getElementById('statusText').innerText = 'OFFLINE';
                    document.getElementById('statusPill').className = 'status-pill paused';
                }
            }

            function updateUI(d) {
                // Status pill
                const statusPill = document.getElementById('statusPill');
                const statusText = document.getElementById('statusText');
                const obsScene = document.getElementById('obsSceneName');
                obsScene.innerText = d.obsScene || 'Direct Mode';

                isEnginePaused = d.isPaused;
                if (d.isPaused) {
                    statusPill.className = 'status-pill paused';
                    statusText.innerText = 'PAUSED (' + (d.obsScene || 'BRB') + ')';
                    document.getElementById('pauseBtn').innerHTML = '<span>▶</span> Resume Engine';
                    document.getElementById('pauseBtn').classList.add('active');
                } else {
                    statusPill.className = 'status-pill';
                    statusText.innerText = 'LIVE (' + (d.obsScene || 'ACTIVE') + ')';
                    document.getElementById('pauseBtn').innerHTML = '<span>❚❚</span> Pause Engine';
                    document.getElementById('pauseBtn').classList.remove('active');
                }

                // Action
                const actionTitle = document.getElementById('actionTitle');
                const actionRec = document.getElementById('actionRec');
                const action = d.action || 'WAIT';
                actionTitle.innerText = action;
                actionRec.innerText = d.recommendation || (d.isPaused ? 'Engine suspended during scene change' : 'Scanning Floorp...');

                if (action.includes('RAISE') || action.includes('BET')) actionTitle.style.color = 'var(--action-raise)';
                else if (action.includes('FOLD')) actionTitle.style.color = 'var(--action-fold)';
                else if (action.includes('CALL')) actionTitle.style.color = 'var(--action-call)';
                else actionTitle.style.color = 'var(--action-check)';

                // Cards
                const heroCards = parseCards(d.hand);
                const heroDiv = document.getElementById('heroCards');
                if (heroCards.length > 0) {
                    heroDiv.innerHTML = heroCards.map(renderCard).join('');
                } else {
                    heroDiv.innerHTML = '<span style="color:#64748b;font-size:14px;">No cards detected</span>';
                }

                const boardCards = parseCards(d.board);
                const boardDiv = document.getElementById('boardCards');
                if (boardCards.length > 0) {
                    boardDiv.innerHTML = boardCards.map(renderCard).join('');
                } else {
                    boardDiv.innerHTML = '<span style="color:#64748b;font-size:14px;">Pre-flop / clean</span>';
                }

                // Stats
                document.getElementById('statPos').innerText = d.position || '—';
                document.getElementById('statPot').innerText = d.pot || '—';
                document.getElementById('statConf').innerText = d.confidence ? d.confidence + '%' : '—';
                document.getElementById('reasonText').innerText = d.hint || d.recommendation || 'GTO Baseline analysis';

                // AirPod Whisper
                if (whisperEnabled && d.actionOnHero && d.id && d.id !== lastSpokenId && action !== 'WAIT' && action !== '—') {
                    lastSpokenId = d.id;
                    speakAdvice(d.action, d.recommendation);
                }
            }

            function toggleWhisper() {
                whisperEnabled = !whisperEnabled;
                const btn = document.getElementById('whisperBtn');
                if (whisperEnabled) {
                    btn.classList.add('active');
                    btn.innerHTML = '<span>🔊</span> AirPod Whisper: ON';
                    speakAdvice('Whisper connected', 'Air-gap audio ready');
                } else {
                    btn.classList.remove('active');
                    btn.innerHTML = '<span>🔈</span> AirPod Whisper: OFF';
                }
            }

            function speakAdvice(action, rec) {
                if (!('speechSynthesis' in window)) return;
                window.speechSynthesis.cancel();
                const utter = new SpeechSynthesisUtterance(`${action}. ${rec || ''}`);
                utter.rate = 1.25;
                utter.pitch = 1.0;
                window.speechSynthesis.speak(utter);
            }

            async function togglePause() {
                const endpoint = isEnginePaused ? '/api/resume' : '/api/pause';
                await fetch(endpoint, { method: 'POST' });
                pollAdvice();
            }

            setInterval(pollAdvice, 400);
            pollAdvice();
        </script>
    </body>
    </html>
    """
}

// MARK: - Main Execution

@main
struct StakeStreamMain {
    static func main() async {
        print("=====================================================")
        print("   J4 CLUBS // STAKESTREAM HEADLESS AIR-GAP ENGINE   ")
        print("   100% Zero-Window Isolation • OBS Scene Auto-Pause ")
        print("=====================================================")

        let store = AdviceStore()
        let settings = HUDSettings.shared
        store.enableNativeMode()

        let engine = NativeWatcherEngine(store: store, settings: settings)
        engine.start()
        print("🚀 [Watcher Engine] Floorp Stake table OCR active")

        // OBS WebSocket Controller
        let obs = OBSSceneController { sceneName in
            let lower = sceneName.lowercased()
            // Auto-pause keywords: brb, away, start, end, intermission
            if lower.contains("brb") || lower.contains("away") || lower.contains("start") || lower.contains("ending") || lower.contains("pause") {
                engine.pause()
            }
            // Auto-resume keywords: gameplay, live, main, poker, table
            else if lower.contains("gameplay") || lower.contains("live") || lower.contains("table") || lower.contains("main") {
                engine.resume()
            }
        }
        obs.start()

        // Air-Gap HTTP Web Server
        let server = AirGapHTTPServer(
            port: 8765,
            adviceProvider: {
                let curr = store.current
                return [
                    "id": curr?.id ?? 0,
                    "hand": curr?.hand ?? "",
                    "position": curr?.position ?? "",
                    "board": curr?.board ?? "",
                    "action": curr?.action ?? (engine.isPaused ? "PAUSED" : "WAIT"),
                    "recommendation": curr?.recommendation ?? (engine.isPaused ? "Stream scene paused" : "Scanning Floorp table..."),
                    "confidence": curr?.confidence ?? 0,
                    "hint": curr?.hint ?? "",
                    "pot": curr?.smallBlind.isEmpty == false ? "SB: \(curr?.smallBlind ?? "") / BB: \(curr?.bigBlind ?? "")" : "",
                    "actionOnHero": curr?.actionOnHero ?? false,
                    "obsScene": obs.currentScene,
                    "isPaused": engine.isPaused
                ]
            },
            onTogglePause: { pause in
                if pause { engine.pause() } else { engine.resume() }
            }
        )
        server.start()

        // Keep process running in main dispatch loop
        dispatchMain()
    }
}
