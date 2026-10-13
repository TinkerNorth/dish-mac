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

    static let capabilitiesJSON = """
    {"protocolVersion":1,"serverVersion":"1.6.0","maxControllers":16,
     "backend":{"id":"fake","supported":true,"available":true,"errorCode":null},
     "motion":{"available":true},
     "host":{"catalog":{"supported":true},
             "mouseControl":{"supported":true,"available":true},
             "keyboardControl":{"supported":false},
             "rumble":{"supported":true,"available":true}}}
    """

    static let catalogJSON = """
    {"locale":"en","protocolVersion":1,"serverVersion":"1.6.0",
     "controllerTypes":[
       {"id":0,"slug":"xbox360","name":"Xbox 360 Controller","shortName":"Xbox",
        "description":"Best compatibility.",
        "image":{"href":"/api/catalog/images/xbox360","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":false},"lightbar":{"supported":false},
                    "touchpad":{"supported":false}}},
       {"id":1,"slug":"ds4","name":"DualShock 4","shortName":"PlayStation",
        "description":"Motion, touchpad and light bar.",
        "image":{"href":"/api/catalog/images/ds4","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":true},"lightbar":{"supported":true},
                    "touchpad":{"supported":true,"modes":["ds4"]}}},
       {"id":2,"slug":"dualsense","name":"DualSense","shortName":"DualSense",
        "description":"Motion, touchpad and light bar.",
        "image":{"href":"/api/catalog/images/dualsense","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":true},"lightbar":{"supported":true},
                    "touchpad":{"supported":true,"modes":["ds4"]}}},
       {"id":3,"slug":"switchpro","name":"Switch Pro","shortName":"Switch Pro",
        "description":"Rumble and motion.",
        "image":{"href":"/api/catalog/images/switchpro","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":false},
                    "motion":{"supported":true},"lightbar":{"supported":false},
                    "touchpad":{"supported":false}}}],
     "hostFeatures":{"mouseControl":{"supported":true,"modes":["off","ds4","mouse"]},
                     "keyboardControl":{"supported":false},
                     "rumble":{"supported":true}}}
    """
}
