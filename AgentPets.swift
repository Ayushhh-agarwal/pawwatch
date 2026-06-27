import AppKit
import Darwin
import Foundation

struct ProcRow {
    let pid: Int
    let ppid: Int
    let stat: String
    let cpu: Double
    let tty: String
    let runtime: String
    let command: String
}

struct AgentKind {
    let name: String
    let color: NSColor
    let executables: Set<String>
    let hints: [String]
}

struct AgentInfo {
    let pid: Int
    let name: String
    let repo: String
    let branch: String
    let sessionTitle: String
    let cwd: String
    let state: String
    let cpu: Double
    let color: NSColor
    let command: String
    let ownerPid: Int
    let ownerApp: String
    let tty: String
    let runtime: String

    var repoBranch: String {
        branch.isEmpty ? repo : "\(repo)@\(branch)"
    }

    var displayTitle: String {
        "\(name) · \(repoBranch)"
    }
}

struct CodexThread {
    let title: String
    let cwd: String
    let id: String
    let recencyMs: Double
}

final class AgentScanner {
    private struct AgentMeta {
        let cwd: String
        let repo: String
        let branch: String
        let sessionTitle: String
    }

    private var metaByPid: [Int: AgentMeta] = [:]

    private let kinds: [AgentKind] = [
        AgentKind(
            name: "Claude",
            color: NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.25, alpha: 1),
            executables: [],
            hints: ["/claude.app/contents/macos/claude"]
        ),
        AgentKind(
            name: "Claude Code",
            color: NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.25, alpha: 1),
            executables: ["claude"],
            hints: ["claude-code", "@anthropic-ai/claude-code"]
        ),
        AgentKind(
            name: "Codex",
            color: NSColor(calibratedRed: 0.20, green: 0.54, blue: 0.92, alpha: 1),
            executables: ["codex"],
            hints: ["/codex.app/contents/macos/codex", "codex-cli", "openai/codex"]
        ),
        AgentKind(
            name: "Gemini",
            color: NSColor(calibratedRed: 0.34, green: 0.62, blue: 0.98, alpha: 1),
            executables: ["gemini"],
            hints: ["@google/gemini-cli"]
        ),
        AgentKind(
            name: "Aider",
            color: NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.45, alpha: 1),
            executables: ["aider"],
            hints: []
        ),
        AgentKind(
            name: "OpenCode",
            color: NSColor(calibratedRed: 0.75, green: 0.44, blue: 0.94, alpha: 1),
            executables: ["opencode"],
            hints: []
        ),
        AgentKind(
            name: "Goose",
            color: NSColor(calibratedRed: 0.92, green: 0.68, blue: 0.20, alpha: 1),
            executables: ["goose"],
            hints: []
        ),
        AgentKind(
            name: "Cursor",
            color: NSColor(calibratedRed: 0.18, green: 0.75, blue: 0.70, alpha: 1),
            executables: ["cursor-agent"],
            hints: ["cursor-agent"]
        ),
        AgentKind(
            name: "Copilot",
            color: NSColor(calibratedRed: 0.30, green: 0.72, blue: 0.36, alpha: 1),
            executables: ["copilot"],
            hints: ["github-copilot-cli"]
        ),
        AgentKind(
            name: "ChatGPT",
            color: NSColor(calibratedRed: 0.13, green: 0.68, blue: 0.54, alpha: 1),
            executables: ["chatgpt"],
            hints: []
        ),
    ]

    func scan() -> [AgentInfo] {
        agents(from: psRows())
    }

    func parsePSOutput(_ output: String) -> [ProcRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(
                maxSplits: 6,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 7,
                  let pid = Int(fields[0]),
                  let ppid = Int(fields[1]),
                  let cpu = Double(String(fields[3]))
            else {
                return nil
            }
            return ProcRow(
                pid: pid,
                ppid: ppid,
                stat: String(fields[2]),
                cpu: cpu,
                tty: String(fields[4]),
                runtime: String(fields[5]),
                command: String(fields[6])
            )
        }
    }

    func agents(from rows: [ProcRow]) -> [AgentInfo] {
        var children: [Int: [ProcRow]] = [:]
        var byPid: [Int: ProcRow] = [:]
        var livePids: Set<Int> = []
        for row in rows {
            children[row.ppid, default: []].append(row)
            byPid[row.pid] = row
            livePids.insert(row.pid)
        }
        metaByPid = metaByPid.filter { livePids.contains($0.key) }

        return rows.compactMap { row in
            guard let kind = classify(row) else {
                return nil
            }
            let descendants = descendants(of: row.pid, children: children)
            let usefulDescendants = descendants.filter { !isNoise($0.command.lowercased()) }
            let totalCpu = row.cpu + usefulDescendants.reduce(0) { $0 + $1.cpu }
            let state = state(stat: row.stat, totalCpu: totalCpu, hasToolChild: !usefulDescendants.isEmpty)
            let meta = cachedMeta(for: row.pid, kind: kind)
            let owner = owningApp(for: row, byPid: byPid)
            return AgentInfo(
                pid: row.pid,
                name: kind.name,
                repo: meta.repo,
                branch: meta.branch,
                sessionTitle: meta.sessionTitle,
                cwd: meta.cwd,
                state: state,
                cpu: totalCpu,
                color: kind.color,
                command: row.command,
                ownerPid: owner.pid,
                ownerApp: owner.name,
                tty: row.tty == "??" ? "" : "/dev/\(row.tty)",
                runtime: row.runtime
            )
        }
        .sorted { left, right in
            if left.name == right.name {
                return left.pid < right.pid
            }
            return left.name < right.name
        }
    }

    private func cachedMeta(for pid: Int, kind: AgentKind) -> AgentMeta {
        if let meta = metaByPid[pid] {
            return meta
        }
        let cwd = cwdForPid(pid)
        let meta = AgentMeta(
            cwd: cwd,
            repo: repoName(for: cwd),
            branch: branchName(for: cwd),
            sessionTitle: sessionTitle(for: kind, cwd: cwd)
        )
        if !cwd.isEmpty {
            metaByPid[pid] = meta
        }
        return meta
    }

    static func selfTest() {
        let scanner = AgentScanner()
        let rows = scanner.parsePSOutput("""
          101     1 S      0.0 ttys001 01:02 /opt/homebrew/bin/claude
          102   101 S      0.0 ttys001 00:01 /bin/zsh -lc git status
          201     1 S      4.2 ?? 03:04 /Applications/Codex.app/Contents/MacOS/Codex
          202   201 S      0.1 ?? 03:04 /Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper --type=renderer
          301     1 S      0.5 ttys002 05:06 /opt/homebrew/bin/gemini
          401     1 S      0.0 ?? 00:01 /Users/me/agent-pets/build/AgentPets.app/Contents/MacOS/AgentPets
        """)
        let agents = scanner.agents(from: rows)
        assert(agents.count == 3)
        assert(agents.contains { $0.name == "Claude Code" && $0.state == "working" })
        assert(agents.contains { $0.name == "Codex" && $0.state == "working" })
        assert(agents.contains { $0.name == "Gemini" && $0.state == "waiting for permission" })
        assert(!agents.contains { $0.command.contains("Helper") })
        print("self-test ok")
    }

    private func psRows() -> [ProcRow] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,stat=,pcpu=,tty=,etime=,command="]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }
        return parsePSOutput(output)
    }

    private func cwdForPid(_ pid: Int) -> String {
        guard let output = commandOutput("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else {
            return ""
        }
        for line in output.split(separator: "\n") {
            if line.first == "n" {
                return String(line.dropFirst())
            }
        }
        return ""
    }

    private func repoName(for cwd: String) -> String {
        guard !cwd.isEmpty else {
            return "unknown"
        }
        let root = gitRoot(for: cwd)
        let path = root.isEmpty ? cwd : root
        if path == "/" {
            return "desktop"
        }
        if path == NSHomeDirectory() {
            return "~"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func gitRoot(for cwd: String) -> String {
        commandOutput("/usr/bin/git", ["-C", cwd, "rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func branchName(for cwd: String) -> String {
        guard !cwd.isEmpty, cwd != "/" else {
            return ""
        }
        let branch = commandOutput("/usr/bin/git", ["-C", cwd, "branch", "--show-current"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !branch.isEmpty {
            return branch
        }
        return commandOutput("/usr/bin/git", ["-C", cwd, "rev-parse", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func sessionTitle(for kind: AgentKind, cwd: String) -> String {
        guard kind.name == "Claude Code" else {
            return ""
        }
        return claudeSessionTitle(for: cwd)
    }

    private func claudeSessionTitle(for cwd: String) -> String {
        guard !cwd.isEmpty,
              let transcript = latestClaudeTranscript(for: cwd),
              let content = try? String(contentsOf: transcript, encoding: .utf8)
        else {
            return ""
        }
        var title = ""
        var slug = ""
        for line in content.split(separator: "\n").suffix(250) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            if let value = json["aiTitle"] as? String, !value.isEmpty {
                title = value
            }
            if let value = json["slug"] as? String, !value.isEmpty {
                slug = value
            }
        }
        return title.isEmpty ? slug : title
    }

    private func latestClaudeTranscript(for cwd: String) -> URL? {
        let project = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(project)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .max { left, right in
                modifiedAt(left) < modifiedAt(right)
            }
    }

    private func modifiedAt(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }

    private func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func owningApp(for row: ProcRow, byPid: [Int: ProcRow]) -> (pid: Int, name: String) {
        if let name = appName(from: row.command) {
            return (row.pid, name)
        }
        var pid = row.ppid
        var seen: Set<Int> = []
        while let parent = byPid[pid], seen.insert(pid).inserted {
            if let name = appName(from: parent.command) {
                return (parent.pid, name)
            }
            pid = parent.ppid
        }
        return (0, "")
    }

    private func appName(from command: String) -> String? {
        guard let range = command.range(of: ".app/Contents/MacOS") else {
            return nil
        }
        let appPath = String(command[..<range.lowerBound]) + ".app"
        return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    }

    private func classify(_ row: ProcRow) -> AgentKind? {
        let exe = executableName(from: row.command)
        for kind in kinds {
            if kind.executables.contains(exe) {
                let lower = row.command.lowercased()
                return isNoise(lower) ? nil : kind
            }
        }
        let lower = row.command.lowercased()
        for kind in kinds {
            if kind.hints.contains(where: lower.contains), !isNoise(lower) {
                return kind
            }
        }
        return nil
    }

    private func executableName(from command: String) -> String {
        guard let first = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return ""
        }
        return URL(fileURLWithPath: String(first)).lastPathComponent.lowercased()
    }

    private func isNoise(_ lower: String) -> Bool {
        lower.contains("agentpets")
            || lower.contains("/agent-pets/")
            || lower.contains("claude-tracker")
            || lower.contains("crashpad_handler")
            || lower.contains("bare-modifier-monitor")
            || lower.contains("codex app-server")
            || lower.contains("codex (renderer)")
            || lower.contains("codex (service)")
            || lower.contains("skycomputeruse")
            || lower.contains("mcp-remote")
            || lower.contains("mcp-server")
            || lower.contains("notebooklm-mcp")
            || lower.contains("gopls")
            || lower.contains("helper.app/contents/macos")
            || lower.contains("--type=renderer")
            || lower.contains("--type=gpu")
            || lower.contains("--type=utility")
            || lower.contains("/bin/ps -axo")
            || lower.contains(" swiftc ")
            || lower.contains("swift-frontend")
    }

    private func descendants(of pid: Int, children: [Int: [ProcRow]]) -> [ProcRow] {
        var result: [ProcRow] = []
        var seen: Set<Int> = []
        var stack = children[pid] ?? []
        while let row = stack.popLast() {
            guard seen.insert(row.pid).inserted else {
                continue
            }
            result.append(row)
            stack.append(contentsOf: children[row.pid] ?? [])
        }
        return result
    }

    private func state(stat: String, totalCpu: Double, hasToolChild: Bool) -> String {
        if stat.contains("T") {
            return "paused"
        }
        if stat.contains("Z") {
            return "ended"
        }
        if hasToolChild || totalCpu >= 3 {
            return "working"
        }
        if totalCpu >= 0.3 {
            return "waiting for permission"
        }
        return "idle"
    }
}

final class PetsView: NSView {
    static let rowHeight: CGFloat = 62
    static let compactHeight: CGFloat = 54

    var onClick: ((AgentInfo, NSPoint) -> Void)?
    var onEmptyClick: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onToggleCompact: (() -> Void)?
    var onFocus: ((AgentInfo) -> Void)?
    var onTerminate: ((AgentInfo) -> Void)?
    private var lastDragPoint: NSPoint?
    private var dragDistance: CGFloat = 0
    private var pendingClick: DispatchWorkItem?
    private var imageCache: [String: NSImage] = [:]
    private var missingImages: Set<String> = []
    var isCompact = false {
        didSet {
            needsDisplay = true
        }
    }
    var agents: [AgentInfo] = [] {
        didSet {
            needsDisplay = true
        }
    }
    var tick = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = NSEvent.mouseLocation
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard let last = lastDragPoint else {
            lastDragPoint = point
            return
        }
        let delta = NSPoint(x: point.x - last.x, y: point.y - last.y)
        dragDistance += hypot(delta.x, delta.y)
        lastDragPoint = point
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            lastDragPoint = nil
            dragDistance = 0
        }
        guard dragDistance < 4 else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if toggleButtonRect().contains(point) {
            cancelPendingClick()
            onToggleCompact?()
            return
        }
        if isCompact {
            if event.clickCount >= 2, let agent = agents.first {
                cancelPendingClick()
                onFocus?(agent)
                return
            }
            scheduleSingleClick { [weak self] in
                self?.onEmptyClick?(point)
            }
            return
        }
        guard !agents.isEmpty else {
            scheduleSingleClick { [weak self] in
                self?.onEmptyClick?(point)
            }
            return
        }
        let index = Int((point.y - 6) / Self.rowHeight)
        guard agents.indices.contains(index) else {
            return
        }
        if terminateButtonRect(for: index).contains(point) {
            cancelPendingClick()
            onTerminate?(agents[index])
            return
        }
        if event.clickCount >= 2 {
            cancelPendingClick()
            onFocus?(agents[index])
            return
        }
        let agent = agents[index]
        scheduleSingleClick { [weak self] in
            self?.onClick?(agent, point)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingClick()
        let point = convert(event.locationInWindow, from: nil)
        if isCompact {
            onEmptyClick?(point)
            return
        }
        guard !agents.isEmpty else {
            onEmptyClick?(point)
            return
        }
        let index = Int((point.y - 6) / Self.rowHeight)
        guard agents.indices.contains(index) else {
            return
        }
        onClick?(agents[index], point)
    }

    private func scheduleSingleClick(_ action: @escaping () -> Void) {
        cancelPendingClick()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingClick = nil
            action()
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func cancelPendingClick() {
        pendingClick?.cancel()
        pendingClick = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        if isCompact {
            drawCompact()
            return
        }

        guard !agents.isEmpty else {
            drawEmptyState()
            return
        }

        for (index, agent) in agents.enumerated() {
            let y = CGFloat(index) * Self.rowHeight + 6
            let card = NSRect(x: 8, y: y, width: bounds.width - 16, height: Self.rowHeight - 8)
            drawCard(agent, in: card)
            drawTerminateButton(in: terminateButtonRect(for: index))
            if index == 0 {
                drawToggleButton("-", in: toggleButtonRect())
            }
        }
    }

    private func drawCompact() {
        let rect = NSRect(x: 8, y: 6, width: bounds.width - 16, height: Self.compactHeight - 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.58).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let color = agents.first?.color ?? .systemGray
        let iconRect = NSRect(x: rect.minX + 8, y: rect.minY + 2, width: 38, height: 38)
        if let agent = agents.first {
            drawAgentIcon(agent, in: iconRect)
        } else {
            drawPet(in: iconRect, color: color, state: "idle")
        }

        let working = agents.filter { $0.state == "working" }.count
        let waiting = agents.filter { $0.state == "waiting for permission" }.count
        let title = agents.isEmpty ? "No flows" : "\(agents.count) flows"
        let detail = agents.isEmpty ? "idle" : "\(working) working, \(waiting) waiting"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncatingStyle(),
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: truncatingStyle(),
        ]
        (title as NSString).draw(in: NSRect(x: rect.minX + 52, y: rect.minY + 8, width: rect.width - 86, height: 16), withAttributes: titleAttrs)
        (detail as NSString).draw(in: NSRect(x: rect.minX + 52, y: rect.minY + 25, width: rect.width - 86, height: 14), withAttributes: detailAttrs)
        drawToggleButton("+", in: toggleButtonRect())
    }

    private func drawEmptyState() {
        let rect = NSRect(x: 8, y: 6, width: bounds.width - 16, height: Self.rowHeight - 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.58).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        ("No agent flows" as NSString).draw(
            in: NSRect(x: rect.minX + 16, y: rect.minY + 19, width: rect.width - 32, height: 18),
            withAttributes: attrs
        )
        drawToggleButton("-", in: toggleButtonRect())
    }

    private func drawCard(_ agent: AgentInfo, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.58).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let petRect = NSRect(x: rect.minX + 9, y: rect.minY + 7, width: 42, height: 42)
        drawAgentIcon(agent, in: petRect)

        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: truncatingStyle(),
        ]
        let nameAttrsTruncated: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncatingStyle(),
        ]

        let nameRect = NSRect(x: rect.minX + 60, y: rect.minY + 10, width: rect.width - 90, height: 17)
        (agent.displayTitle as NSString).draw(in: nameRect, withAttributes: nameAttrsTruncated)

        let dotRect = NSRect(x: rect.minX + 60, y: rect.minY + 32, width: 8, height: 8)
        stateColor(agent.state).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let detailRect = NSRect(x: rect.minX + 73, y: rect.minY + 29, width: rect.width - 103, height: 15)
        let detail = agent.sessionTitle.isEmpty
            ? "\(agent.state) · \(agent.runtime) · \(String(format: "%.1f", agent.cpu))%"
            : "\(agent.state) · \(agent.runtime) · \(agent.sessionTitle) · \(String(format: "%.1f", agent.cpu))%"
        (detail as NSString).draw(in: detailRect, withAttributes: detailAttrs)
    }

    private func toggleButtonRect() -> NSRect {
        NSRect(x: bounds.width - (isCompact ? 37 : 64), y: 14, width: 22, height: 22)
    }

    private func terminateButtonRect(for index: Int) -> NSRect {
        NSRect(x: bounds.width - 25, y: CGFloat(index) * Self.rowHeight + 8, width: 12, height: 12)
    }

    private func drawToggleButton(_ symbol: String, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.76).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centeredStyle(),
        ]
        (symbol as NSString).draw(in: rect.offsetBy(dx: 0, dy: 1), withAttributes: attrs)
    }

    private func drawTerminateButton(in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centeredStyle(),
        ]
        ("x" as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func drawAgentIcon(_ agent: AgentInfo, in rect: NSRect) {
        guard let image = imageForAgent(agent.name) else {
            drawPet(in: rect, color: agent.color, state: agent.state)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
        image.draw(in: aspectFillRect(for: image, in: rect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func imageForAgent(_ name: String) -> NSImage? {
        if let image = imageCache[name] {
            return image
        }
        if missingImages.contains(name) {
            return nil
        }
        for path in assetPaths(for: name) {
            if let image = NSImage(contentsOfFile: path) {
                imageCache[name] = image
                return image
            }
        }
        missingImages.insert(name)
        return nil
    }

    private func assetPaths(for name: String) -> [String] {
        let roots = [
            NSHomeDirectory() + "/agent-pets/assets",
            Bundle.main.resourcePath.map { $0 + "/assets" } ?? "",
        ].filter { !$0.isEmpty }
        let names = [name, name.lowercased()]
        let extensions = ["png", "jpg", "jpeg", "heic", "webp"]
        return roots.flatMap { root in
            names.flatMap { base in
                extensions.map { ext in "\(root)/\(base).\(ext)" }
            }
        }
    }

    private func aspectFillRect(for image: NSImage, in rect: NSRect) -> NSRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return rect
        }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private func truncatingStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }

    private func centeredStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }

    private func drawPet(in rect: NSRect, color: NSColor, state: String) {
        let bounce: CGFloat = state == "working" && tick % 2 == 0 ? -2 : 0
        let fill = color.blended(withFraction: 0.12, of: .white) ?? color
        let head = rect.insetBy(dx: 5, dy: 8).offsetBy(dx: 0, dy: bounce)

        fill.setFill()
        triangle([
            NSPoint(x: head.minX + 5, y: head.minY + 7),
            NSPoint(x: head.minX + 11, y: head.minY - 2),
            NSPoint(x: head.minX + 16, y: head.minY + 9),
        ]).fill()
        triangle([
            NSPoint(x: head.maxX - 5, y: head.minY + 7),
            NSPoint(x: head.maxX - 11, y: head.minY - 2),
            NSPoint(x: head.maxX - 16, y: head.minY + 9),
        ]).fill()

        NSBezierPath(ovalIn: head).fill()

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(ovalIn: NSRect(x: head.minX + 9, y: head.minY + 14, width: 4, height: 5)).fill()
        NSBezierPath(ovalIn: NSRect(x: head.maxX - 13, y: head.minY + 14, width: 4, height: 5)).fill()

        NSColor.black.withAlphaComponent(0.55).setStroke()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: head.midX - 4, y: head.minY + 25))
        mouth.curve(
            to: NSPoint(x: head.midX + 4, y: head.minY + 25),
            controlPoint1: NSPoint(x: head.midX - 2, y: head.minY + 29),
            controlPoint2: NSPoint(x: head.midX + 2, y: head.minY + 29)
        )
        mouth.lineWidth = 1.4
        mouth.stroke()
    }

    private func triangle(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])
        path.line(to: points[1])
        path.line(to: points[2])
        path.close()
        return path
    }

    private func stateColor(_ state: String) -> NSColor {
        switch state {
        case "working":
            return .systemGreen
        case "waiting for permission":
            return .systemYellow
        case "paused":
            return .systemOrange
        case "ended":
            return .systemRed
        default:
            return .systemGray
        }
    }
}

final class AgentOverlayController: NSObject {
    private let scanner = AgentScanner()
    private let panel: NSPanel
    private let petsView = PetsView(frame: .zero)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenu = NSMenu()
    private let originXKey = "AgentPetsOriginX"
    private let originYKey = "AgentPetsOriginY"
    private let compactKey = "AgentPetsCompact"
    private let hiddenKey = "AgentPetsHidden"
    private var userOrigin: NSPoint?
    private var isCompact = false
    private var isHidden = false
    private var timer: Timer?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 292, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        userOrigin = savedOrigin()
        isCompact = UserDefaults.standard.bool(forKey: compactKey)
        isHidden = UserDefaults.standard.bool(forKey: hiddenKey)
        petsView.isCompact = isCompact
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.contentView = petsView
        petsView.onClick = { [weak self] agent, point in
            self?.showAgentMenu(agent, at: point)
        }
        petsView.onEmptyClick = { [weak self] point in
            self?.showGlobalMenu(at: point, in: self?.petsView)
        }
        petsView.onDrag = { [weak self] delta in
            self?.movePanel(by: delta)
        }
        petsView.onToggleCompact = { [weak self] in
            self?.toggleCompact()
        }
        petsView.onFocus = { [weak self] agent in
            self?.focus(agent)
        }
        petsView.onTerminate = { [weak self] agent in
            self?.confirmTerminate(agent)
        }
        setupMenu()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func setupMenu() {
        statusItem.button?.title = ""
        statusItem.button?.image = statusIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    private func refresh() {
        let agents = scanner.scan()
        petsView.tick += 1
        petsView.agents = agents
        petsView.isCompact = isCompact
        statusItem.button?.toolTip = isHidden ? "Agent Pets hidden" : (agents.isEmpty ? "No agent flows" : "\(agents.count) agent flows")
        guard !isHidden else {
            panel.orderOut(nil)
            return
        }

        let height = isCompact ? PetsView.compactHeight : CGFloat(max(agents.count, 1)) * PetsView.rowHeight + 12
        let width: CGFloat = isCompact ? 206 : 292
        guard let screen = NSScreen.screens.max(by: { $0.visibleFrame.maxX < $1.visibleFrame.maxX }) ?? NSScreen.main else {
            return
        }
        let frame = screen.visibleFrame
        let defaultOrigin = NSPoint(x: frame.maxX - width - 12, y: frame.maxY - height - 12)
        let origin = clampedOrigin(userOrigin ?? defaultOrigin, width: width, height: height, screen: screen)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func movePanel(by delta: NSPoint) {
        var frame = panel.frame
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        panel.setFrameOrigin(frame.origin)
        userOrigin = frame.origin
        saveOrigin(frame.origin)
    }

    private func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setFill()

        [
            NSRect(x: 2.2, y: 9.5, width: 3.8, height: 4.8),
            NSRect(x: 5.8, y: 12.0, width: 4.0, height: 5.0),
            NSRect(x: 9.2, y: 12.0, width: 4.0, height: 5.0),
            NSRect(x: 12.8, y: 9.5, width: 3.8, height: 4.8),
            NSRect(x: 4.2, y: 2.5, width: 9.6, height: 8.8),
        ].forEach { rect in
            NSBezierPath(ovalIn: rect).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func clampedOrigin(_ origin: NSPoint, width: CGFloat, height: CGFloat, screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        return NSPoint(
            x: min(max(origin.x, frame.minX + 4), frame.maxX - width - 4),
            y: min(max(origin.y, frame.minY + 4), frame.maxY - height - 4)
        )
    }

    private func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXKey) != nil,
              defaults.object(forKey: originYKey) != nil
        else {
            return nil
        }
        return NSPoint(x: defaults.double(forKey: originXKey), y: defaults.double(forKey: originYKey))
    }

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: originXKey)
        UserDefaults.standard.set(origin.y, forKey: originYKey)
    }

    private func toggleCompact() {
        isCompact.toggle()
        UserDefaults.standard.set(isCompact, forKey: compactKey)
        refresh()
    }

    @objc private func toggleHiddenFromMenu() {
        isHidden.toggle()
        UserDefaults.standard.set(isHidden, forKey: hiddenKey)
        refresh()
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: originXKey)
        UserDefaults.standard.removeObject(forKey: originYKey)
        userOrigin = nil
        refresh()
    }

    private func showGlobalMenu(at point: NSPoint, in view: NSView?) {
        guard let view else {
            return
        }
        globalMenu().popUp(positioning: nil, at: point, in: view)
    }

    private func globalMenu() -> NSMenu {
        let menu = NSMenu()
        populateGlobalMenu(menu)
        return menu
    }

    private func populateGlobalMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Running Flows", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        if petsView.agents.isEmpty {
            let empty = NSMenuItem(title: "No agent flows detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for agent in petsView.agents {
                let session = agent.sessionTitle.isEmpty ? "" : " · \(agent.sessionTitle)"
                let item = NSMenuItem(
                    title: "\(agent.displayTitle)\(session) · \(agent.state) · \(agent.runtime) · \(agent.ownerApp.isEmpty ? "unknown" : agent.ownerApp)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        addRecentCodexChats(to: menu)
        menu.addItem(.separator())
        let hide = NSMenuItem(
            title: isHidden ? "Show Pets" : "Hide Pets",
            action: #selector(toggleHiddenFromMenu),
            keyEquivalent: "h"
        )
        hide.target = self
        menu.addItem(hide)
        let compact = NSMenuItem(
            title: isCompact ? "Expand" : "Minimize",
            action: #selector(toggleCompactFromMenu),
            keyEquivalent: "m"
        )
        compact.target = self
        compact.isEnabled = !isHidden
        menu.addItem(compact)
        let reset = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "0")
        reset.target = self
        menu.addItem(reset)
        let quit = NSMenuItem(title: "Quit Agent Pets", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func showAgentMenu(_ agent: AgentInfo, at point: NSPoint) {
        let selected = petsView.agents.first(where: { $0.pid == agent.pid }) ?? agent
        let menu = NSMenu()
        let title = NSMenuItem(title: selected.displayTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if !selected.sessionTitle.isEmpty {
            let session = NSMenuItem(title: selected.sessionTitle, action: nil, keyEquivalent: "")
            session.isEnabled = false
            menu.addItem(session)
        }

        let detail = NSMenuItem(title: "\(selected.state) · \(selected.runtime) · \(selected.ownerApp.isEmpty ? "unknown" : selected.ownerApp)", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.addItem(.separator())

        if selected.ownerPid > 0 {
            let focus = NSMenuItem(title: "Jump to \(selected.ownerApp)", action: #selector(focusFromMenu(_:)), keyEquivalent: "j")
            focus.target = self
            focus.representedObject = selected.pid
            menu.addItem(focus)
        }
        if !selected.cwd.isEmpty {
            let repo = NSMenuItem(title: selected.cwd, action: nil, keyEquivalent: "")
            repo.isEnabled = false
            menu.addItem(repo)
            let copyRepo = NSMenuItem(title: "Copy Repo Path", action: #selector(copyText(_:)), keyEquivalent: "r")
            copyRepo.target = self
            copyRepo.representedObject = selected.cwd
            menu.addItem(copyRepo)
        }
        let copy = NSMenuItem(title: "Copy Command", action: #selector(copyCommand(_:)), keyEquivalent: "c")
        copy.target = self
        copy.representedObject = selected.command
        menu.addItem(copy)
        menu.addItem(.separator())
        let terminate = NSMenuItem(title: "Terminate Agent", action: #selector(terminateFromMenu(_:)), keyEquivalent: "x")
        terminate.target = self
        terminate.representedObject = selected.pid
        menu.addItem(terminate)
        menu.popUp(positioning: nil, at: point, in: petsView)
    }

    private func addRecentCodexChats(to menu: NSMenu) {
        let parent = NSMenuItem(title: "Recent Codex Chats", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let threads = recentCodexThreads()
        if threads.isEmpty {
            let empty = NSMenuItem(title: "No recent chats found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for thread in threads {
                let item = NSMenuItem(
                    title: "\(thread.title) · \(repoLabel(for: thread.cwd)) · \(ageText(thread.recencyMs))",
                    action: #selector(focusCodexAppFromMenu),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = thread.id
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let note = NSMenuItem(title: "Click focuses Codex; exact tab jump is unavailable", action: nil, keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
        }
        menu.addItem(parent)
        menu.setSubmenu(submenu, for: parent)
    }

    private func recentCodexThreads() -> [CodexThread] {
        let db = NSHomeDirectory() + "/.codex/state_5.sqlite"
        let query = """
        SELECT
          substr(replace(replace(replace(CASE WHEN title = '' THEN id ELSE title END, char(10), ' '), char(13), ' '), char(9), ' '), 1, 64),
          coalesce(nullif(cwd, ''), '/'),
          id,
          recency_at_ms
        FROM threads
        WHERE archived = 0
          AND coalesce(thread_source, '') != 'subagent'
          AND title NOT LIKE 'The following is the Codex agent history%'
        ORDER BY recency_at_ms DESC
        LIMIT 8;
        """
        guard let output = commandOutput("/usr/bin/sqlite3", ["-separator", "\t", db, query]) else {
            return []
        }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let recency = Double(fields[3]) else {
                return nil
            }
            return CodexThread(title: String(fields[0]), cwd: String(fields[1]), id: String(fields[2]), recencyMs: recency)
        }
    }

    private func repoLabel(for cwd: String) -> String {
        if cwd == "/" {
            return "desktop"
        }
        if cwd == NSHomeDirectory() {
            return "~"
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func ageText(_ recencyMs: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - recencyMs / 1000)
        if seconds < 3600 {
            return "\(Int(seconds / 60))m"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3600))h"
        }
        return "\(Int(seconds / 86_400))d"
    }

    private func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    @objc private func copyCommand(_ sender: NSMenuItem) {
        copyText(sender)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc private func focusFromMenu(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int,
              let agent = petsView.agents.first(where: { $0.pid == pid })
        else {
            return
        }
        focus(agent)
    }

    @objc private func terminateFromMenu(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int,
              let agent = petsView.agents.first(where: { $0.pid == pid })
        else {
            return
        }
        confirmTerminate(agent)
    }

    private func confirmTerminate(_ agent: AgentInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Terminate \(agent.displayTitle)?"
        alert.informativeText = "This sends SIGTERM to this agent process. It does not close unrelated terminal tabs or windows."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        if kill(pid_t(agent.pid), SIGTERM) == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refresh()
            }
            return
        }
        let error = String(cString: strerror(errno))
        let failed = NSAlert()
        failed.alertStyle = .warning
        failed.messageText = "Could not terminate \(agent.name)"
        failed.informativeText = error
        failed.runModal()
    }

    @objc private func focusCodexAppFromMenu() {
        if let agent = petsView.agents.first(where: { $0.name == "Codex" }) {
            focus(agent)
            return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Codex.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    private func focus(_ agent: AgentInfo) {
        if agent.ownerApp == "Terminal", !agent.tty.isEmpty, focusTerminalTab(tty: agent.tty) {
            return
        }
        guard agent.ownerPid > 0,
              let app = NSRunningApplication(processIdentifier: pid_t(agent.ownerPid))
        else {
            return
        }
        app.activate(options: [.activateAllWindows])
        if isJetBrains(agent.ownerApp) {
            _ = focusJetBrainsTerminal(appName: agent.ownerApp)
        }
    }

    private func isJetBrains(_ appName: String) -> Bool {
        ["GoLand", "IntelliJ IDEA", "PyCharm", "WebStorm", "CLion", "DataGrip", "Rider", "PhpStorm", "RubyMine"].contains(appName)
    }

    private func focusTerminalTab(tty: String) -> Bool {
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected tab of w to t
                set index of w to 1
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        """
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && String(data: data, encoding: .utf8)?.contains("ok") == true
    }

    private func focusJetBrainsTerminal(appName: String) -> Bool {
        let escaped = appName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "\(escaped)" to activate
        delay 0.15
        tell application "System Events"
          tell process "\(escaped)"
            set frontmost to true
            try
              click menu item "Terminal" of menu 1 of menu item "Tool Windows" of menu 1 of menu bar item "View" of menu bar 1
              return "ok"
            on error
              key code 111 using option down
              return "fallback"
            end try
          end tell
        end tell
        """
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return output.contains("ok") || output.contains("fallback")
    }

    @objc private func toggleCompactFromMenu() {
        toggleCompact()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AgentOverlayController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateGlobalMenu(menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AgentOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AgentOverlayController()
        controller?.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

if CommandLine.arguments.contains("--self-test") {
    AgentScanner.selfTest()
    exit(0)
}

if CommandLine.arguments.contains("--list") {
    for agent in AgentScanner().scan() {
        print("\(agent.name)\t\(agent.pid)\t\(agent.repo)\t\(agent.branch)\t\(agent.sessionTitle)\t\(agent.runtime)\t\(agent.state)\t\(String(format: "%.1f", agent.cpu))%\t\(agent.ownerApp)\t\(agent.ownerPid)\t\(agent.tty)\t\(agent.cwd)\t\(agent.command)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
