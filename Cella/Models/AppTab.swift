//
//  AppTab.swift
//  Cella
//
//  Defines the top-level navigation tabs.
//

import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case feeds = "Feeds"
    case cella = "Cella"
    case config = "Config"

    var id: String { rawValue }
}
