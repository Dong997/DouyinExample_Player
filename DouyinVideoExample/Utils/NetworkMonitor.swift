/// @file NetworkMonitor.swift
/// @brief 网络状态监听器 — 基于 NWPathMonitor 封装，提供网络连通性变化通知
/// @author jscn-app
/// @date 2025-05-14
import Foundation
import Network
import Combine
import os.log

/// 网络连接状态
public enum NetworkStatus: Equatable {
    /// 未知状态（监听尚未启动）
    case unknown
    /// 网络已断开
    case disconnected
    /// 网络已连接（含连接类型）
    case connected(ConnectionType)
}

/// 网络连接类型
public enum ConnectionType: Equatable {
    case wifi
    case cellular
    case wiredEthernet
    case other
}

/// 网络状态监听器
/// 基于 NWPathMonitor 封装，通过 Combine Publisher 广播网络状态变化
///
/// 特性：
/// - 后台队列监听，主线程回调
/// - 提供当前状态快照与变化流
/// - 单例模式，全局共享
///
/// 使用示例：
/// ```swift
/// NetworkMonitor.shared.$status
///     .receive(on: DispatchQueue.main)
///     .sink { status in
///         if case .connected = status {
///             // 网络恢复，重试播放
///         }
///     }
/// ```
@MainActor
public final class NetworkMonitor: ObservableObject {

    /// 全局共享实例
    public static let shared = NetworkMonitor()

    /// 当前网络状态
    @Published private(set) var status: NetworkStatus = .unknown

    /// 网络是否可用
    public var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// 底层路径监听器
    private let monitor = NWPathMonitor()

    /// 监听队列（后台线程，避免阻塞主线程）
    private let monitorQueue = DispatchQueue(label: "com.douyin.video.network-monitor")

    /// 是否正在监听
    private var isMonitoring = false

    private init() {}

    // MARK: - Lifecycle

    /// 启动网络监听
    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitor.pathUpdateHandler = { [weak self] path in
            let status = Self.resolveStatus(from: path)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let oldStatus = self.status
                self.status = status

                if case .disconnected = oldStatus, case .connected = status {
                    AppLog.network.info("Network recovered: \(String(describing: status))")
                } else if case .connected = oldStatus, case .disconnected = status {
                    AppLog.network.warning("Network disconnected")
                }
            }
        }
        monitor.start(queue: monitorQueue)
        AppLog.network.info("Network monitor started")
    }

    /// 停止网络监听
    public func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.cancel()
        AppLog.network.info("Network monitor stopped")
    }

    // MARK: - Private

    /// 从 NWPath 解析网络状态（纯函数，无隔离需求）
    /// - Parameter path: 系统网络路径
    /// - Returns: 解析后的网络状态
    nonisolated private static func resolveStatus(from path: NWPath) -> NetworkStatus {
        if path.status == .satisfied {
            let connectionType: ConnectionType
            if path.usesInterfaceType(.wifi) {
                connectionType = .wifi
            } else if path.usesInterfaceType(.cellular) {
                connectionType = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                connectionType = .wiredEthernet
            } else {
                connectionType = .other
            }
            return .connected(connectionType)
        } else if path.status == .unsatisfied {
            return .disconnected
        } else {
            return .unknown
        }
    }

    deinit {
        monitor.cancel()
    }
}
