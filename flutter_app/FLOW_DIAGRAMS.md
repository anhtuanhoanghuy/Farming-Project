## Flow Diagrams

### Share Revoke Flow

```
Owner's Device List
    │
    └─► Share Device → Khách nhận được lời mời
           ↓
Khách's Device List
    │
    └─► Accept Invitation
           ↓
   DeviceAccessWatcher.start() ◄─── initialized in SplashScreen
   DeviceAccessWatcher: listen(device_shares, devices tables)
           ↓
Khách's Dashboard
    │
    └─► Open: Sensor Capacity → Sensor Config
           ↓
Device is now accessible to guest

═══════════════════════════════════════════════════════════════

Owner's Device List
    │
    └─► Revoke Share ◄─── THIS TRIGGERS THE EVENT
           ↓ (remove from device_shares table)
           
Supabase Realtime
    │
    └─► device_shares stream event
           ↓
DeviceAccessWatcher._startShareListener()
    │
    └─► On stream event: _checkAccess()
           ├─ Check listSharedDevices() 
           ├─ Device NOT found
           ├─ currentDevices has device
           └─► revoked.add(macAddress) ◄─── BROADCAST
           
Khách's Sensor Config Screen
    │
    └─► ShareRevokeListener listens to revoked stream
           └─► Receives: (macAddress)
               └─► Matches widget.device.deviceId
                   └─► _onRevoked()
                       ├─ Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
                       └─ Navigator.popUntil((route) => route.isFirst)
                           ├─ Pop Sensor Config
                           ├─ Pop Sensor Capacity  
                           └─ Pop Dashboard
                               └─► Back to Device List
```

### Ownership Transfer Flow

```
Owner's Device List
    │
    └─► Transfer Ownership to Account B
           ↓ (UPDATE devices SET user_id = new_id)
           
Supabase Realtime
    │
    └─► devices stream event (user_id changed)
           ↓
DeviceAccessWatcher._startDeviceListener()
    │
    └─► On stream event: _checkAccess()
           ├─ Check listDevices(currentUserId)
           ├─ Device NOT found (user_id is now Account B's)
           ├─ currentDevices has device
           └─► revoked.add(macAddress) ◄─── BROADCAST
           
Khách's Load Control Screen
    │
    └─► ShareRevokeListener listens to revoked stream
           └─► Receives: (macAddress)
               └─► Matches widget.device.deviceId
                   └─► _onRevoked()
                       ├─ Show SnackBar: "Quyền truy cập thiết bị đã bị thu hồi"
                       └─ Navigator.popUntil((route) => route.isFirst)
                           ├─ Pop Load Control
                           ├─ Pop Sensor Capacity  
                           ├─ Pop Dashboard
                           └─► Back to Device List
```

### Architecture Components

```
┌──────────────────────────────────────────────────────────┐
│                      SplashScreen                         │
│          (Initializes DeviceAccessWatcher)               │
└─────────────────────────┬────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│          DeviceAccessWatcher (Singleton)                 │
│                                                          │
│  Properties:                                             │
│  • _revoked: StreamController<String>  (MAC addresses)   │
│  • _shareSubscription: devices_shares realtime           │
│  • _deviceSubscription: devices realtime                 │
│                                                          │
│  Methods:                                                │
│  • start() - Start listening to both streams             │
│  • _checkAccess() - Compare current vs accessible        │
│  • stop() - Stop listening                              │
│                                                          │
│  Public API:                                             │
│  • revoked: Stream<String> - Broadcast of lost MAC       │
└──────────┬──────────────────────────────────────────────┘
           │
           │ Emits MAC addresses when access is lost
           │
           ├──► DashboardScreen._revokeListener
           │        └─ Listens to: revoked stream
           │        └─ Pops: Dashboard + all children
           │
           ├──► SensorCapacityScreen._revokeListener
           │        └─ Listens to: revoked stream
           │        └─ Pops: SensorCapacity + children
           │
           ├──► SensorConfigScreen._revokeListener
           │        └─ Listens to: revoked stream
           │        └─ Pops: SensorConfig
           │
           ├──► LoadControlScreen._revokeListener
           │        └─ Listens to: revoked stream
           │        └─ Pops: LoadControl
           │
           └──► DiagnosticsScreen._revokeListener
                    └─ Listens to: revoked stream
                    └─ Pops: Diagnostics
```

### ShareRevokeListener Lifecycle

```
Screen Created
    │
    ├─► ShareRevokeListener._init_()
    │      └─ Store context & deviceId
    │
    ├─► Stateful.initState()
    │      └─ _revokeListener.start()
    │          ├─ Call DeviceAccessWatcher.start()
    │          └─ Subscribe to revoked stream
    │
    └─► On Device Revoke/Transfer
        ├─ DeviceAccessWatcher broadcasts revoked event
        └─ ShareRevokeListener.listen() receives event
           ├─ Check if deviceId matches
           └─ Call _onRevoked()
              ├─ Show SnackBar
              ├─ Navigator.of(context).popUntil((route) => route.isFirst)
              └─ Pop current screen back to home
              
Stateful.dispose()
    └─ _revokeListener.dispose()
       └─ Cancel stream subscription
```

### State Transitions

```
Device Access States for Guest User:

INITIAL
   │
   ├─► SHARED (share created) ───► GRANTED (device accessible)
   │
   │
   ├─► REVOKED (share deleted)
   │      └──► Device disappears from guest's device list
   │          └──► ShareRevokeListener notified
   │              └──► Guest auto-logged out of all device screens
   │
   └─► TRANSFERRED (ownership changed to another user)
          └──► Device disappears from guest's devices
              └──► ShareRevokeListener notified
                  └──► Guest auto-logged out of all device screens
```

### Message Flow Diagram

```
Time →

Owner      │  Revoke              │
App        │  Share               │
           │                      │
           ├─► UPDATE device_shares
           │   WHERE id = share_id
           │
Backend    │                      │
(Supabase) │                      │
           │                      ├─► Broadcast realtime event
           │                      │   (device_shares changed)
           │
Realtime   │                      │
Stream     │                      │
           │                      │
Khách      │                      │
App        │                      │
           │                      ├─ Receive: device_shares event
           │                      ├─ Call: _checkAccess()
           │                      ├─ Call: listSharedDevices()
           │                      ├─ Device NOT in list
           │                      ├─ Call: revoked.add(mac)
           │                      │
           │                      └─► ShareRevokeListener
           │                          ├─ Receive: revoked(mac)
           │                          ├─ Verify: mac == device.deviceId
           │                          ├─ Show: SnackBar
           │                          └─ Pop: All screens
           │
           ├─────────────────────────────────────────────────► Time
        [Revoke]              [Detection]           [Auto-Pop]
        (1-5ms)              (50-500ms)             (500ms-2s)
                            (realtime delay)      (UI animation)
```
