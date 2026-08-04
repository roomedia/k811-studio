import AppKit
import K811Core
import SwiftUI

@main
struct K811MacApp: App {
  @StateObject private var controller = K811Controller()

  var body: some Scene {
    WindowGroup("K811 Studio") {
      ContentView(controller: controller)
    }
    .windowResizability(.contentSize)
  }
}

struct K811EffectChoice: Hashable, Identifiable {
  let mode: K811LightingMode?
  let id: String
  let displayName: String

  static let agent = K811EffectChoice(mode: nil, id: "agent", displayName: "에이전트")
  static let allCases =
    K811LightingMode.allCases.map {
      K811EffectChoice(mode: $0, id: "lighting-\($0.rawValue)", displayName: $0.displayName)
    } + [.agent]

  static func lighting(_ mode: K811LightingMode) -> K811EffectChoice {
    allCases.first { $0.mode == mode }!
  }

  var isAgent: Bool { mode == nil }
}

@MainActor
final class K811Controller: ObservableObject {
  @Published var device: K811DeviceInfo?
  @Published var status = "장치를 확인하는 중…"
  @Published var selectedEffect = K811EffectChoice.lighting(.fixed)
  @Published var selectedColor = Color(red: 0.20, green: 0.55, blue: 1.00)
  @Published var brightness = 180.0
  @Published var speed = 2.0
  @Published var autoColor = false
  @Published var isApplying = false
  @Published var agentStatus = "상주 앱 없이 hook이 K811을 직접 제어합니다."
  @Published var selectedLayer = K811Layer.standard
  @Published var keymapProfile = K811KeymapProfile()
  @Published var keymapStatus = "로컬 키 설정 초안을 불러오는 중…"
  @Published var isWritingKeymap = false
  @Published var recoveryBaselineAvailable = false
  @Published var lastKeymapBackupURL: URL?
  @Published var openCodeEnabled: Bool {
    didSet { defaults.set(openCodeEnabled, forKey: DefaultsKey.openCode) }
  }
  @Published var piEnabled: Bool {
    didSet { defaults.set(piEnabled, forKey: DefaultsKey.pi) }
  }
  @Published var antigravityEnabled: Bool {
    didSet { defaults.set(antigravityEnabled, forKey: DefaultsKey.antigravity) }
  }

  private let defaults: UserDefaults
  private let stateStore = K811AgentStateStore()
  private let profileStore: K811KeymapProfileStore
  private let backupStore: K811KeymapBackupStore

  var isBusy: Bool {
    isApplying || isWritingKeymap
  }

  private enum DefaultsKey {
    static let openCode = "agentSourceOpenCode"
    static let pi = "agentSourcePi"
    static let antigravity = "agentSourceAntigravity"
  }

  init(
    defaults: UserDefaults = .standard,
    profileStore: K811KeymapProfileStore = K811KeymapProfileStore(),
    backupStore: K811KeymapBackupStore = K811KeymapBackupStore()
  ) {
    self.defaults = defaults
    self.profileStore = profileStore
    self.backupStore = backupStore
    openCodeEnabled = defaults.bool(forKey: DefaultsKey.openCode)
    piEnabled = defaults.bool(forKey: DefaultsKey.pi)
    antigravityEnabled = defaults.bool(forKey: DefaultsKey.antigravity)
    do {
      keymapProfile = try profileStore.load()
      keymapStatus =
        keymapProfile.isEmpty
        ? "저장된 키 설정 없음"
        : "저장된 키 설정 \(keymapProfile.assignments.count)개"
    } catch {
      keymapProfile = K811KeymapProfile()
      keymapStatus = "로컬 키 설정을 불러오지 못했습니다: \(error.localizedDescription)"
    }
    do {
      recoveryBaselineAvailable = try profileStore.loadApplied() != nil
      if !recoveryBaselineAvailable {
        keymapStatus += " · 안전 적용 전 키보드 초기화 필요"
      }
    } catch {
      recoveryBaselineAvailable = false
      keymapStatus += " · 복구 baseline을 불러오지 못했습니다: \(error.localizedDescription)"
    }
    refreshDevice()
  }

  func refreshDevice() {
    guard !isBusy else { return }
    let transport = K811HIDTransport()
    do {
      device = try transport.connect()
      transport.disconnect()
      status = "K811 확인됨 · 현재 HID 미점유"
    } catch {
      transport.disconnect()
      device = nil
      status = error.localizedDescription
    }
  }

  func outputUsage(for key: K811PhysicalKey) -> UInt8? {
    keymapProfile.assignment(for: key, layer: selectedLayer)?.outputUsage
  }

  func modifierUsage(for key: K811PhysicalKey) -> UInt8? {
    keymapProfile.assignment(for: key, layer: selectedLayer)?.modifierUsage
  }

  func setOutputUsage(_ usage: UInt8?, for key: K811PhysicalKey) {
    do {
      var updatedProfile = keymapProfile
      if let usage {
        try updatedProfile.setAssignment(
          for: key,
          layer: selectedLayer,
          outputUsage: usage,
          modifierUsage: modifierUsage(for: key)
        )
      } else {
        updatedProfile.removeAssignment(for: key, layer: selectedLayer)
      }
      try profileStore.save(updatedProfile)
      keymapProfile = updatedProfile
      keymapStatus = "로컬 초안 저장됨 · \(keymapProfile.assignments.count)개"
    } catch {
      keymapStatus = "로컬 초안을 저장하지 못했습니다: \(error.localizedDescription)"
    }
  }

  func setModifierUsage(_ usage: UInt8?, for key: K811PhysicalKey) {
    guard let assignment = keymapProfile.assignment(for: key, layer: selectedLayer) else {
      return
    }
    do {
      var updatedProfile = keymapProfile
      try updatedProfile.setAssignment(
        for: key,
        layer: selectedLayer,
        outputUsage: assignment.outputUsage,
        modifierUsage: usage
      )
      try profileStore.save(updatedProfile)
      keymapProfile = updatedProfile
      keymapStatus = "로컬 초안 저장됨 · \(keymapProfile.assignments.count)개"
    } catch {
      keymapStatus = "로컬 초안을 저장하지 못했습니다: \(error.localizedDescription)"
    }
  }

  func applyKeymap() {
    guard !isBusy, !keymapProfile.isEmpty else { return }
    guard recoveryBaselineAvailable else {
      keymapStatus = "안전한 자동복구를 위해 먼저 키보드 초기화를 실행해주세요."
      return
    }
    let profile = keymapProfile
    let recovery: K811KeymapProfile
    do {
      guard let loadedRecovery = try profileStore.loadApplied() else {
        recoveryBaselineAvailable = false
        keymapStatus = "복구 baseline이 없습니다. 먼저 키보드 초기화를 실행해주세요."
        return
      }
      recovery = loadedRecovery
    } catch {
      recoveryBaselineAvailable = false
      keymapStatus = "복구 baseline을 읽지 못했습니다: \(error.localizedDescription)"
      return
    }
    let profileStore = profileStore
    let backupStore = backupStore
    isWritingKeymap = true
    keymapStatus = "base snapshot을 백업하고 키 설정 \(profile.assignments.count)개를 전송하는 중…"

    Task {
      defer { isWritingKeymap = false }
      do {
        let backupURL = try await Task.detached(priority: .userInitiated) {
          try K811KeymapRecoveryCoordinator.apply(
            target: profile,
            recovery: recovery,
            backupBaseSnapshot: {
              try Self.backupCurrentBase(using: backupStore)
            },
            write: { image in
              try Self.writeKeymapImage(image)
            },
            persistApplied: { applied in
              try profileStore.saveApplied(applied)
            },
            invalidateApplied: {
              try? profileStore.invalidateApplied()
            }
          )
        }.value
        lastKeymapBackupURL = backupURL
        recoveryBaselineAvailable = true
        keymapStatus =
          "키 설정 \(profile.assignments.count)개 적용 완료 · 백업 \(backupURL.lastPathComponent)"
        status = "K811 확인됨 · 현재 HID 미점유"
      } catch {
        updateBaselineAvailability(after: error)
        keymapStatus = error.localizedDescription
      }
    }
  }

  func resetKeymap() {
    guard !isBusy else { return }
    let emptyProfile = K811KeymapProfile()
    let recovery: K811KeymapProfile
    do {
      recovery = try profileStore.loadApplied() ?? emptyProfile
    } catch {
      try? profileStore.invalidateApplied()
      recoveryBaselineAvailable = false
      recovery = emptyProfile
    }
    let profileStore = profileStore
    let backupStore = backupStore
    isWritingKeymap = true
    keymapStatus = "base snapshot을 백업하고 key override를 초기화하는 중…"

    Task {
      defer { isWritingKeymap = false }
      do {
        let backupURL = try await Task.detached(priority: .userInitiated) {
          try K811KeymapRecoveryCoordinator.apply(
            target: emptyProfile,
            recovery: recovery,
            backupBaseSnapshot: {
              try Self.backupCurrentBase(using: backupStore)
            },
            write: { image in
              try Self.writeKeymapImage(image)
            },
            persistApplied: { applied in
              try profileStore.saveApplied(applied)
            },
            invalidateApplied: {
              try? profileStore.invalidateApplied()
            }
          )
        }.value

        lastKeymapBackupURL = backupURL
        recoveryBaselineAvailable = true
        status = "K811 확인됨 · 현재 HID 미점유"
        var emptyProfile = keymapProfile
        emptyProfile.removeAll()
        do {
          try profileStore.save(emptyProfile)
          keymapProfile = emptyProfile
          keymapStatus =
            "키보드와 로컬 초안을 공장 기본으로 초기화했습니다 · 백업 \(backupURL.lastPathComponent)"
        } catch {
          keymapStatus = "키보드는 초기화됐지만 로컬 초안 저장에 실패했습니다: \(error.localizedDescription)"
        }
      } catch {
        updateBaselineAvailability(after: error)
        keymapStatus = error.localizedDescription
      }
    }
  }

  nonisolated private static func backupCurrentBase(
    using backupStore: K811KeymapBackupStore
  ) throws -> URL {
    let transport = K811HIDTransport()
    defer { transport.disconnect() }
    _ = try transport.connect()
    let snapshot = try K811KeymapProtocol.readSnapshot(using: transport)
    return try backupStore.save(snapshot)
  }

  nonisolated private static func writeKeymapImage(_ image: K811KeymapWriteImage) throws {
    let transport = K811HIDTransport()
    defer { transport.disconnect() }
    _ = try transport.connect()
    try K811KeymapProtocol.writeImage(image, using: transport)
  }

  private func updateBaselineAvailability(after error: Error) {
    guard let applyError = error as? K811KeymapApplyError else { return }
    switch applyError {
    case .targetWriteAndRecoveryFailed, .appliedProfileSaveAndRecoveryFailed:
      recoveryBaselineAvailable = false
    case .baseSnapshotBackupFailed,
      .targetWriteFailedRecovered,
      .appliedProfileSaveFailedRecovered:
      break
    }
  }

  func applyLighting() {
    guard !isBusy else { return }
    if selectedEffect.isAgent {
      clearAgentSignals()
      return
    }

    guard let selectedMode = selectedEffect.mode else { return }
    guard let rgb = selectedColor.rgbBytes else {
      status = "선택한 색상을 sRGB로 변환하지 못했습니다."
      return
    }

    isApplying = true
    status = "조명 설정을 전송하는 중…"
    defer { isApplying = false }
    do {
      device = try K811LightingWriter.apply(
        mode: selectedMode,
        red: rgb.red,
        green: rgb.green,
        blue: rgb.blue,
        brightness: UInt8(brightness.rounded()),
        speed: UInt8(speed.rounded()),
        autoColor: autoColor
      )
      status = "조명 설정을 적용했습니다 · HID 연결 해제됨"
    } catch {
      status = error.localizedDescription
    }
  }

  func clearAgentSignals() {
    guard !isBusy else { return }
    isApplying = true
    status = "에이전트 알림을 초기화하는 중…"
    defer { isApplying = false }
    do {
      try stateStore.clearAll { _ in
        self.device = try K811LightingWriter.turnOff()
      }
      status = "모든 에이전트 알림을 확인했습니다 · 조명 꺼짐 · HID 연결 해제됨"
      agentStatus = "대기 중 · 다음 hook이 장치를 직접 엽니다."
    } catch {
      status = error.localizedDescription
      agentStatus = "초기화 실패"
    }
  }
}

private struct ContentView: View {
  @ObservedObject var controller: K811Controller
  @State private var selectedSection = K811StudioSection.lighting

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 14) {
        Image(systemName: "keyboard.fill")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 3) {
          Text("K811 Studio")
            .font(.title.bold())
          Text("native macOS controller")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      GroupBox("장치") {
        HStack {
          Circle()
            .fill(controller.device == nil ? Color.orange : Color.green)
            .frame(width: 10, height: 10)
          VStack(alignment: .leading, spacing: 3) {
            Text(controller.status)
            if let device = controller.device {
              Text("\(device.manufacturer) · \(device.product) · FF00:0001 · 64B")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("다시 확인") {
            controller.refreshDevice()
          }
        }
        .padding(8)
      }

      Picker("기능", selection: $selectedSection) {
        ForEach(K811StudioSection.allCases) { section in
          Text(section.displayName).tag(section)
        }
      }
      .pickerStyle(.segmented)

      if selectedSection == .lighting {
        GroupBox("조명") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
              Text("효과")
              Picker("", selection: $controller.selectedEffect) {
                ForEach(K811EffectChoice.allCases) { effect in
                  Text(effect.displayName).tag(effect)
                }
              }
              .labelsHidden()
              .frame(width: 240)
            }

            if !controller.selectedEffect.isAgent {
              GridRow {
                Text("색상")
                ColorPicker("", selection: $controller.selectedColor, supportsOpacity: false)
                  .labelsHidden()
              }

              GridRow {
                Text("밝기")
                HStack {
                  Slider(value: $controller.brightness, in: 1...255, step: 1)
                  Text("\(Int(controller.brightness))")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                }
              }

              GridRow {
                Text("속도")
                HStack {
                  Slider(value: $controller.speed, in: 1...4, step: 1)
                  Text("\(Int(controller.speed))")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                }
              }

              GridRow {
                Text("자동 색상")
                Toggle("효과가 색상을 자동 변경", isOn: $controller.autoColor)
              }
            }
          }
          .padding(8)

          if controller.selectedEffect.isAgent {
            AgentSettingsView(controller: controller)
              .padding([.horizontal, .bottom], 8)
          }

          HStack {
            Spacer()
            Button {
              controller.applyLighting()
            } label: {
              if controller.isApplying {
                ProgressView().controlSize(.small)
              } else {
                Label(
                  controller.selectedEffect.isAgent ? "알림 전체 확인 · 소등" : "조명 적용",
                  systemImage: controller.selectedEffect.isAgent ? "bell.slash" : "sparkles"
                )
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.device == nil || controller.isBusy)
          }
          .padding([.horizontal, .bottom], 8)
        }
      } else {
        K811KeymapEditorView(controller: controller)
      }

      Label(
        selectedSection == .lighting
          ? "조명과 키 설정은 전송이 끝나는 즉시 HID 연결을 해제합니다."
          : "키 설정은 실장치 검증된 0x09 overlay 계약을 사용합니다. 매크로는 아직 비활성화되어 있습니다.",
        systemImage: selectedSection == .lighting ? "lightbulb" : "keyboard"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 760, height: 700)
  }
}

private struct AgentSettingsView: View {
  @ObservedObject var controller: K811Controller

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Divider()

      HStack {
        Image(systemName: "bolt.horizontal.circle.fill")
          .foregroundStyle(.green)
        Text(controller.agentStatus)
          .font(.callout.weight(.medium))
        Spacer()
      }

      HStack(spacing: 14) {
        AgentLegend(color: .green, title: "완료", detail: "2회")
        AgentLegend(color: .blue, title: "질문", detail: "3회")
        AgentLegend(color: .orange, title: "승인", detail: "4회")
        AgentLegend(color: .red, title: "실패", detail: "6회")
      }

      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
        GridRow {
          Text("필수")
            .foregroundStyle(.secondary)
          HStack(spacing: 16) {
            AgentSourceBadge(name: "Orca")
            AgentSourceBadge(name: "Claude Code")
            AgentSourceBadge(name: "Codex")
          }
        }
        GridRow {
          Text("선택")
            .foregroundStyle(.secondary)
          HStack(spacing: 16) {
            Toggle("OpenCode", isOn: $controller.openCodeEnabled)
            Toggle("Pi", isOn: $controller.piEnabled)
            Toggle("Antigravity", isOn: $controller.antigravityEnabled)
          }
          .toggleStyle(.checkbox)
        }
      }

      Text(
        "Claude·Codex·OpenCode hook이 transient helper를 실행해 K811을 직접 connect → write → disconnect합니다. 최초 1회 scripts/install-agent-hooks.py --apply 실행 후 agent를 재시작해야 합니다. 앱·daemon은 필요 없습니다. Orca에서 실행한 Claude/Codex도 같은 hook을 사용하며, Orca automation·Pi·Antigravity는 공통 CLI adapter를 연결할 수 있습니다."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct AgentLegend: View {
  let color: Color
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 10, height: 10)
      Text(title)
        .font(.caption.weight(.semibold))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct AgentSourceBadge: View {
  let name: String

  var body: some View {
    Label(name, systemImage: "lock.fill")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

extension Color {
  fileprivate var rgbBytes: (red: UInt8, green: UInt8, blue: UInt8)? {
    guard let color = NSColor(self).usingColorSpace(.sRGB) else {
      return nil
    }

    return (
      UInt8((color.redComponent * 255).rounded()),
      UInt8((color.greenComponent * 255).rounded()),
      UInt8((color.blueComponent * 255).rounded())
    )
  }
}
