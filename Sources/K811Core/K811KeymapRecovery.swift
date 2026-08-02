import Foundation

public enum K811KeymapApplyError: LocalizedError, Equatable, Sendable {
  case baseSnapshotBackupFailed(String)
  case targetWriteFailedRecovered(String, backupURL: URL)
  case targetWriteAndRecoveryFailed(target: String, recovery: String, backupURL: URL)
  case appliedProfileSaveFailedRecovered(String, backupURL: URL)
  case appliedProfileSaveAndRecoveryFailed(
    persistence: String,
    recovery: String,
    backupURL: URL
  )

  public var errorDescription: String? {
    switch self {
    case .baseSnapshotBackupFailed(let message):
      "장치 write 전 base snapshot 백업에 실패해 전송을 중단했습니다: \(message)"
    case .targetWriteFailedRecovered(let message, let backupURL):
      "키 설정 적용은 실패했지만 이전 프로필 자동복구에 성공했습니다: \(message) · 백업: \(backupURL.path)"
    case .targetWriteAndRecoveryFailed(let target, let recovery, let backupURL):
      "키 설정 적용과 자동복구가 모두 실패했습니다. 장치를 다시 연결한 뒤 키보드 초기화를 실행하세요. 적용: \(target) · 복구: \(recovery) · 백업: \(backupURL.path)"
    case .appliedProfileSaveFailedRecovered(let message, let backupURL):
      "장치 적용 후 baseline 저장에 실패해 이전 프로필로 자동복구했습니다: \(message) · 백업: \(backupURL.path)"
    case .appliedProfileSaveAndRecoveryFailed(let persistence, let recovery, let backupURL):
      "baseline 저장과 이전 프로필 자동복구가 모두 실패했습니다. 장치를 다시 연결한 뒤 키보드 초기화를 실행하세요. 저장: \(persistence) · 복구: \(recovery) · 백업: \(backupURL.path)"
    }
  }
}

public enum K811KeymapRecoveryCoordinator {
  @discardableResult
  public static func apply(
    target: K811KeymapProfile,
    recovery: K811KeymapProfile,
    backupBaseSnapshot: () throws -> URL,
    write: (K811KeymapWriteImage) throws -> Void,
    persistApplied: (K811KeymapProfile) throws -> Void,
    invalidateApplied: () -> Void
  ) throws -> URL {
    let targetImage = try target.makeWriteImage()
    let recoveryImage = try recovery.makeWriteImage()

    let backupURL: URL
    do {
      backupURL = try backupBaseSnapshot()
    } catch {
      throw K811KeymapApplyError.baseSnapshotBackupFailed(error.localizedDescription)
    }

    do {
      try write(targetImage)
    } catch {
      let targetMessage = error.localizedDescription
      do {
        try write(recoveryImage)
      } catch {
        invalidateApplied()
        throw K811KeymapApplyError.targetWriteAndRecoveryFailed(
          target: targetMessage,
          recovery: error.localizedDescription,
          backupURL: backupURL
        )
      }
      throw K811KeymapApplyError.targetWriteFailedRecovered(
        targetMessage,
        backupURL: backupURL
      )
    }

    do {
      try persistApplied(target)
    } catch {
      let persistenceMessage = error.localizedDescription
      do {
        try write(recoveryImage)
      } catch {
        invalidateApplied()
        throw K811KeymapApplyError.appliedProfileSaveAndRecoveryFailed(
          persistence: persistenceMessage,
          recovery: error.localizedDescription,
          backupURL: backupURL
        )
      }
      throw K811KeymapApplyError.appliedProfileSaveFailedRecovered(
        persistenceMessage,
        backupURL: backupURL
      )
    }

    return backupURL
  }
}
