// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The reconcile view, the graceful close and the per-controller routes.

import Foundation

extension FakeSatelliteRest {

    /// Real sub-routes 404 once the session is closed (or never opened) —
    /// `getSessionView`/`applyController`/`removeController` all report
    /// not-found for a device with no session row.
    func notFound() -> FakeSatelliteHttp.Response {
        FakeSatelliteHttp.json(404, ["error": "connection not found"])
    }

    func reconcile(_ request: FakeSatelliteHttp.Request, id: String) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            state.reconcileGets.append(id)
            let controllers = state.controllers.map { ctrl -> [String: Any] in
                var view: [String: Any] = [
                    "ctrlIdx": ctrl["ctrlIdx"] as? Int ?? 0,
                    "active": true,
                    "appliedType": ctrl["type"] as? Int ?? 0,
                    "touchpadMode": ctrl["touchpadMode"] as? String ?? "off",
                    "motion": ["sinkSupportedForType": true, "backendOk": true]
                ]
                if let caps = ctrl["caps"] { view["caps"] = caps }
                return view
            }
            return FakeSatelliteHttp.json(200, [
                "connectionId": id,
                "deviceId": state.pairedDeviceId ?? "",
                "epoch": Int(state.ackEpochOverride ?? state.epoch),
                "protocolVersion": state.settledProtocolVersion,
                "maxControllers": 16,
                "controllers": controllers,
                "hostFeatures": ["mouseControl": ["granted": state.lastMouseGranted]]
            ])
        }
    }

    /// Graceful client close: no close-notify (the closer already knows).
    func closeSession(_ request: FakeSatelliteHttp.Request, id: String) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            state.sessions.removeAll()
            state.activeToken = nil
            if !state.controllers.isEmpty {
                state.epoch &+= 1
                state.controllers = []
            }
            return FakeSatelliteHttp.json(200, ["ok": true])
        }
    }

    // MARK: - Controller sub-resource (contract §Controller)

    func putSlot(_ request: FakeSatelliteHttp.Request, id: String, idx: Int) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            var descriptor = body
            descriptor["ctrlIdx"] = idx // the path index wins (contract)
            let existing = state.controllers.firstIndex { ($0["ctrlIdx"] as? Int ?? -1) == idx }
            if let failure = state.controllerApplyFailure {
                // replugFailed leaves the previous pad in force; every other
                // code means the slot is not plugged (contract §Session).
                let priorType = existing.map { state.controllers[$0]["type"] as? Int ?? 0 }
                return FakeSatelliteHttp.json(200, [
                    "epoch": Int(state.epoch),
                    "controller": [
                        "ctrlIdx": idx,
                        "result": failure,
                        "appliedType": priorType ?? (descriptor["type"] as? Int ?? 0),
                        "motion": ["sinkSupportedForType": false, "backendOk": false]
                    ]
                ])
            }
            var list = state.controllers
            if let existing {
                // Epoch moves only on a TYPE change (replug); caps/mode
                // converge in place (`applyDescriptorLocked` same-family arm).
                let typeChanged = (list[existing]["type"] as? Int ?? 0) != (descriptor["type"] as? Int ?? 0)
                if !(list[existing] as NSDictionary).isEqual(to: descriptor) {
                    list[existing] = descriptor
                    if typeChanged { state.epoch &+= 1 }
                }
            } else {
                list.append(descriptor)
                state.epoch &+= 1
            }
            state.controllers = list.sorted { ($0["ctrlIdx"] as? Int ?? 0) < ($1["ctrlIdx"] as? Int ?? 0) }
            return FakeSatelliteHttp.json(200, [
                "epoch": Int(state.epoch),
                "controller": [
                    "ctrlIdx": idx,
                    "result": "ok",
                    "appliedType": descriptor["type"] as? Int ?? 0,
                    "motion": ["sinkSupportedForType": true, "backendOk": true]
                ]
            ])
        }
    }

    /// Removes the SLOT only; the session lives on (contract).
    func deleteSlot(_ request: FakeSatelliteHttp.Request, id: String, idx: Int) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            let before = state.controllers.count
            state.controllers.removeAll { ($0["ctrlIdx"] as? Int ?? -1) == idx }
            if state.controllers.count != before { state.epoch &+= 1 }
            return FakeSatelliteHttp.json(200, ["ok": true, "epoch": Int(state.epoch)])
        }
    }
}
