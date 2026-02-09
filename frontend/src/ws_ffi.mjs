let ws = null;
let reconnect_timer = null;

export function ws_connect(url, on_message) {
  if (ws && ws.readyState <= 1) {
    console.log("[WS] Already connected or connecting, skipping");
    return;
  }

  console.log("[WS] Connecting to", url);
  ws = new WebSocket(url);

  ws.onopen = () => {
    console.log("[WS] Connection opened");
  };

  ws.onmessage = (event) => {
    console.log("[WS] Message received:", event.data);
    on_message(event.data);
  };

  ws.onclose = (event) => {
    console.log(
      "[WS] Connection closed (code:",
      event.code,
      "reason:",
      event.reason || "none",
      ")",
    );
    // Reconnect after 3 seconds
    if (reconnect_timer) clearTimeout(reconnect_timer);
    reconnect_timer = setTimeout(() => {
      console.log("[WS] Attempting reconnect...");
      ws_connect(url, on_message);
    }, 3000);
  };

  ws.onerror = (err) => {
    console.error("[WS] Error:", err);
  };
}

export function ws_close() {
  console.log("[WS] Closing connection");
  if (reconnect_timer) {
    clearTimeout(reconnect_timer);
    reconnect_timer = null;
  }
  if (ws) {
    ws.close();
    ws = null;
  }
}
