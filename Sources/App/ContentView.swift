//
//  ContentView.swift
//  EquilController
//
//  对应 AAPS 4.0 的 EquilComposeContent：三个屏幕的容器。
//    overview → 概览（默认）
//    history  → 历史
//    wizard*  → 配对 / 换敷贴 / 解绑向导
//    scanner  → BLE 扫描
//
//  AAPS 用 Compose 内部状态 + 工具栏切换。这里用 NavigationStack +
//  Model 上的 route，系统返回手势直接可用。
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model = EquilControllerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            OverviewView(model: model)
                .navigationTitle("Equil 泵")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: routeBinding) {
                    destination
                }
        }
        // 打开 App 就自己连泵：不用点「运行」。
        // 启动走一次，从后台回来再走一次（模型内部 30 秒节流，重复调用无害）。
        .onAppear { model.autoConnectOnLaunch() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.autoConnectOnLaunch() }
        }
        // 大剂量输入页已撤掉入口：1.32 起大剂量在设置页第一栏内联输入，
        // 确认页仍由 ContentView / 设置页各自的 binding 负责。
        // 扫描（设置页与向导共用同一个 sheet，避免嵌套导航失灵）
        .sheet(isPresented: $model.showScanner, onDismiss: {
            if model.scanning { model.stopScan() }
        }) {
            NavigationStack {
                ScannerView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { model.showScanner = false }
                        }
                    }
            }
        }
        // 设置
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        // 实时日志：1.32 起撤掉入口（设置页底部那行版本号长按进日志已去掉），
        // LogView 仍保留在 AuxViews，需要时再挂一个入口即可。
        // 输注确认页：只有闸门判定为 confirm 时才出现
        .sheet(isPresented: bolusConfirmBinding) {
            if let units = model.pendingBolus {
                BolusConfirmView(
                    units: units,
                    reason: model.pendingReason,
                    extendedMinutes: model.pendingExtendedMinutes,
                    reservoirUnits: model.reservoirUnits,
                    maxSingleDose: min(model.safety.maxSingleDose, model.pumpConfig.maxBolus),
                    maxPerHour: model.safety.maxPerHour,
                    usedLastHour: model.safety.usedLastHour(),
                    onConfirm: { model.confirmBolus() },
                    onCancel: { model.cancelBolus() }
                )
            }
        }
        // 闸门直接拒绝时弹这个，不给"仍然继续"的选项
        .alert("无法输注", isPresented: blockBinding) {
            Button("知道了", role: .cancel) { model.blockReason = nil }
        } message: {
            Text(model.blockReason ?? "")
        }
    }

    // MARK: - 路由

    private var routeBinding: Binding<Bool> {
        Binding(
            get: { model.route != .overview },
            set: { presented in if !presented { model.route = .overview } }
        )
    }

    @ViewBuilder
    private var destination: some View {
        switch model.route {
        case .history:
            HistoryView(model: model)
        case .wizardPair, .wizardChange, .wizardUnpair:
            WizardView(model: model, flow: model.route)
        case .overview:
            EmptyView()
        }
    }

    private var bolusConfirmBinding: Binding<Bool> {
        Binding(
            // 设置页开着的时候由设置页自己呈现确认页（它本身是 sheet，
            // 同一个父视图不能同时 present 两个 sheet，否则确认页出不来）。
            get: { model.pendingBolus != nil && !model.showSettings },
            set: { presented in if !presented { model.cancelBolus() } }
        )
    }

    private var blockBinding: Binding<Bool> {
        Binding(
            get: { model.blockReason != nil },
            set: { presented in if !presented { model.blockReason = nil } }
        )
    }
}
