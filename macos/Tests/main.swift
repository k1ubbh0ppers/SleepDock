import Foundation

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}
var settings = Settings()
func input(idle: Double = 0, tasks: Int = 0, battery: Int = 80, plugged: Bool = true, uncertain: Bool = false) -> PolicyInput {
    PolicyInput(settings: settings, battery: battery, pluggedIn: plugged, idleSeconds: idle, taskCount: tasks, uncertainAgents: uncertain)
}
check(!SleepPolicy.evaluate(input(tasks: 1)).keepAwake, "总开关关闭不创建断言")
settings.masterEnabled = true
check(SleepPolicy.evaluate(input(tasks: 1)).keepAwake, "任务运行防止空闲休眠")
check(!SleepPolicy.evaluate(input()).keepAwake, "系统模式任务结束释放保护")
settings.mode = .never
check(SleepPolicy.evaluate(input()).keepAwake, "永不休眠创建临时断言")
check(!SleepPolicy.evaluate(input(battery: 19, plugged: false)).keepAwake, "低电量释放保护")
check(SleepPolicy.evaluate(input(battery: 19)).keepAwake, "接电时低电量不影响保护")
settings.acOnly = true
check(!SleepPolicy.evaluate(input(plugged: false)).keepAwake, "仅接电模式拔电释放保护")
settings.acOnly = false
settings.mode = .idle
settings.minutes = 5
check(SleepPolicy.evaluate(input(idle: 299)).keepAwake, "自定空闲时间前不受系统较短时间影响")
check(SleepPolicy.evaluate(input(idle: 301)).sleepForIdle, "空闲时间到才请求休眠")
check(!SleepPolicy.evaluate(input(idle: 301, tasks: 1)).sleepForIdle, "空闲到期但任务运行时不请求休眠")
check(!SleepPolicy.evaluate(input(idle: 301, uncertain: true)).sleepForIdle, "任务状态不明禁止自动休眠")
settings.keepDisplayAwake = true
check(SleepPolicy.evaluate(input()).keepDisplayAwake, "屏幕常亮单独控制")
settings.masterEnabled = false
check(!SleepPolicy.evaluate(input()).keepDisplayAwake, "关闭总开关释放屏幕断言")
let gate = AutoSleepGate()
let now = Date(timeIntervalSince1970: 1000)
gate.arm(.agents, now: now)
check(!gate.tick(now: now.addingTimeInterval(59), enabled: true, taskCount: 0, uncertain: false, idleSeconds: 100), "完成后保留60秒取消窗口")
check(gate.tick(now: now.addingTimeInterval(60), enabled: true, taskCount: 0, uncertain: false, idleSeconds: 100), "正常完成且无人操作才到期")
gate.arm(.agents, now: now)
check(!gate.tick(now: now.addingTimeInterval(30), enabled: true, taskCount: 0, uncertain: false, idleSeconds: 2), "任务结束后用户操作取消自动睡眠")
check(gate.deadline == nil, "取消后不重复触发")
gate.arm(.agents, now: now)
check(!gate.tick(now: now.addingTimeInterval(61), enabled: true, taskCount: 1, uncertain: false, idleSeconds: 100), "新任务阻止已到期自动睡眠")
gate.arm(.agents, now: now)
check(!gate.tick(now: now.addingTimeInterval(61), enabled: true, taskCount: 0, uncertain: true, idleSeconds: 100), "状态不明阻止自动睡眠")
gate.arm(.timer, now: now)
check(!gate.tick(now: now.addingTimeInterval(61), enabled: false, taskCount: 0, uncertain: false, idleSeconds: 100), "暂停插件取消定时睡眠")
exit(failures == 0 ? 0 : 1)
