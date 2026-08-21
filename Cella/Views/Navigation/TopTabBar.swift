//
//  TopTabBar.swift
//  Cella
//
//  Pill-style tab bar for switching between Explore, Cella, and Config tabs.
//  Includes a "Liquid Glass" sliding selection pill, drag-to-switch, and
//  scroll-to-switch when hovering.
//

import SwiftUI
import Combine

// MARK: - Scroll Coordinator

final class ScrollCoordinator: ObservableObject {
    @MainActor @Published var switchSignal = 0

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var gestureActive = false

    var isHovering = false

    init() {}

    func start() {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        reset()
    }

    private func reset() {
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        gestureActive = false
    }

    private func handleScroll(_ event: NSEvent) {
        guard isHovering else { return }

        let isTrackpad = event.phase != [] || event.momentumPhase != []

        if isTrackpad {
            // Trackpad: accumulate deltas across the gesture, switch once threshold is crossed
            if event.phase.contains(.began) {
                reset()
                gestureActive = true
            }

            guard gestureActive else { return }

            accumulatedDeltaX += event.scrollingDeltaX
            accumulatedDeltaY += event.scrollingDeltaY

            let threshold: CGFloat = 45.0

            if accumulatedDeltaX < -threshold || accumulatedDeltaY < -threshold {
                emit(.next)
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
            } else if accumulatedDeltaX > threshold || accumulatedDeltaY > threshold {
                emit(.previous)
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                reset()
            }
        } else {
            // Mouse scroll wheel: fire immediately per-event
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let threshold: CGFloat = 8.0

            if deltaX < -threshold || deltaY < -threshold {
                emit(.next)
            } else if deltaX > threshold || deltaY > threshold {
                emit(.previous)
            }
        }
    }

    private func emit(_ direction: Direction) {
        let value = direction == .next ? 1 : -1
        if Thread.isMainThread {
            MainActor.assumeIsolated { switchSignal = value }
        } else {
            Task { @MainActor [weak self] in
                self?.switchSignal = value
            }
        }
    }

    enum Direction { case next, previous }
}

// MARK: - TopTabBar

struct TopTabBar: View {
    @Binding var selectedTab: AppTab
    @StateObject private var coordinator = ScrollCoordinator()
    @Environment(\.theme) private var theme

    @Namespace private var animation
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int = 0

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(8)
        .background(theme.tabBarBackground)
        .clipShape(Capsule())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                coordinator.isHovering = true
            case .ended:
                coordinator.isHovering = false
            }
        }
        .onAppear {
            coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
        .onChange(of: coordinator.switchSignal) { _, signal in
            guard signal != 0 else { return }
            let tabs = AppTab.allCases
            guard let idx = tabs.firstIndex(of: selectedTab) else { return }

            if signal == 1, idx < tabs.count - 1 {
                withAnimation(.snappy) {
                    selectedTab = tabs[idx + 1]
                }
            } else if signal == -1, idx > 0 {
                withAnimation(.snappy) {
                    selectedTab = tabs[idx - 1]
                }
            }

            coordinator.switchSignal = 0
        }
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    let tabs = AppTab.allCases
                    if dragOffset == 0 {
                        dragStartIndex = tabs.firstIndex(of: selectedTab) ?? 0
                    }

                    let rawOffset = value.translation.width
                    dragOffset = rawOffset * 0.4

                    let threshold: CGFloat = 30
                    if rawOffset < -threshold && dragStartIndex < tabs.count - 1 {
                        let nextTab = tabs[dragStartIndex + 1]
                        if selectedTab != nextTab {
                            withAnimation(.snappy) {
                                selectedTab = nextTab
                            }
                        }
                    } else if rawOffset > threshold && dragStartIndex > 0 {
                        let prevTab = tabs[dragStartIndex - 1]
                        if selectedTab != prevTab {
                            withAnimation(.snappy) {
                                selectedTab = prevTab
                            }
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
        )
    }

    // MARK: - Tab Button

    @ViewBuilder
    private func tabButton(for tab: AppTab) -> some View {
        Button {
            withAnimation(.snappy) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selectedTab == tab ? theme.tabSelectedText : theme.tabUnselectedText)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if selectedTab == tab {
                            Capsule()
                                .fill(theme.tabSelectedBackground)
                                .matchedGeometryEffect(id: "pill", in: animation)
                                .offset(x: dragOffset)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
