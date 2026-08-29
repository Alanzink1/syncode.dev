<p align="center">
  <img src="assets/logo/syncode.dev_logo.png" width="500" alt="Syncode.dev Logo">
</p>

### Code together. In your editor.

**Real-time collaborative development without leaving your editor.**

`syncode.dev` connects local projects across developers and keeps them synchronized in real time — whether you're using **VS Code, Cursor, JetBrains, Vim, Neovim, Zed, or anything else that works with local files.**

`Flutter Web` · `Dart` · `Node.js` · `Firebase` · `WebSocket` · `WebRTC` · `File System Access API` · `FileSystemObserver` · `CRDT / OT`

---

## The idea

Most collaborative coding tools require developers to work inside a specific editor, install an extension, or move their development environment into the browser.

**Syncode takes a different approach.**

Every developer keeps a real local copy of the project and continues working with their preferred editor.

Syncode runs entirely on the web and, with explicit permission from the user, connects directly to an authorized local project directory through browser filesystem APIs.

```text
Alan / VS Code                         Gabriel / Cursor
      │                                       │
      ▼                                       ▼
 Local Project                           Local Project
      │                                       │
      ▼                                       ▼
File System API                         File System API
      │                                       │
      └──────────── syncode.dev ──────────────┘
                    Realtime Room
```

Gabriel saves:

```text
src/auth/login.ts
```

The browser detects the filesystem change.

Syncode synchronizes it.

Alan's local filesystem is updated.

VS Code detects the change normally.

**No browser editor.**

**No extension.**

**No local agent.**

**No editor lock-in.**

**Your actual local project becomes collaborative.**

---

## 100% Web

Syncode is designed as a **web-first collaborative development platform**.

The core experience does not require installing a desktop application, background daemon, IDE extension or local Node.js agent.

The browser itself provides the bridge between Syncode and the local filesystem.

```text
Browser / PWA
      │
      ├── File System Access API
      │       └── Read and write authorized project files
      │
      ├── FileSystemObserver
      │       └── Detect external filesystem changes
      │
      ├── IndexedDB
      │       └── Persist project directory handles
      │
      ├── WebSocket
      │       └── Realtime synchronization
      │
      └── WebRTC
              └── Peer-to-peer features / screen sharing
```

The initial target is **Chromium-based browsers**, primarily:

- Google Chrome
- Microsoft Edge
- installed Chromium PWAs

Browser support will expand when equivalent filesystem capabilities become available across other engines.

---

## How it works

```text
1. Open syncode.dev
        ↓
2. Create a room
        ↓
3. Receive a room code
        ↓
4. Invite another developer
        ↓
5. Each developer selects a local project directory
        ↓
6. Browser receives filesystem permission
        ↓
7. Projects reconcile their initial state
        ↓
8. Realtime synchronization starts
```

After authorization, the directory handle can be stored locally using IndexedDB.

When persistent filesystem permission is available, Syncode can reconnect to the previously authorized project without requiring the developer to manually select the directory every time.

---

## Architecture

```text
                   ┌─────────────────────┐
                   │     Flutter Web     │
                   │     syncode.dev     │
                   └──────────┬──────────┘
                              │
                     Rooms / Presence
                              │
                   ┌──────────▼──────────┐
                   │ Collaboration Server│
                   │       Node.js       │
                   └─────┬─────────┬─────┘
                         │         │
                    WebSocket    WebRTC
                         │         │
          ┌──────────────┘         └──────────────┐
          │                                       │
          ▼                                       ▼
 ┌───────────────────┐                    ┌──────────────┐
 │    Flutter Web    │                    │ Screen Share │
 └─────────┬─────────┘                    └──────────────┘
           │
 ┌─────────▼─────────┐
 │ FileSystemObserver│
 └─────────┬─────────┘
           │
 ┌─────────▼─────────┐
 │ Diff / Patch      │
 │ Sync Engine       │
 └─────────┬─────────┘
           │
 ┌─────────▼─────────┐
 │ File System Access│
 │       API         │
 └─────────┬─────────┘
           │
 ┌─────────▼─────────┐
 │   Local Project   │
 └───────────────────┘
```

The browser owns the local synchronization lifecycle:

```text
observe → detect → compare → patch → transmit → apply → verify
```

The collaboration server coordinates rooms, participants and synchronization state.

---

## Local filesystem access

Syncode does **not** receive unrestricted access to the developer's computer.

The user explicitly selects which project directory Syncode may access.

```text
User selects:

C:\Projects\syncode-demo

        ↓

Browser permission

        ↓

FileSystemDirectoryHandle

        ↓

Syncode
```

All filesystem operations remain scoped to the authorized directory.

The directory handle can be persisted locally through IndexedDB so Syncode can attempt to reconnect to the project on future sessions.

```text
First session

Select directory
      ↓
Grant permission
      ↓
Store DirectoryHandle
      ↓
Start synchronization


Future session

Load DirectoryHandle
      ↓
Check permission
      ↓
granted
      ↓
Reconnect automatically
```

Permission persistence ultimately remains controlled by the browser and the user.

---

## Detecting editor changes

Syncode does not need to integrate directly with VS Code, Cursor, JetBrains or any other editor.

Editors already write changes to the filesystem.

Syncode observes the filesystem.

```text
VS Code

    ↓ save

src/app.dart

    ↓

Operating System Filesystem

    ↓

FileSystemObserver

    ↓

Syncode detects change

    ↓

Diff / Patch

    ↓

WebSocket

    ↓

Other participants
```

From the editor's perspective, Syncode is invisible.

A remote change simply appears as a normal filesystem modification.

---

## Live File Sync

A local save becomes a remote filesystem update.

```text
Developer saves file
        ↓
FileSystemObserver
        ↓
Change Detection
        ↓
Diff / Patch
        ↓
WebSocket
        ↓
Remote Syncode Client
        ↓
Apply through File System Access API
        ↓
Remote Local Filesystem
        ↓
Editor detects change
```

The editor does not need to understand Syncode.

As far as VS Code, Cursor, Vim or JetBrains are concerned:

**a file simply changed on disk.**

---

## Initial synchronization

When someone joins an existing room, Syncode must reconcile the room state with the selected local directory.

```text
Host Project
     │
     ├── src/
     ├── assets/
     └── package.json

          ↓

    Project Manifest
          ↓
    hashes / metadata
          ↓

Guest Project
```

Syncode compares the project manifests before transferring data.

Only files that need to be created or updated should be transmitted.

Large ignored directories such as dependencies and build outputs should never be transferred.

---

## Concurrent editing

Simple file synchronization works until two developers modify the same content at the same time.

Syncode must therefore distinguish between:

```text
Different files
    → synchronize independently

Same file, different regions
    → attempt automatic merge

Same file, conflicting regions
    → detect conflict

Concurrent live editing
    → OT / CRDT
```

Early versions will prioritize **safe conflict detection** over silently overwriting another developer's work.

The long-term goal is deterministic convergence through **Operational Transformation (OT)** or **Conflict-free Replicated Data Types (CRDTs)**.

---

## Preventing sync loops

Remote changes written through the File System Access API may also be observed as filesystem changes.

Without protection:

```text
Alan saves
   ↓
Gabriel receives
   ↓
Gabriel writes file
   ↓
Observer detects write
   ↓
Alan receives
   ↓
∞
```

Syncode identifies operations using metadata such as:

```text
operation_id
origin_client
file_path
base_hash
result_hash
timestamp
```

Before broadcasting an observed filesystem event, Syncode determines whether it represents:

```text
local developer change

or

already-applied remote operation
```

This prevents synchronization loops.

---

## `.syncodeignore`

Not everything inside a project should be synchronized.

```gitignore
.git/
node_modules/
build/
dist/
.dart_tool/
.idea/
*.log
.env
.env.*
```

`.syncodeignore` defines files and directories that never enter the collaborative session.

Generated files, dependencies, secrets and local IDE configuration should remain local whenever possible.

---

## Rooms

A Syncode room represents a temporary collaborative development session.

```text
SYNCODE ROOM · 7KQ-92A

Participants

● Alan       VS Code
● Gabriel    Cursor
● Pedro      Viewing

────────────────────────────────────

Project Sync       ● LIVE
Screen Share       ● LIVE
Latency             31ms
```

A room can provide:

- project synchronization;
- screen sharing via WebRTC;
- participant presence;
- chat;
- individual permissions;
- change history;
- recoverable snapshots;
- connection and synchronization status.

Creating a room does not require a user account.

The host creates a temporary session and receives a room code that can be shared with other participants.

---

## Session infrastructure

Firebase can be used for lightweight session coordination such as:

```text
room code
participants
presence
room metadata
temporary session state
```

The collaboration server handles realtime synchronization.

```text
Flutter Web
     │
     ├──── Firebase
     │       └── room/session state
     │
     └──── Node.js
             └── realtime collaboration
                    │
                    ├── WebSocket
                    └── WebRTC signaling
```

The architecture does not require permanent user registration for basic collaborative sessions.

---

## Permissions & security

**Selecting a project does not give Syncode unrestricted access to the computer.**

Every session operates inside an explicitly authorized directory.

```text
Authorized scope

C:\Projects\syncode-demo
```

The browser security model prevents Syncode from arbitrarily accessing directories outside the user's authorization.

Sensitive files can additionally be excluded through `.syncodeignore`.

Possible collaboration permissions include:

```text
Gabriel

✓ Read files
✓ Edit files
✓ Create files
✗ Delete files
✗ Execute commands
```

Syncode must validate remote operations before applying them locally.

### Out of scope

Remote terminal access and arbitrary command execution are **not part of the initial scope**.

Syncode synchronizes project files.

It does not give another participant control over your computer.

---

## Recovery

Real-time synchronization should never mean irreversible synchronization.

Before applying potentially destructive operations, Syncode can maintain recoverable session snapshots.

```text
Session
 │
 ├── Snapshot A
 │
 ├── Operation 001
 ├── Operation 002
 ├── Operation 003
 │
 ├── Snapshot B
 │
 └── Operation 004
```

This allows the session to recover from conflicts, accidental edits or synchronization failures.

**Git remains responsible for permanent project history.**

Syncode history exists to make the **live session safe and recoverable.**

---

## Roadmap

### v0.1 — Browser filesystem

- [ ] Flutter Web foundation
- [ ] File System Access API integration
- [ ] Select authorized project directory
- [ ] Read and write project files
- [ ] Persist directory handles with IndexedDB
- [ ] Persistent permission flow
- [ ] FileSystemObserver prototype

### v0.2 — Rooms

- [ ] Create room without account
- [ ] Join room using code
- [ ] Firebase room state
- [ ] Participant presence
- [ ] Node.js collaboration server
- [ ] WebSocket connection

### v0.3 — Basic synchronization

- [ ] Detect external editor changes
- [ ] Synchronize basic file modifications
- [ ] Initial project reconciliation
- [ ] File checksums
- [ ] `.syncodeignore`
- [ ] Operation IDs
- [ ] Sync-loop prevention

### v0.4 — Efficient sync

- [ ] Diff / patch synchronization
- [ ] File creation
- [ ] File deletion
- [ ] Directory creation
- [ ] Rename detection
- [ ] Connection recovery

### v0.5 — Concurrent collaboration

- [ ] Conflict detection
- [ ] Concurrent file changes
- [ ] Merge strategies
- [ ] OT / CRDT research
- [ ] OT / CRDT prototype

### v0.6 — Screen sharing

- [ ] WebRTC screen sharing
- [ ] Multiple viewers
- [ ] Stream controls

### v0.7 — Presence & permissions

- [ ] Participant presence
- [ ] Active file indicators
- [ ] Per-user permissions
- [ ] Read-only participants

### v0.8 — Recovery

- [ ] Session history
- [ ] Snapshots
- [ ] Restore points
- [ ] Change inspection

### v0.9 — PWA

- [ ] Installable Syncode PWA
- [ ] Persistent project access
- [ ] Reconnection experience
- [ ] Offline application shell
- [ ] Chromium optimization

### v1.0 — Stable collaboration

- [ ] Reliable multi-user sessions
- [ ] Safe filesystem synchronization
- [ ] Concurrent editing
- [ ] Session recovery
- [ ] Secure permission model
- [ ] Production-ready collaboration server

---

## Browser support

Syncode depends on modern filesystem capabilities that are not yet implemented equally across every browser.

The initial production target is:

```text
Chrome / Chromium     ✓ Primary target
Microsoft Edge        ✓ Primary target
Chromium PWA          ✓ Primary target

Firefox               △ Limited
Safari                △ Limited
```

Syncode should perform capability detection instead of assuming filesystem APIs are available.

Unsupported browsers should receive a clear compatibility message rather than a partially working synchronization experience.

---

## Engineering principles

```text
Your editor.
Your filesystem.
One shared state.
```

**100% Web**

The core Syncode experience should not require a desktop agent or editor extension.

**Editor agnostic**

Syncode works with the filesystem instead of depending on a specific editor.

**Local first**

Developers keep real local projects and their existing development environment.

**Permission based**

Local filesystem access exists only inside directories explicitly authorized by the developer.

**Git owns history**

Syncode does not replace Git.

Git manages permanent project history.

Syncode manages the live collaborative session.

**Safe by default**

No synchronization operation should escape the explicitly authorized project scope.

**Recoverable**

A synchronization mistake should never destroy someone's work.

**Observable**

Developers should always be able to understand what Syncode is synchronizing.

**Deterministic**

Every participant should eventually converge to the same project state.

---

<div align="center">

### syncode.dev

**Multiplayer for your codebase.**

Your editor. Your workflow. Shared in real time.

**100% Web. No extensions. No local agent.**

🚧 **Currently under development.**

</div>