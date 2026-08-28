//
//  AppTab.swift
//  Cella
//
//  Defines the top-level navigation tabs.
//

import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case cluster = "Cluster"
    case motions = "Motion"
    case cella = "Cella"
    case enhancedLRC = "LRC Editor"
    case config = "Config"

    var id: String { rawValue }
}
