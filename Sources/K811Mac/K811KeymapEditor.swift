import K811Core
import SwiftUI

enum K811StudioSection: String, CaseIterable, Identifiable {
  case lighting
  case keymap

  var id: Self { self }

  var displayName: String {
    switch self {
    case .lighting: "조명"
    case .keymap: "키 설정"
    }
  }
}

struct K811OutputChoice: Identifiable, Hashable {
  let usage: UInt8
  let displayName: String

  var id: UInt8 { usage }

  static let all: [K811OutputChoice] = {
    let letters = (0..<26).map {
      K811OutputChoice(
        usage: UInt8(0x04 + $0),
        displayName: String(UnicodeScalar(65 + $0)!)
      )
    }
    let digitLabels = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    let digits = digitLabels.enumerated().map {
      K811OutputChoice(usage: UInt8(0x1E + $0.offset), displayName: $0.element)
    }
    let controls: [K811OutputChoice] = [
      .init(usage: 0x28, displayName: "Enter"),
      .init(usage: 0x29, displayName: "Esc"),
      .init(usage: 0x2A, displayName: "Backspace"),
      .init(usage: 0x2B, displayName: "Tab"),
      .init(usage: 0x2C, displayName: "Space"),
      .init(usage: 0x2D, displayName: "-"),
      .init(usage: 0x2E, displayName: "="),
      .init(usage: 0x2F, displayName: "["),
      .init(usage: 0x30, displayName: "]"),
      .init(usage: 0x31, displayName: "\\"),
      .init(usage: 0x33, displayName: ";"),
      .init(usage: 0x34, displayName: "'"),
      .init(usage: 0x35, displayName: "`"),
      .init(usage: 0x36, displayName: ","),
      .init(usage: 0x37, displayName: "."),
      .init(usage: 0x38, displayName: "/"),
      .init(usage: 0x39, displayName: "Caps Lock"),
    ]
    let functionKeys = (0..<12).map {
      K811OutputChoice(usage: UInt8(0x3A + $0), displayName: "F\($0 + 1)")
    }
    let extendedFunctionKeys = (0..<12).map {
      K811OutputChoice(usage: UInt8(0x68 + $0), displayName: "F\($0 + 13)")
    }
    let navigation: [K811OutputChoice] = [
      .init(usage: 0x46, displayName: "Print Screen"),
      .init(usage: 0x47, displayName: "Scroll Lock"),
      .init(usage: 0x48, displayName: "Pause"),
      .init(usage: 0x49, displayName: "Insert"),
      .init(usage: 0x4A, displayName: "Home"),
      .init(usage: 0x4B, displayName: "Page Up"),
      .init(usage: 0x4C, displayName: "Delete"),
      .init(usage: 0x4D, displayName: "End"),
      .init(usage: 0x4E, displayName: "Page Down"),
      .init(usage: 0x4F, displayName: "Right Arrow"),
      .init(usage: 0x50, displayName: "Left Arrow"),
      .init(usage: 0x51, displayName: "Down Arrow"),
      .init(usage: 0x52, displayName: "Up Arrow"),
      .init(usage: 0x65, displayName: "Application/Menu"),
    ]
    return letters + digits + controls + functionKeys + extendedFunctionKeys + navigation
  }()
}

struct K811ModifierChoice: Identifiable, Hashable {
  let usage: UInt8?
  let displayName: String

  var id: String {
    usage.map { String(format: "%02X", $0) } ?? "none"
  }

  static let all: [K811ModifierChoice] = [
    .init(usage: nil, displayName: "없음"),
    .init(usage: 0xE0, displayName: "왼쪽 Control"),
    .init(usage: 0xE1, displayName: "왼쪽 Shift"),
    .init(usage: 0xE2, displayName: "왼쪽 Option"),
    .init(usage: 0xE3, displayName: "왼쪽 Command"),
    .init(usage: 0xE4, displayName: "오른쪽 Control"),
    .init(usage: 0xE5, displayName: "오른쪽 Shift"),
    .init(usage: 0xE6, displayName: "오른쪽 Option"),
    .init(usage: 0xE7, displayName: "오른쪽 Command"),
  ]
}

struct K811KeymapEditorView: View {
  @ObservedObject var controller: K811Controller
  @State private var showsResetConfirmation = false

  var body: some View {
    GroupBox("키 설정") {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Picker("레이어", selection: $controller.selectedLayer) {
            Text("Standard").tag(K811Layer.standard)
            Text("FN").tag(K811Layer.function)
          }
          .pickerStyle(.segmented)
          .frame(width: 260)
          .disabled(controller.isBusy)

          Spacer()

          Text("로컬 초안 \(controller.keymapProfile.assignments.count)개")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Label(
          "장치 overlay는 읽을 수 없습니다. write 전 readable base를 백업하고 로컬 초안 전체를 명시적으로 적용합니다.",
          systemImage: "externaldrive.badge.questionmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Label(
          "조이스틱·노브·미디어 control은 key-up이 보장되는 macro 경로가 검증되기 전까지 직접 매핑하지 않습니다.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)

        HStack(spacing: 8) {
          Label(
            controller.recoveryBaselineAvailable
              ? "자동복구 baseline 준비됨"
              : "자동복구 baseline 없음 · 먼저 키보드 초기화 필요",
            systemImage: controller.recoveryBaselineAvailable
              ? "checkmark.shield"
              : "exclamationmark.shield"
          )
          .foregroundStyle(controller.recoveryBaselineAvailable ? .green : .orange)
          if let backupURL = controller.lastKeymapBackupURL {
            Text("최근 백업: \(backupURL.lastPathComponent)")
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)

        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
          GridRow {
            Text("물리 키")
            Text("출력")
            Text("Modifier")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.bottom, 6)

          Divider().gridCellColumns(3)

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(K811KeymapProtocol.directKeyboardKeys) { key in
                keyRow(key)
                Divider()
              }
            }
          }
          .frame(height: 350)
          .gridCellColumns(3)
        }

        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(controller.keymapStatus)
              .font(.callout.weight(.medium))
            Text("적용 실패 시 이전 applied profile을 자동복구하고 로컬 초안은 유지합니다.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Button("키보드 초기화", role: .destructive) {
            showsResetConfirmation = true
          }
          .disabled(controller.device == nil || controller.isBusy)

          Button {
            controller.applyKeymap()
          } label: {
            if controller.isWritingKeymap {
              ProgressView().controlSize(.small)
            } else {
              Label("키보드에 적용", systemImage: "keyboard.badge.ellipsis")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            controller.device == nil
              || controller.isBusy
              || controller.keymapProfile.isEmpty
              || !controller.recoveryBaselineAvailable
          )
        }
      }
      .padding(8)
    }
    .confirmationDialog(
      "K811 키 설정을 공장 기본으로 초기화할까요?",
      isPresented: $showsResetConfirmation
    ) {
      Button("키보드 초기화", role: .destructive) {
        controller.resetKeymap()
      }
      Button("취소", role: .cancel) {}
    } message: {
      Text(
        "readable base를 먼저 백업한 뒤 key override를 모두 지웁니다. 성공하면 zero-image를 자동복구 baseline으로 등록하고 로컬 초안도 비웁니다."
      )
    }
  }

  private func keyRow(_ key: K811PhysicalKey) -> some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(key.label)
          .font(.callout.weight(.semibold))
        Text("slot \(key.slot)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .frame(width: 118, alignment: .leading)

      Picker("\(key.label) 출력", selection: outputBinding(for: key)) {
        Text("기본 동작").tag(Optional<UInt8>.none)
        ForEach(K811OutputChoice.all) { choice in
          Text(choice.displayName).tag(Optional(choice.usage))
        }
      }
      .labelsHidden()
      .frame(width: 220)
      .disabled(controller.isBusy)

      Picker("\(key.label) modifier", selection: modifierBinding(for: key)) {
        ForEach(K811ModifierChoice.all) { choice in
          Text(choice.displayName).tag(choice.usage)
        }
      }
      .labelsHidden()
      .frame(width: 180)
      .disabled(controller.isBusy || controller.outputUsage(for: key) == nil)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 7)
  }

  private func outputBinding(for key: K811PhysicalKey) -> Binding<UInt8?> {
    Binding(
      get: { controller.outputUsage(for: key) },
      set: { controller.setOutputUsage($0, for: key) }
    )
  }

  private func modifierBinding(for key: K811PhysicalKey) -> Binding<UInt8?> {
    Binding(
      get: { controller.modifierUsage(for: key) },
      set: { controller.setModifierUsage($0, for: key) }
    )
  }
}
