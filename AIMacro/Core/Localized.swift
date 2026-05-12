//
//  Localized.swift
//  Macroony
//
//  Short helper around String Catalog lookups so call sites stay compact:
//      L("Ready")            // English source key; KO comes from the catalog
//
//  English is the source language for both the project (development region)
//  and `Localizable.xcstrings`. Korean is the translated locale. Any unknown
//  locale falls back to the source language (English), which is the desired
//  default behaviour.
//

import Foundation

@inline(__always)
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
