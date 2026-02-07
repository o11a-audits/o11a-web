let ws = null;
let reconnect_timer = null;

export function ws_connect(url, on_message) {
  if (ws && ws.readyState <= 1) {
    return; // already connected or connecting
  }

  ws = new WebSocket(url);

  ws.onmessage = (event) => {
    on_message(event.data);
  };

  ws.onclose = () => {
    // Reconnect after 3 seconds
    if (reconnect_timer) clearTimeout(reconnect_timer);
    reconnect_timer = setTimeout(() => {
      ws_connect(url, on_message);
    }, 3000);
  };

  ws.onerror = (err) => {
    console.error("WebSocket error:", err);
  };
}

export function ws_close() {
  if (reconnect_timer) {
    clearTimeout(reconnect_timer);
    reconnect_timer = null;
  }
  if (ws) {
    ws.close();
    ws = null;
  }
}
