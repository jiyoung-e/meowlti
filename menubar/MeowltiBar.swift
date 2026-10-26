// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright 2026 jiyoung-e (https://github.com/jiyoung-e/meowlti)
// MeowltiBar — menu bar + management window for the `meowlti` CLI.
// Every action shells out to `meowlti` so the app and the CLI never diverge.

import AppKit
import SwiftUI
import Sparkle

// MARK: - CLI bridge

struct Profile: Identifiable, Equatable {
    let name: String
    let email: String?          // known once a Code tab / CLI session has run
    let desktopSignedIn: Bool   // the desktop app holds a login (email may still be unknown)
    let claudeRunning: Bool
    let codexRunning: Bool
    let codexCLILoggedIn: Bool
    let label: String?
    /// The CLI / Code tab account differs from the desktop login (one profile mixing two accounts).
    let accountsDiffer: Bool
    var id: String { name }
    /// "default" is the user's normal Claude/Codex (no profile folder); only open/quit/login apply.
    var isDefault: Bool { name == "default" }
    var displayName: String { isDefault ? "기본 (메인)" : (label ?? name) }

    var accountSummary: String {
        if let email { return email }
        return desktopSignedIn ? "로그인됨" : "로그인 안 됨"
    }
}

struct ShareItem: Identifiable, Equatable {
    enum State: String { case shared, local, off }
    let name: String
    let state: State
    var id: String { name }
}

struct CodeSession: Identifiable, Equatable {
    let id: String          // CLI session id
    let title: String
    let lastActivity: Date
    let cwd: String
    let fromDesktop: Bool
}

struct CommandResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
    /// The CLI prefixes errors with "meowlti: "; drop it for display.
    var message: String {
        output.split(separator: "\n").map { $0.hasPrefix("meowlti: ") ? String($0.dropFirst(9)) : String($0) }
            .joined(separator: "\n")
    }
}

enum Meowlti {
    static let executable: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Homebrew (Apple silicon / Intel), npm global prefixes, then a source checkout.
        let candidates = ["/opt/homebrew/bin/meowlti", "/usr/local/bin/meowlti", "\(home)/.local/bin/meowlti",
                          "\(home)/.npm-global/bin/meowlti", "\(home)/meowlti/meowlti"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }()

    static var home: String {
        ProcessInfo.processInfo.environment["MEOWLTI_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meowlti").path
    }

    static func makeProcess(_ args: [String]) -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        return (process, pipe)
    }

    static func wait(_ process: Process, _ pipe: Pipe) -> CommandResult {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandResult(status: process.terminationStatus, output: text)
    }

    static func run(_ args: [String]) -> CommandResult {
        let (process, pipe) = makeProcess(args)
        do { try process.run() } catch {
            return CommandResult(status: -1, output: "meowlti를 실행할 수 없습니다 (\(executable)): \(error.localizedDescription)")
        }
        return wait(process, pipe)
    }

    static func profiles() -> [Profile] {
        let result = run(["ls", "--tsv"])
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 7 else { return nil }
            return Profile(name: c[0],
                           email: c[1] == "-" ? nil : c[1],
                           desktopSignedIn: c[6] != "-",
                           claudeRunning: c[2] == "running",
                           codexRunning: c[3] == "running",
                           codexCLILoggedIn: c[4] == "yes",
                           label: c[5].isEmpty ? nil : c[5],
                           accountsDiffer: c.count > 8 && c[8] == "yes")
        }
    }

    static func shared(_ name: String, _ tool: String) -> [ShareItem] {
        let result = run(["shared", name, tool])
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t").map(String.init)
            guard c.count == 2, let state = ShareItem.State(rawValue: c[1]) else { return nil }
            return ShareItem(name: c[0], state: state)
        }
    }

    static func sessions(_ name: String) -> [CodeSession] {
        let result = run(["sessions", name])
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 5, let ms = Double(c[2]) else { return nil }
            return CodeSession(id: c[0], title: c[1], lastActivity: Date(timeIntervalSince1970: ms / 1000),
                               cwd: c[3], fromDesktop: c[4] == "desktop")
        }
    }

    static func bindings(_ name: String) -> [String] {
        let result = run(["bindings", name])
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.map(String.init)
        }
    }

    static func isValidName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }
}

// MARK: - State shared by the menu and the window

@MainActor
final class Store: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var selection: String?
    @Published var busy: Set<String> = []          // profile names with a command in flight
    @Published var loginWaiting: Set<String> = []
    @Published var loginExclusive: Set<String> = []   // waiting with the other Claude windows closed
    @Published var notice: (text: String, isError: Bool)?
    @Published var claudeShares: [ShareItem] = []
    @Published var codexShares: [ShareItem] = []
    @Published var showingAdd = false
    @Published var sessions: [CodeSession] = []
    @Published var claudeCLILogin: String?          // "yes" / "no" / "-" for the selected profile
    @Published var boundFolders: [String] = []
    @Published var shellInstalled: Bool?
    /// Set when a copy was refused because the accounts are in different organizations.
    @Published var crossOrgRequest: (from: String, session: CodeSession, to: String)?
    /// Set when both profiles continued the same session separately (copy refused as DIVERGED).
    @Published var divergedRequest: (from: String, session: CodeSession, to: String, allowCrossOrg: Bool)?

    private var loginProcesses: [String: Process] = [:]
    private var timer: Timer?

    func refresh() {
        Task.detached {
            let list = Meowlti.profiles()
            await MainActor.run {
                self.profiles = list
                if self.selection == nil || !list.contains(where: { $0.name == self.selection }) {
                    self.selection = list.first?.name
                }
                self.refreshShares()
            }
        }
    }

    func refreshShares() {
        guard let name = selection, name != "default" else {
            claudeShares = []; codexShares = []; sessions = []; boundFolders = []; claudeCLILogin = nil; return
        }
        Task.detached {
            let c = Meowlti.shared(name, "claude"), x = Meowlti.shared(name, "codex")
            let s = Meowlti.sessions(name)
            let cli = Meowlti.run(["cli-status", name])
            let folders = Meowlti.bindings(name)
            let shell = Meowlti.run(["shell-init", "--status"])
            await MainActor.run {
                guard self.selection == name else { return }
                self.boundFolders = folders
                self.shellInstalled = shell.ok ? shell.output == "installed" : nil
                self.claudeShares = c
                self.codexShares = x
                self.sessions = s
                self.claudeCLILogin = cli.ok ? cli.output : nil
            }
        }
    }

    /// Copy a Code session to another profile and open that profile's Claude window.
    /// The target window is quit first because the desktop app rewrites its session list while running.
    /// Copying back (A -> B -> A) updates the older copy; if both sides continued, the user may copy it as new.
    func copySession(from: String, session: CodeSession, to: String, allowCrossOrg: Bool = false, asNew: Bool = false) {
        busy.insert(from)
        let target = profiles.first { $0.name == to }
        let wasRunning = target?.claudeRunning == true
        Task.detached {
            if wasRunning {
                let q = Meowlti.run(["quit", to, "claude"])
                if !q.ok {
                    await MainActor.run { self.busy.remove(from); self.notice = (q.message, true) }
                    return
                }
            }
            var args = ["copy-session", from, session.id, to]
            if allowCrossOrg { args.append("--allow-cross-org") }
            if asNew { args.append("--as-new") }
            let result = Meowlti.run(args)
            // Reopen the target if we closed it, or if there is something new to continue there.
            if (result.ok && target?.desktopSignedIn == true) || wasRunning { _ = Meowlti.run(["open", to, "claude"]) }
            await MainActor.run {
                self.busy.remove(from)
                let toName = target?.displayName ?? to
                let out = result.output
                if result.ok {
                    let where_ = out.contains("Code tab")
                        ? "'\(toName)' Claude 창의 Code 탭 목록에서 이어서 진행하세요."
                        : "터미널에서 이어가세요: cd \(session.cwd) && meowlti claude \(to) --resume <세션 ID>"
                    if out.contains("already has the same") {
                        self.notice = ("'\(toName)'에 이미 같은 대화가 있습니다. 복사할 내용이 없습니다.", false)
                    } else if out.contains("newer version") {
                        self.notice = ("'\(toName)' 쪽 대화가 더 최신이라 복사하지 않았습니다. 반대 방향으로 가져오세요.", false)
                    } else if out.contains("Updated") {
                        self.notice = ("'\(toName)'의 '\(session.title)'을(를) 최신 대화로 갱신했습니다. \(where_)", false)
                    } else if out.contains("separate session") {
                        self.notice = ("'\(toName)'에 '\(session.title) (copy)'라는 별도 세션으로 복사했습니다. \(where_)", false)
                    } else {
                        self.notice = ("'\(session.title)' 세션을 '\(toName)'에 복사했습니다. \(where_)", false)
                    }
                } else if out.contains("CROSS_ORG") {
                    self.crossOrgRequest = (from, session, to)
                } else if out.contains("DIVERGED") {
                    self.divergedRequest = (from, session, to, allowCrossOrg)
                } else {
                    self.notice = (result.message, true)
                }
                self.refresh()
            }
        }
    }

    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stopAutoRefresh() { timer?.invalidate(); timer = nil }

    /// Run a CLI command for a profile; show only failures unless a success text is given.
    func perform(_ args: [String], for name: String, success: String? = nil, then: (() -> Void)? = nil) {
        busy.insert(name)
        Task.detached {
            let result = Meowlti.run(args)
            await MainActor.run {
                self.busy.remove(name)
                if !result.ok {
                    self.notice = (result.message, true)
                } else if let success {
                    self.notice = (success, false)
                }
                self.refresh()
                if result.ok { then?() }
            }
        }
    }

    /// Wait for the profile's window to sign in. `exclusive` closes the other Claude windows meanwhile
    /// (needed for Google sign-in, whose claude:// return link otherwise goes to the normal window).
    func startLogin(_ name: String, exclusive: Bool = false) {
        guard loginProcesses[name] == nil else { return }
        let (process, pipe) = Meowlti.makeProcess(["login", name] + (exclusive ? ["--exclusive"] : []))
        do { try process.run() } catch {
            notice = ("로그인 대기를 시작하지 못했습니다: \(error.localizedDescription)", true)
            return
        }
        loginProcesses[name] = process
        loginWaiting.insert(name)
        if exclusive { loginExclusive.insert(name) }
        Task.detached {
            let result = Meowlti.wait(process, pipe)
            await MainActor.run {
                let cancelled = self.loginProcesses[name] == nil
                self.loginProcesses[name] = nil
                self.loginWaiting.remove(name)
                self.loginExclusive.remove(name)
                if cancelled { return }
                let reopened = result.output.contains("Reopened") ? " 잠시 닫았던 Claude 창들도 다시 열었습니다." : ""
                self.notice = result.ok
                    ? (result.output.contains("already signed in")
                        ? ("'\(name)'은(는) 이미 로그인되어 있습니다. 다른 계정으로 바꾸려면 그 창에서 먼저 로그아웃하세요.", false)
                        : ("'\(name)' 로그인을 확인했습니다.\(reopened)", false))
                    : (result.message, true)
                self.refresh()
            }
        }
    }

    func cancelLogin(_ name: String) {
        guard let p = loginProcesses.removeValue(forKey: name) else { return }
        // Interrupt (not kill) so an --exclusive login still reopens the windows it closed.
        p.interrupt()
        loginWaiting.remove(name)
        loginExclusive.remove(name)
    }

    func addProfile(name: String, label: String, openAfter: Bool) {
        busy.insert(name)
        Task.detached {
            var result = Meowlti.run(["add", name])
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok, !trimmed.isEmpty { result = Meowlti.run(["label", name, trimmed]) }
            if result.ok, openAfter { result = Meowlti.run(["open", name, "claude"]) }
            let final = result
            await MainActor.run {
                let result = final
                self.busy.remove(name)
                if result.ok {
                    self.selection = name
                    self.notice = (openAfter
                        ? "'\(name)' 프로필을 만들고 Claude 창을 열었습니다. 그 창에서 이 프로필에 쓸 계정으로 로그인하세요."
                        : "'\(name)' 프로필을 만들었습니다.", false)
                } else {
                    self.notice = (result.message, true)
                }
                self.refresh()
            }
        }
    }
}

// MARK: - Views

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Color.green : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
    }
}

struct ManagerView: View {
    @ObservedObject var store: Store

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.profiles) { p in
                    HStack(spacing: 8) {
                        StatusDot(on: p.claudeRunning || p.codexRunning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName).fontWeight(.medium)
                            Text((p.accountsDiffer ? "⚠ " : "") + p.accountSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(p.name)
                    .padding(.vertical, 2)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { store.showingAdd = true } label: { Label("새 프로필", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("add-profile")
                    Spacer()
                }
                .padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                if let n = store.notice {
                    NoticeBar(text: n.text, isError: n.isError) { store.notice = nil }
                }
                if let p = store.profiles.first(where: { $0.name == store.selection }) {
                    ProfileDetail(store: store, profile: p)
                } else {
                    EmptyState { store.showingAdd = true }
                }
            }
        }
        .sheet(isPresented: $store.showingAdd) {
            AddProfileSheet(existing: Set(store.profiles.map(\.name))) { name, label, openAfter in
                store.addProfile(name: name, label: label, openAfter: openAfter)
            }
        }
        .onChange(of: store.selection) { store.refreshShares() }
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct NoticeBar: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("notice-text")
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                .accessibilityIdentifier("notice-dismiss")
        }
        .padding(10)
        .background((isError ? Color.orange : Color.green).opacity(0.12))
    }
}

struct EmptyState: View {
    let add: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cat").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("프로필이 없습니다").font(.title3)
            Text("계정마다 프로필을 하나씩 만들면, 각 계정의 Claude·Codex를 동시에 띄울 수 있습니다.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("새 프로필 만들기", action: add).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProfileDetail: View {
    @ObservedObject var store: Store
    let profile: Profile
    @State private var labelDraft = ""
    @State private var confirmDelete = false

    private var busy: Bool { store.busy.contains(profile.name) }
    private var waitingLogin: Bool { store.loginWaiting.contains(profile.name) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName).font(.title2).fontWeight(.semibold)
                    Text(profile.isDefault
                         ? "평소에 쓰는 Claude·Codex입니다. 프로필 창이 떠 있어 Dock 아이콘으로 열리지 않을 때 여기서 여세요."
                         : "프로필 ID: \(profile.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("계정") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(profile.accountSummary)
                        if profile.email == nil && profile.desktopSignedIn {
                            Text("이메일은 이 프로필에서 Code 탭을 한 번 쓰면 표시됩니다")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if profile.accountsDiffer {
                            Label("CLI·Code 탭 계정이 데스크톱 로그인과 다릅니다. 한 프로필에 계정이 섞여 세션·메모리가 공유됩니다.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            Section("Claude 데스크톱") {
                LabeledContent("상태") {
                    HStack(spacing: 6) { StatusDot(on: profile.claudeRunning); Text(profile.claudeRunning ? "실행 중" : "꺼짐") }
                }
                HStack {
                    Button(profile.claudeRunning ? "앞으로 가져오기" : "열기") {
                        store.perform(["open", profile.name, "claude"], for: profile.name)
                    }
                    .accessibilityIdentifier("claude-open")
                    Button("종료") { store.perform(["quit", profile.name, "claude"], for: profile.name) }
                        .disabled(!profile.claudeRunning)
                        .accessibilityIdentifier("claude-quit")
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                .disabled(busy)
                LoginRow(store: store, name: profile.name, waiting: waitingLogin)
            }

            if !profile.isDefault {
            Section {
                LabeledContent("로그인", value: { switch store.claudeCLILogin {
                    case "yes": return "됨"
                    case "no": return "안 됨"
                    case "-": return "claude CLI 없음"
                    default: return "확인 중…"
                } }())
            } header: {
                Text("Claude Code CLI")
            } footer: {
                Text("데스크톱 로그인과 별개입니다. 터미널에서 한 번 로그인하세요: meowlti claude \(profile.name) auth login · 실행: meowlti claude \(profile.name)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            }

            Section {
                LabeledContent("데스크톱 상태") {
                    HStack(spacing: 6) { StatusDot(on: profile.codexRunning); Text(profile.codexRunning ? "실행 중" : "꺼짐") }
                }
                HStack {
                    Button(profile.codexRunning ? "앞으로 가져오기" : "열기") {
                        store.perform(["open", profile.name, "codex"], for: profile.name)
                    }
                    .accessibilityIdentifier("codex-open")
                    Button("종료") { store.perform(["quit", profile.name, "codex"], for: profile.name) }
                        .disabled(!profile.codexRunning)
                        .accessibilityIdentifier("codex-quit")
                }
                .disabled(busy)
                LabeledContent("CLI 로그인", value: profile.codexCLILoggedIn ? "됨" : "안 됨")
            } header: {
                Text(profile.isDefault ? "Codex" : "Codex (실험적)")
            } footer: {
                Text(profile.isDefault ? "CLI는 평소처럼 codex로 실행합니다." : "CLI 로그인: 터미널에서 meowlti codex \(profile.name) login")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !profile.isDefault {

            Section {
                HStack {
                    TextField("표시 이름", text: $labelDraft, prompt: Text(profile.name))
                        .onSubmit(saveLabel)
                        .accessibilityIdentifier("label-field")
                    Button("저장", action: saveLabel)
                        .accessibilityIdentifier("label-save")
                        .disabled(labelDraft.trimmingCharacters(in: .whitespaces) == (profile.label ?? ""))
                }
            } header: {
                Text("표시 이름")
            } footer: {
                Text("메뉴와 이 창에 보이는 이름입니다. 프로필 ID와 저장 폴더는 바뀌지 않습니다 (데스크톱 앱 기록이 경로에 묶여 있어서).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            FoldersSection(store: store, profile: profile)

            SessionsSection(store: store, profile: profile)

            ShareSection(store: store, profile: profile, tool: "claude", title: "공유 설정 · Claude",
                         source: "~/.claude", items: store.claudeShares)
            ShareSection(store: store, profile: profile, tool: "codex", title: "공유 설정 · Codex",
                         source: "~/.codex", items: store.codexShares)

            Section {
                HStack {
                    Button("프로필 폴더 열기") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "\(Meowlti.home)/profiles/\(profile.name)"))
                    }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("프로필 삭제…").foregroundStyle(.red)
                    }
                    .accessibilityIdentifier("profile-delete")
                }
            }
            }
        }
        .formStyle(.grouped)
        .onAppear { labelDraft = profile.label ?? "" }
        .onChange(of: profile.name) { labelDraft = profile.label ?? "" }
        .confirmationDialog("'\(profile.displayName)' 프로필을 삭제할까요?", isPresented: $confirmDelete) {
            Button("휴지통으로 이동", role: .destructive) {
                store.perform(["rm", profile.name, "--yes"], for: profile.name,
                              success: "'\(profile.displayName)' 프로필을 휴지통으로 옮겼습니다.")
            }
        } message: {
            Text("실행 중인 창을 종료한 뒤 로그인·채팅·Code 세션 데이터를 휴지통으로 옮깁니다.")
        }
    }

    private func saveLabel() {
        let text = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            store.perform(["label", profile.name, "--clear"], for: profile.name)
        } else {
            store.perform(["label", profile.name, text], for: profile.name)
        }
    }
}

struct LoginRow: View {
    @ObservedObject var store: Store
    let name: String
    let waiting: Bool
    @State private var confirmExclusive = false

    var body: some View {
        if waiting {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("로그인을 기다리는 중…").fontWeight(.medium)
                    Spacer()
                    Button("취소") { store.cancelLogin(name) }
                        .accessibilityIdentifier("login-cancel")
                }
                Text(store.loginExclusive.contains(name)
                     ? "다른 Claude 창은 잠시 닫혀 있습니다. 이 프로필 창에서 아무 방법으로나 로그인하세요. 끝나면 닫았던 창을 다시 엽니다 (최대 10분)."
                     : "이 프로필 창에서 '이메일로 계속하기'로 로그인하세요. 로그인되면 자동으로 확인합니다 (최대 5분).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("로그인 시작") { store.startLogin(name) }
                        .accessibilityIdentifier("login-start")
                    Button("Google로 로그인…") { confirmExclusive = true }
                        .accessibilityIdentifier("login-exclusive")
                }
                Text("이메일 로그인은 다른 창을 그대로 둔 채 할 수 있습니다. Google 로그인은 돌아오는 링크가 평소 쓰는 Claude 창으로 가서, 로그인하는 동안 다른 Claude 창을 잠시 닫습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("다른 Claude 창을 잠시 닫고 로그인할까요?", isPresented: $confirmExclusive) {
                Button("닫고 로그인") { store.startLogin(name, exclusive: true) }
            } message: {
                Text("평소 쓰는 Claude와 다른 프로필 창을 정상 종료한 뒤 이 프로필 창만 띄웁니다. 로그인이 끝나면 닫았던 창을 다시 엽니다. 진행 중인 Code 세션은 저장된 상태로 다시 이어집니다.")
            }
        }
    }
}

struct FoldersSection: View {
    @ObservedObject var store: Store
    let profile: Profile

    var body: some View {
        Section {
            if store.boundFolders.isEmpty {
                Text("지정한 폴더가 없습니다").foregroundStyle(.secondary)
            }
            ForEach(store.boundFolders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("해제") {
                        store.perform(["unbind", folder], for: profile.name) { store.refreshShares() }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("folder-unbind")
                }
            }
            HStack {
                Button("폴더 추가…", action: chooseFolder)
                    .accessibilityIdentifier("folder-add")
                Spacer()
                if store.shellInstalled == false {
                    Button("터미널 연동 설치") {
                        store.perform(["shell-init", "--install"], for: profile.name,
                                      success: "~/.zshrc에 터미널 연동을 추가했습니다. 새 터미널 창부터 적용됩니다.") {
                            store.refreshShares()
                        }
                    }
                } else if store.shellInstalled == true {
                    Label("터미널 연동 설치됨", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.caption)
                }
            }
            .disabled(store.busy.contains(profile.name))
        } header: {
            Text("폴더 지정")
        } footer: {
            Text("지정한 폴더(하위 폴더 포함)에서 터미널에 claude나 codex만 입력해도 이 프로필로 실행됩니다. 터미널 연동이 필요하고, 데스크톱 Code 탭에는 적용되지 않습니다. 건너뛰려면 command claude.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "이 폴더 지정"
        panel.message = "'\(profile.displayName)' 프로필로 실행할 프로젝트 폴더를 고르세요."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.perform(["bind", profile.name, url.path], for: profile.name) { store.refreshShares() }
    }
}

struct SessionsSection: View {
    @ObservedObject var store: Store
    let profile: Profile
    @State private var pending: (session: CodeSession, to: String)?
    @State private var showAll = false

    // copy-session works between profiles only; the default setup is not a target.
    private var targets: [Profile] { store.profiles.filter { $0.name != profile.name && !$0.isDefault } }
    private var shown: [CodeSession] { showAll ? store.sessions : Array(store.sessions.prefix(5)) }

    var body: some View {
        Section {
            if store.sessions.isEmpty {
                Text("이 프로필에는 아직 Code 세션이 없습니다").foregroundStyle(.secondary)
            }
            ForEach(shown) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).lineLimit(1)
                        Text(s.lastActivity.formatted(.relative(presentation: .named)) + (s.fromDesktop ? " · Code 탭" : " · CLI"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("이어서 하기") {
                        if targets.isEmpty { Text("다른 프로필이 없습니다") }
                        ForEach(targets) { t in
                            Button("\(t.displayName)  —  \(t.accountSummary)") { pending = (s, t.name) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("session-continue")
                    .disabled(store.busy.contains(profile.name))
                }
            }
            if store.sessions.count > 5 {
                Button(showAll ? "최근 5개만 보기" : "전체 \(store.sessions.count)개 보기") { showAll.toggle() }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text("Code 세션")
        } footer: {
            Text("다른 프로필로 복사해서 그 계정으로 이어갑니다. 원래 세션은 그대로 남습니다. 이미 복사한 세션을 다시 보내면 최신 대화로 갱신합니다(A → B → A). 데스크톱 채팅은 서버에 저장되어 옮길 수 없습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("복사하고 열기") {
                if let p = pending { store.copySession(from: profile.name, session: p.session, to: p.to) }
                pending = nil
            }
        } message: {
            Text(confirmMessage)
        }
        .alert("조직이 다른 계정입니다", isPresented: Binding(
            get: { store.crossOrgRequest?.from == profile.name },
            set: { if !$0 { store.crossOrgRequest = nil } })) {
            Button("그래도 복사", role: .destructive) {
                if let r = store.crossOrgRequest {
                    store.copySession(from: r.from, session: r.session, to: r.to, allowCrossOrg: true)
                }
                store.crossOrgRequest = nil
            }
            Button("취소", role: .cancel) { store.crossOrgRequest = nil }
        } message: {
            Text("이 세션의 대화 내용(코드, 파일 내용 포함)이 다른 조직의 계정으로 넘어갑니다. 회사 데이터 정책에 맞는지 확인한 뒤 진행하세요.")
        }
        .alert("양쪽에서 따로 이어간 세션입니다", isPresented: Binding(
            get: { store.divergedRequest?.from == profile.name },
            set: { if !$0 { store.divergedRequest = nil } })) {
            Button("새 세션으로 복사") {
                if let r = store.divergedRequest {
                    store.copySession(from: r.from, session: r.session, to: r.to, allowCrossOrg: r.allowCrossOrg, asNew: true)
                }
                store.divergedRequest = nil
            }
            Button("취소", role: .cancel) { store.divergedRequest = nil }
        } message: {
            Text("이 세션은 두 프로필에서 각각 대화가 진행되어 하나로 합칠 수 없습니다. 덮어쓰면 한쪽 대화가 사라지므로, 대상 프로필에 '(copy)' 이름의 별도 세션으로 복사할 수 있습니다. 원래 세션들은 그대로 남습니다.")
        }
    }

    private var targetName: String {
        guard let p = pending else { return "" }
        return store.profiles.first { $0.name == p.to }?.displayName ?? p.to
    }
    private var confirmTitle: String { "'\(pending?.session.title ?? "")'을(를) '\(targetName)'에서 이어갈까요?" }
    private var confirmMessage: String {
        let running = store.profiles.first { $0.name == pending?.to }?.claudeRunning == true
        let desktop = store.profiles.first { $0.name == pending?.to }?.desktopSignedIn == true
        if running {
            return "'\(targetName)' Claude 창이 켜져 있어 잠시 종료했다가 다시 엽니다. 그 창에서 진행 중인 작업이 있다면 먼저 마무리하세요."
        }
        return desktop
            ? "복사한 뒤 '\(targetName)' Claude 창을 엽니다."
            : "'\(targetName)'은(는) 데스크톱 로그인이 없어 CLI로 이어가도록 복사합니다."
    }
}

struct ShareSection: View {
    @ObservedObject var store: Store
    let profile: Profile
    let tool: String
    let title: String
    let source: String
    let items: [ShareItem]

    var body: some View {
        Section {
            if items.isEmpty {
                Text("\(source)에 공유할 수 있는 항목이 없습니다").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Toggle(isOn: Binding(
                    get: { item.state == .shared },
                    set: { on in
                        store.perform([on ? "share" : "unshare", profile.name, tool, item.name], for: profile.name) {
                            store.refreshShares()
                        }
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        if item.state == .local {
                            Text("이 프로필에 따로 만든 파일이 있어 공유할 수 없습니다").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(item.state == .local || store.busy.contains(profile.name))
                .accessibilityIdentifier("share-\(tool)-\(item.name)")
            }
        } header: {
            Text(title)
        } footer: {
            Text("켜면 기본 계정의 \(source) 항목을 이 프로필에서 같이 씁니다. 로그인·세션·메모리 기록은 공유되지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AddProfileSheet: View {
    let existing: Set<String>
    let create: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var label = ""
    @State private var openAfter = true

    private var problem: String? {
        if name.isEmpty { return nil }
        if !Meowlti.isValidName(name) { return "영문 소문자, 숫자, '-'만 쓸 수 있고 첫 글자는 '-'일 수 없습니다." }
        if existing.contains(name) { return "같은 ID의 프로필이 이미 있습니다." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 프로필").font(.title2).fontWeight(.semibold)
            Form {
                TextField("프로필 ID", text: $name, prompt: Text("예: personal"))
                    .accessibilityIdentifier("new-id")
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    Text("폴더 이름으로 쓰이며 나중에 바꿀 수 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("표시 이름 (선택)", text: $label, prompt: Text("예: 개인 계정"))
                    .accessibilityIdentifier("new-label")
                Toggle("만든 뒤 바로 Claude 창 열기", isOn: $openAfter)
                    .accessibilityIdentifier("new-open-after")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("new-cancel")
                Button("만들기") {
                    create(name, label, openAfter)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || problem != nil)
                .accessibilityIdentifier("new-create")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, @MainActor SPUStandardUserDriverDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    let store = Store()
    private var window: NSWindow?
    /// Sparkle checks GitHub releases for a newer signed build. Only builds that carry the update
    /// signing key (release builds) start it; local development builds leave it off.
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
        updaterDelegate: nil, userDriverDelegate: self)

    // Gentle reminders: as a menu bar app with no Dock icon, an update window found by a
    // scheduled check could sit unnoticed behind other windows. While Sparkle shows an update,
    // join the Dock and come forward (with a badge if the user did not ask), then go back.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !state.userInitiated { NSApp.dockTile.badgeLabel = "1" }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.dockTile.badgeLabel = ""
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.dockTile.badgeLabel = ""
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.image
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "meowlti")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "meowlti"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        _ = updaterController   // starts Sparkle (release builds only)
        if CommandLine.arguments.contains("--show") { showManager() }
        // `--check-updates`: same as choosing 업데이트 확인… (useful for diagnosing updates).
        if CommandLine.arguments.contains("--check-updates"),
           Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updaterController.checkForUpdates(nil) }
        }
    }

    // Opening the app again from Finder/Spotlight shows the management window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager()
        return true
    }

    // Rebuild on open so running state is current.
    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu(menu, profiles: Meowlti.profiles()) }

    func buildMenu(_ menu: NSMenu, profiles: [Profile]) {
        menu.removeAllItems()
        if profiles.isEmpty {
            let empty = NSMenuItem(title: "프로필 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for p in profiles {
            let running = p.claudeRunning || p.codexRunning
            let top = NSMenuItem(title: "\(running ? "●" : "○")  \(p.displayName)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            let acct = NSMenuItem(title: p.accountSummary, action: nil, keyEquivalent: "")
            acct.isEnabled = false
            sub.addItem(acct)
            sub.addItem(.separator())
            sub.addItem(item(p.claudeRunning ? "Claude 앞으로 가져오기" : "Claude 열기", #selector(openClaude), p.name))
            sub.addItem(item("Claude 종료", #selector(quitClaude), p.name, enabled: p.claudeRunning))
            sub.addItem(.separator())
            let exp = p.isDefault ? "" : " (실험적)"   // only profile windows of Codex desktop are experimental
            sub.addItem(item(p.codexRunning ? "Codex 앞으로 가져오기\(exp)" : "Codex 열기\(exp)", #selector(openCodex), p.name))
            sub.addItem(item("Codex 종료", #selector(quitCodex), p.name, enabled: p.codexRunning))
            sub.addItem(.separator())
            sub.addItem(item("설정…", #selector(showProfile), p.name))
            top.submenu = sub
            menu.addItem(top)
        }
        menu.addItem(.separator())
        menu.addItem(item("새 프로필 추가…", #selector(addProfile)))
        let manage = item("프로필 관리…", #selector(showManager))
        manage.keyEquivalent = ","
        menu.addItem(manage)
        menu.addItem(.separator())
        if Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil {
            let update = NSMenuItem(title: "업데이트 확인…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
            update.target = updaterController
            update.isEnabled = updaterController.updater.canCheckForUpdates
            menu.addItem(update)
        }
        menu.addItem(item("MeowltiBar 종료", #selector(quitApp)))
    }

    private func item(_ title: String, _ action: Selector, _ profile: String? = nil, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.representedObject = profile
        it.isEnabled = enabled
        return it
    }

    private func run(_ args: [String], _ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task.detached {
            let result = Meowlti.run(args + [])
            if !result.ok {
                await MainActor.run {
                    self.showManager()
                    self.store.selection = name
                    self.store.notice = (result.message, true)
                }
            }
        }
    }

    @objc private func openClaude(_ s: NSMenuItem) { run(["open", s.representedObject as? String ?? "", "claude"], s) }
    @objc private func quitClaude(_ s: NSMenuItem) { run(["quit", s.representedObject as? String ?? "", "claude"], s) }
    @objc private func openCodex(_ s: NSMenuItem) { run(["open", s.representedObject as? String ?? "", "codex"], s) }
    @objc private func quitCodex(_ s: NSMenuItem) { run(["quit", s.representedObject as? String ?? "", "codex"], s) }

    @objc private func showProfile(_ s: NSMenuItem) {
        showManager()
        store.selection = s.representedObject as? String
    }

    @objc private func addProfile() {
        showManager()
        store.showingAdd = true
    }

    @objc func showManager() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "meowlti"
            w.contentViewController = NSHostingController(rootView: ManagerView(store: store))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MeowltiManager")
            w.delegate = self
            w.center()
            window = w
        }
        store.startAutoRefresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { store.stopAutoRefresh() }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// The app icon (alerts, Finder): the menu bar cat on a rounded tile.
enum AppIcon {
    static func render(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let tile = NSBezierPath(roundedRect: inset, xRadius: size * 0.18, yRadius: size * 0.18)
            NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
                                NSColor(calibratedRed: 0.90, green: 0.40, blue: 0.30, alpha: 1)])?
                .draw(in: tile, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let cat = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = cat.size
                cat.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
    static let image = render(size: 512)
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }

// `MeowltiBar --dump-menu` prints the menu, for checking without clicking.
// `MeowltiBar --write-icon <dir>` writes the icon PNGs used by build.sh.
let args = CommandLine.arguments
if args.contains("--dump-menu") {
    MainActor.assumeIsolated {
        let menu = NSMenu()
        delegate.buildMenu(menu, profiles: Meowlti.profiles())
        func dump(_ m: NSMenu, _ depth: Int) {
            for it in m.items {
                let pad = String(repeating: "  ", count: depth)
                if it.isSeparatorItem { print("\(pad)---"); continue }
                print("\(pad)\(it.title)\(it.isEnabled ? "" : "  [disabled]")")
                if let sub = it.submenu { dump(sub, depth + 1) }
            }
        }
        dump(menu, 0)
    }
    exit(0)
}
if let i = args.firstIndex(of: "--write-icon"), i + 1 < args.count {
    let dir = args[i + 1]
    for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                       (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
        let img = AppIcon.render(size: CGFloat(px))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
    }
    exit(0)
}

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
