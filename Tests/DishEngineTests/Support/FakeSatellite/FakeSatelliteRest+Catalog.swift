// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

// MARK: - Catalog & capabilities (contract §ServerInfo & Catalog)

extension FakeSatelliteRest {

    func catalog(_ request: FakeSatelliteHttp.Request) -> FakeSatelliteHttp.Response {
        store.with { $0.catalogRequests += 1 }
        if request.headers["if-none-match"] == Self.catalogETag {
            return FakeSatelliteHttp.Response(status: 304, headers: [("ETag", Self.catalogETag)], body: Data())
        }
        var response = FakeSatelliteHttp.json(200, raw: Self.catalogJSON)
        response.headers.append(("ETag", Self.catalogETag))
        return response
    }

    static let catalogETag = "\"1.6.0+en\""

    /// The probe; the `controllerAudio` block grants everything or nothing.
    static func capabilitiesJSON(controllerAudio: Bool) -> String {
        let audio = controllerAudio ? "true" : "false"
        return """
        {"protocolVersion":3,"serverVersion":"1.6.0","maxControllers":16,
         "backend":{"id":"fake","supported":true,"available":true,"errorCode":null},
         "motion":{"available":true},
         "host":{"catalog":{"supported":true},
                 "mouseControl":{"supported":true,"available":true},
                 "keyboardControl":{"supported":false},
                 "rumble":{"supported":true,"available":true}},
         "controllerAudio":{"enabled":\(audio),"mic":\(audio),"speaker":\(audio),"hapticAudio":\(audio)}}
        """
    }

    /// The version-2 catalog: four types, `emulates` per type, every feature
    /// slug the contract names.
    static let catalogJSON = """
    {"locale":"en","protocolVersion":3,"serverVersion":"1.6.0","catalogVersion":2,
     "controllerTypes":[
       {"id":0,"slug":"xbox360","name":"Xbox 360 Controller","shortName":"Xbox",
        "description":"Best compatibility.",
        "image":{"href":"/api/catalog/images/xbox360","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":false},"lightbar":{"supported":false},
                    "touchpad":{"supported":false},"triggerEffects":{"supported":false},
                    "playerLeds":{"supported":false},"mic":{"supported":false},
                    "speaker":{"supported":false},"hapticAudio":{"supported":false}},
        "emulates":{"sdlType":"xbox360","usb":["045e:028e"]}},
       {"id":1,"slug":"ds4","name":"DualShock 4","shortName":"PlayStation",
        "description":"Motion, touchpad and light bar.",
        "image":{"href":"/api/catalog/images/ds4","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":true,"requires":"vigembus>=1.17"},"lightbar":{"supported":true},
                    "touchpad":{"supported":true,"modes":["ds4"]},"triggerEffects":{"supported":false},
                    "playerLeds":{"supported":false},"mic":{"supported":false},
                    "speaker":{"supported":false},"hapticAudio":{"supported":false}},
        "emulates":{"sdlType":"ps4","usb":["054c:05c4"]}},
       {"id":2,"slug":"dualsense","name":"DualSense","shortName":"DualSense",
        "description":"Motion, touchpad, light bar and adaptive triggers.",
        "image":{"href":"/api/catalog/images/dualsense","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":true},"lightbar":{"supported":true},
                    "touchpad":{"supported":true,"modes":["ds4"]},"triggerEffects":{"supported":true},
                    "playerLeds":{"supported":true},"mic":{"supported":true},
                    "speaker":{"supported":true},"hapticAudio":{"supported":true}},
        "emulates":{"sdlType":"ps5","usb":["054c:0ce6"]}},
       {"id":3,"slug":"switchpro","name":"Switch Pro","shortName":"Switch Pro",
        "description":"Rumble and motion.",
        "image":{"href":"/api/catalog/images/switchpro","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":false},
                    "motion":{"supported":true},"lightbar":{"supported":false},
                    "touchpad":{"supported":false},"triggerEffects":{"supported":false},
                    "playerLeds":{"supported":true},"mic":{"supported":false},
                    "speaker":{"supported":false},"hapticAudio":{"supported":false}},
        "emulates":{"sdlType":"switchpro","usb":["057e:2009"]}}],
     "hostFeatures":{"mouseControl":{"supported":true,"modes":["off","ds4","mouse"]},
                     "keyboardControl":{"supported":false},
                     "rumble":{"supported":true}}}
    """
}
