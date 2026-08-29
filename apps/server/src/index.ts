import { WebSocketServer, WebSocket } from 'ws';
import * as http from 'http';

const PORT = 8080;

// Create a basic HTTP server to attach the WebSocket server
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Syncode WebSocket Server Running\n');
});

const wss = new WebSocketServer({ server });

wss.on('connection', (ws: WebSocket) => {
  console.log('New client connected');

  ws.on('message', (message: Buffer) => {
    const data = message.toString();
    try {
      const parsed = JSON.parse(data);
      if (parsed.type === 'FILE_UPDATE') {
        console.log(`[FILE_UPDATE] path: ${parsed.path}, hash: ${parsed.hash}`);
      } else if (parsed.type === 'FILE_DELETE') {
        console.log(`[FILE_DELETE] path: ${parsed.path}`);
      }
    } catch (e) {
      console.log(`Received message, size: ${data.length} bytes`);
    }
    // Broadcast the message to all OTHER connected clients
    wss.clients.forEach((client) => {
      if (client !== ws && client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    });
  });

  ws.on('close', () => {
    console.log('Client disconnected');
  });

  ws.on('error', (error) => {
    console.error('WebSocket error:', error);
  });
});

server.listen(PORT, () => {
  console.log(`🚀 Syncode v0.2 server running on ws://localhost:${PORT}`);
});