import Foundation
import FanSMC

/// SMC operations required by the controller. Tests can model mode and target
/// read-back without touching physical fan hardware.
public protocol FanControlHardware: AnyObject {
    func fanCount() -> Int
    func fan(_ id: Int) -> Fan?
    func allFans() -> [Fan]
    func maxTemperature(group: SensorGroup) -> Double?
    func sensorReadings(group: SensorGroup) -> [(key: String, tempC: Double)]
    func forceFanMode(_ id: Int) throws
    func restoreAutomaticMode(_ id: Int) throws
    func setFanTargetRPM(_ id: Int, rpm: Int) throws
}

extension SMCConnection: FanControlHardware {}
