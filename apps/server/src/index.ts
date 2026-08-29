import { WebSocketServer, WebSocket } from 'ws';
import * as http from 'http';
import { WebSocketServer } from 'ws';

const rooms = new Map<string, Set<any>>();
const wss = new WebSocketServer({ port: 8080 });

wss.on('connection', function connection(ws: any) {
  console.log('New client connected');

  ws.on('message', function message(data: any) {
    try {
      const parsed = JSON.parse(data.toString());
      
      if (parsed.type === 'JOIN_ROOM') {
        const roomId = parsed.roomId;
        ws.roomId = roomId;
        
        if (!rooms.has(roomId)) {
          rooms.set(roomId, new Set());
        }
        rooms.get(roomId)!.add(ws);
        console.log(`[JOIN_ROOM] Client joined room: ${roomId}`);
        return;
      }

      const roomId = ws.roomId;
      if (!roomId) return; // Ignora pacotes de sockets sem sala

      if (parsed.type === 'FILE_UPDATE') {
        console.log(`[FILE_UPDATE] room: ${roomId}, path: ${parsed.path}, hash: ${parsed.hash}`);
      } else if (parsed.type === 'FILE_DELETE') {
        console.log(`[FILE_DELETE] room: ${roomId}, path: ${parsed.path}`);
      } else if (parsed.type === 'DIR_CREATE') {
        console.log(`[DIR_CREATE] room: ${roomId}, path: ${parsed.path}`);
      } else if (parsed.type === 'DIR_DELETE') {
        console.log(`[DIR_DELETE] room: ${roomId}, path: ${parsed.path}`);
      } else if (parsed.type === 'REQUEST_FULL_SYNC') {
        console.log(`[REQUEST_FULL_SYNC] room: ${roomId}`);
      }

      // Broadcast apenas para os clientes na mesma sala (exceto o próprio remetente)
      const roomClients = rooms.get(roomId);
      if (roomClients) {
        roomClients.forEach(function each(client: any) {
          if (client !== ws && client.readyState === 1) {
            client.send(data);
          }
        });
      }
    } catch (e) {
      console.log(`Received message, size: ${data.length} bytes`);
    }
  });

  ws.on('close', () => {
    if (ws.roomId) {
      const roomClients = rooms.get(ws.roomId);
      if (roomClients) {
        roomClients.delete(ws);
        console.log(`[LEAVE_ROOM] Client left room: ${ws.roomId}`);
        if (roomClients.size === 0) {
          rooms.delete(ws.roomId); // Limpa sala vazia da memória
        }
      }
    }
    console.log('Client disconnected');
  });

  ws.on('error', (error) => {
    console.error('WebSocket error:', error);
  });
});

console.log('🚀 Syncode v0.2 server running on ws://localhost:8080');