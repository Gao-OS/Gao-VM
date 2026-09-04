enum DriverProtocol {
    static let protocolVersion = "gaovm.v1.2"
    static let capabilities = [
        "hello", "ping",
        "vm.configure", "vm.start", "vm.stop", "vm.status",
        "open_display", "close_display"
    ]
    static let requiredCapabilities = ["hello", "ping"]
}
