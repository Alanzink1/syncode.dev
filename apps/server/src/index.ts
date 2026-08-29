import { WebSocketServer } from 'ws';

interface Participant {
  ws: any;
  userId: string;
  username: string;
  canPairProgram: boolean;
}

interface Room {
  id: string;
  password?: string;
  hostWs: any;
  participants: Map<any, Participant>;
}

const rooms = new Map<string, Room>();
const wss = new WebSocketServer({ port: 8080 });

function generateUserId() {
  return Math.random().toString(36).substring(2, 9);
}

function broadcastToRoom(roomId: string, data: any, excludeWs?: any) {
  const room = rooms.get(roomId);
  if (!room) return;
  const messageStr = JSON.stringify(data);
  room.participants.forEach((p) => {
    if (p.ws !== excludeWs && p.ws.readyState === 1) {
      p.ws.send(messageStr);
    }
  });
}

function sendToWs(ws: any, data: any) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify(data));
  }
}

function getRoomParticipants(room: Room) {
  const list: any[] = [];
  room.participants.forEach((p) => {
    list.push({
      userId: p.userId,
      username: p.username,
      isHost: p.ws === room.hostWs,
      canPairProgram: p.canPairProgram,
    });
  });
  return list;
}

wss.on('connection', function connection(ws: any) {
  ws.userId = generateUserId();
  console.log(`New client connected: ${ws.userId}`);

  ws.on('message', function message(rawData: any) {
    try {
      const parsed = JSON.parse(rawData.toString());
      const roomId = ws.roomId;

      // --- AUTENTICAÇÃO E ENTRADA ---
      if (parsed.type === 'CREATE_ROOM') {
        const { roomId: reqRoomId, password, username } = parsed;
        if (rooms.has(reqRoomId)) {
          return sendToWs(ws, { type: 'ERROR', message: 'Sala já existe.' });
        }
        
        const room: Room = {
          id: reqRoomId,
          password: password,
          hostWs: ws,
          participants: new Map(),
        };
        rooms.set(reqRoomId, room);
        
        ws.roomId = reqRoomId;
        room.participants.set(ws, {
          ws,
          userId: ws.userId,
          username,
          canPairProgram: true, // Host pode programar
        });
        
        console.log(`[CREATE_ROOM] ${username} created ${reqRoomId}`);
        sendToWs(ws, { type: 'ROOM_JOINED', participants: getRoomParticipants(room) });
        return;
      }

      if (parsed.type === 'JOIN_ROOM') {
        const { roomId: reqRoomId, password, username } = parsed;
        const room = rooms.get(reqRoomId);
        
        if (!room) {
          return sendToWs(ws, { type: 'ERROR', message: 'Sala não encontrada.' });
        }
        if (room.password && room.password !== password) {
          return sendToWs(ws, { type: 'ERROR', message: 'Senha incorreta.' });
        }
        
        ws.roomId = reqRoomId;
        const participant = {
          ws,
          userId: ws.userId,
          username,
          canPairProgram: false, // Convidados começam sem permissão
        };
        room.participants.set(ws, participant);
        
        console.log(`[JOIN_ROOM] ${username} joined ${reqRoomId}`);
        sendToWs(ws, { type: 'ROOM_JOINED', participants: getRoomParticipants(room) });
        broadcastToRoom(reqRoomId, { type: 'USER_JOINED', participant: {
          userId: ws.userId, username, isHost: false, canPairProgram: false
        }}, ws);
        return;
      }

      // Rejeita qualquer outra mensagem se não estiver na sala
      if (!roomId) return;
      const room = rooms.get(roomId);
      if (!room) return;
      const me = room.participants.get(ws);
      if (!me) return;

      // --- CHAT ---
      if (parsed.type === 'CHAT_MESSAGE') {
        broadcastToRoom(roomId, {
          type: 'CHAT_MESSAGE',
          sender: me.username,
          message: parsed.message,
          timestamp: Date.now(),
        });
        return;
      }

      // --- PERMISSÕES (SOMENTE HOST) ---
      if (parsed.type === 'SYNC_PERMISSION') {
        if (ws !== room.hostWs) return; // Apenas host
        
        let targetWs: any = null;
        room.participants.forEach((p) => {
          if (p.userId === parsed.targetUserId) targetWs = p.ws;
        });
        
        if (targetWs) {
          const targetP = room.participants.get(targetWs);
          if (targetP) {
            targetP.canPairProgram = parsed.canPairProgram;
            broadcastToRoom(roomId, {
              type: 'PERMISSION_UPDATED',
              userId: parsed.targetUserId,
              canPairProgram: parsed.canPairProgram
            });
            console.log(`[PERMISSION] ${targetP.username} in ${roomId} canPairProgram = ${parsed.canPairProgram}`);
          }
        }
        return;
      }

      // --- SINCRONIZAÇÃO DE CÓDIGO (PAIR PROGRAMMING) ---
      if (['FILE_UPDATE', 'FILE_DELETE', 'DIR_CREATE', 'DIR_DELETE', 'REQUEST_FULL_SYNC'].includes(parsed.type)) {
        if (!me.canPairProgram) {
          sendToWs(ws, { type: 'ERROR', message: 'Você não tem permissão de edição (Pair Programming).' });
          return;
        }
        // Roteia a mensagem pura original para os outros
        room.participants.forEach((p) => {
          if (p.ws !== ws && p.ws.readyState === 1) {
            p.ws.send(rawData.toString());
          }
        });
        return;
      }

      // --- WEBRTC SIGNALING ---
      if (['WEBRTC_OFFER', 'WEBRTC_ANSWER', 'WEBRTC_ICE'].includes(parsed.type)) {
        parsed.senderId = me.userId; // Injeta quem mandou
        
        if (parsed.targetUserId) {
          // Envia para o alvo específico
          room.participants.forEach((p) => {
            if (p.userId === parsed.targetUserId && p.ws.readyState === 1) {
              p.ws.send(JSON.stringify(parsed));
            }
          });
        } else {
          // Broadcast
          room.participants.forEach((p) => {
            if (p.ws !== ws && p.ws.readyState === 1) {
              p.ws.send(JSON.stringify(parsed));
            }
          });
        }
        return;
      }

    } catch (e) {
      console.log(`Erro processando mensagem: ${e}`);
    }
  });

  ws.on('close', () => {
    if (ws.roomId) {
      const room = rooms.get(ws.roomId);
      if (room) {
        room.participants.delete(ws);
        console.log(`[LEAVE_ROOM] Client ${ws.userId} left room: ${ws.roomId}`);
        
        if (room.participants.size === 0) {
          rooms.delete(ws.roomId);
        } else {
          // Se o host sair, podemos fechar a sala ou passar o host (por simplicidade, fechamos)
          if (ws === room.hostWs) {
            broadcastToRoom(ws.roomId, { type: 'ERROR', message: 'O Host encerrou a sala.' });
            rooms.delete(ws.roomId);
          } else {
            broadcastToRoom(ws.roomId, { type: 'USER_LEFT', userId: ws.userId });
          }
        }
      }
    }
  });
});

console.log('🚀 Syncode v0.6 server running on ws://localhost:8080');