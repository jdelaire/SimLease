public enum StatusTheme {
    public static func colorName(for kind: MenuDisplayState.Kind) -> String {
        switch kind {
        case .free: "green"
        case .leased: "orange"
        case .metadataError: "red"
        }
    }
}
