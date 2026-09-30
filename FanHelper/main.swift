// notchpilot-fand: root helper run by launchd whenever /Users/Shared/NotchPilot/fan-mode changes.
// The file holds "max" or "auto"; the helper applies it through the SMC and exits.
import Foundation

let dir = "/Users/Shared/NotchPilot"
let modeFile = "\(dir)/fan-mode"
let statusFile = "\(dir)/fan-status"

let mode = ((try? String(contentsOfFile: modeFile, encoding: .utf8)) ?? "auto")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let smc = SMC.shared
let count = Int(smc.getValue("FNum") ?? 0)

if mode == "max" {
    for id in 0..<count {
        smc.setFanMode(id, mode: .forced)
        if let maxSpeed = smc.getValue("F\(id)Mx") {
            smc.setFanSpeed(id, speed: Int(maxSpeed))
        }
    }
} else {
    for id in 0..<count {
        smc.setFanMode(id, mode: .automatic)
    }
    _ = smc.resetFanControl()
}

// Report what the fans actually do, for NotchPilot and for debugging.
sleep(1)
let speeds = (0..<count).map { Int(smc.getValue("F\($0)Tg") ?? 0) }
let status = "\(mode) \(speeds.map(String.init).joined(separator: ","))\n"
try? status.write(toFile: statusFile, atomically: true, encoding: .utf8)
