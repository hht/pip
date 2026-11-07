/// 回答：一段异步工作在截止时间前做完了没有。
/// 工作和一个 sleep 赛跑（task group），先到的那个决定结果；超时返回 `nil`（「没有结果」），并取消工作。
/// 任务组要等所有子任务结束才返回，所以被取消的工作必须响应取消（`URLSession` 会；路由子进程靠
/// `RouteProbe.output` 在取消时 `terminate`），否则超时也会被它拖住。
/// 时钟从参数注入。
/// @see https://developer.apple.com/documentation/swift/withtaskgroup(of:returning:isolation:body:)
enum Deadline {
    static func run<T: Sendable, C: Clock>(
        by deadline: C.Instant, clock: C, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await clock.sleep(until: deadline, tolerance: nil) // 被取消说明工作先到，返回值不会被用到
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
