import Foundation

// MARK: - LogCategories

/// All swift-log category labels used across EchoSight.
///
/// Every spec binds to one or more of these constants. Using constants prevents
/// category-name typos that would silently route events to phantom buckets.
public enum LogCategories {
    public static let app        = "echosight.app"
    public static let spatial    = "echosight.spatial"
    public static let anchor     = "echosight.anchor"
    public static let speech     = "echosight.speech"
    public static let capture    = "echosight.capture"
    public static let detector   = "echosight.detector"
    public static let fusion     = "echosight.fusion"
    public static let scene      = "echosight.scene"
    public static let recall     = "echosight.recall"
    public static let ambient    = "echosight.ambient"
    public static let read       = "echosight.read"
    public static let gemma      = "echosight.gemma"
    public static let store      = "echosight.store"
    public static let modal      = "echosight.modal"
    public static let download   = "echosight.download"
}
