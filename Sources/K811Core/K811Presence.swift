import AppKit
import Darwin
import Foundation

/// 사람이 이미 화면을 보고 있는지 판단한다.
///
/// 훅은 자기를 띄운 에이전트의 자식이고, 그 에이전트는 터미널 앱의 자손이다.
/// 따라서 최전면 앱의 PID 가 이 프로세스의 조상 중에 있으면 사용자가 그 세션을
/// 보고 있다는 뜻이다. 그 경우 키보드 불빛은 정보가 아니라 소음이다.
///
/// 판단이 불확실할 때는 항상 `false`(= 알림을 켠다)로 떨어진다. 놓친 알림보다
/// 불필요한 알림이 덜 해롭기 때문이다. 터미널이 셸을 별도 서버 프로세스에서
/// 띄우거나(iTerm2) 세션이 tmux 로 분리돼 있으면 조상 사슬이 끊겨 이 경우에 해당한다.
public enum K811Presence {
    /// 지정한 프로세스의 부모 PID. 조회에 실패하면 `nil`.
    public static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// 자기 자신부터 launchd 직전까지의 조상 PID 집합.
    ///
    /// 순환이 생기더라도 이미 본 PID 를 만나면 멈춘다.
    public static func ancestorProcessIDs(of pid: pid_t = getpid()) -> Set<pid_t> {
        var result: Set<pid_t> = []
        var current = pid
        while current > 1, !result.contains(current) {
            result.insert(current)
            guard let parent = parentProcessID(of: current) else { break }
            current = parent
        }
        return result
    }

    /// 이 훅을 띄운 터미널이 최전면인가.
    public static func hookHostIsFrontmost() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return ancestorProcessIDs().contains(frontmost.processIdentifier)
    }
}
