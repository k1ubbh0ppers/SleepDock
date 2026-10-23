import Foundation
import CoreGraphics

@main struct WindowSizingChecks {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL \(label)") }
            count += 1
            print("PASS \(label)")
        }
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let short = CGRect(x: -1280, y: 0, width: 1280, height: 700)
        check(WidgetWindowSizing.height(600, visibleHeight: 875) == 600, "保留用户高度")
        check(WidgetWindowSizing.height(10, visibleHeight: 875) == 240, "最小高度240")
        check(WidgetWindowSizing.height(2000, visibleHeight: 875) == 859, "最大高度适配屏幕")
        check(WidgetWindowSizing.height(.nan, visibleHeight: 875) == 728, "无效高度回退")
        check(WidgetWindowSizing.height(100, visibleHeight: 220) == 204, "小屏幕可低于标准最小值")
        let resized = WidgetWindowSizing.frame(height: 530, top: 870, x: 1040, visible: visible)
        check(resized.width == 390, "固定宽度390")
        check(resized.height == 530, "垂直调整真实高度")
        check(resized.maxY == 870, "拖动底边保持顶边")
        let out = WidgetWindowSizing.frame(height: 900, top: 1600, x: 2000, visible: visible)
        check(out.maxX <= visible.maxX && out.minY >= visible.minY && out.maxY <= visible.maxY, "越界窗口回到可见区域")
        let other = WidgetWindowSizing.frame(height: 500, top: 650, x: -3000, visible: short)
        check(other.minX == -1280 && other.width == 390, "支持副屏负坐标")
        print("PASS: \(count) WindowSizing checks")
    }
}
