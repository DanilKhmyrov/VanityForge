import Darwin
import Foundation
import IOKit
import Observation

/// Живые системные метрики (CPU/память/GPU) через низкоуровневые Mach/IOKit
/// API — без внешних зависимостей и без sudo. GPU-число — это утилизация
/// системного GPU в целом (IOAccelerator), не самого поиска: `keyhunt` на
/// этой машине CPU-шный, реальной GPU-нагрузки от него не будет — метрика
/// просто даёт честную картину происходящего на машине.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var cpuUsage: Double = 0
    private(set) var memoryUsage: Double = 0
    private(set) var memoryUsedGB: Double = 0
    private(set) var memoryTotalGB: Double = 0
    private(set) var gpuUsage: Double?
    private(set) var cpuHistory: [Double] = []

    private var pollTask: Task<Void, Never>?
    private var prevTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    func start() {
        guard pollTask == nil else { return }
        sample()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.sample()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleGPU()
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let ticks = info.cpu_ticks
        let user = ticks.0, system = ticks.1, idle = ticks.2, nice = ticks.3

        defer { prevTicks = (user, system, idle, nice) }
        guard let prev = prevTicks else { return }

        let deltaUser = Double(user &- prev.user)
        let deltaSystem = Double(system &- prev.system)
        let deltaIdle = Double(idle &- prev.idle)
        let deltaNice = Double(nice &- prev.nice)
        let total = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard total > 0 else { return }

        cpuUsage = min(1, max(0, (deltaUser + deltaSystem + deltaNice) / total))
        cpuHistory.append(cpuUsage)
        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let used = Double(UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return }

        memoryUsedGB = used / 1_073_741_824
        memoryTotalGB = total / 1_073_741_824
        memoryUsage = min(1, max(0, used / total))
    }

    private func sampleGPU() {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            gpuUsage = nil
            return
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var propsUnmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = propsUnmanaged?.takeRetainedValue() as? [String: Any],
               let perf = props["PerformanceStatistics"] as? [String: Any],
               let utilization = perf["Device Utilization %"] as? Int {
                best = max(best ?? 0, Double(utilization) / 100.0)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        gpuUsage = best
    }
}
