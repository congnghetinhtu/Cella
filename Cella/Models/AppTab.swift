//
//  AppTab.swift
//  Cella
//
//  Defines the top-level navigation tabs.
//

import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case cluster = "Cluster"
    case cella = "Cella"
    case enhancedLRC = "Clarc"
    case config = "Config"

    var id: String { rawValue }
}
