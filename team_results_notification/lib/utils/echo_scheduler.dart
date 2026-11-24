/// Echo poll interval: faster when WebSocket is down (fallback path).
Duration echoPollInterval({required bool webSocketLive}) {
  return webSocketLive
      ? const Duration(seconds: 5)
      : const Duration(seconds: 2);
}
