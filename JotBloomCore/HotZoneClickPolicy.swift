public enum HotZoneClickPolicy {
    public static func shouldActivate(
        buttonNumber: Int,
        clickCount: Int
    ) -> Bool {
        buttonNumber == 0 && clickCount >= 1
    }
}
