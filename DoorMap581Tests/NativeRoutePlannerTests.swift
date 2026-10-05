import XCTest
@testable import DoorMap581

final class NativeRoutePlannerTests: XCTestCase {
    let a = DoorCoordinate(lat: 24.1350, lng: 120.6880)
    let b = DoorCoordinate(lat: 24.1360, lng: 120.6890)
    let c = DoorCoordinate(lat: 24.1370, lng: 120.6900)

    func testRequestKeepsMotorScooterWorkerContractAndBoundsAreas() throws {
        let via = [b]
        let area = DoorAvoidArea(id: "mid", lat: 24.1350, lng: 120.6900, radius: 60)
        let (request, selected) = try NativeRoutePlanner.request(origin: a, destination: c, via: via, areas: [area], alternatives: 2, minute: 600)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/route")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(value["variant"] as? String, "main")
        XCTAssertEqual(value["alternatives"] as? Int, 2)
        XCTAssertEqual((value["via"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((value["areas"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(selected.map(\.id), ["mid"])
    }

    func testDecodesValidatedAlternativesAndManeuverIndexes() throws {
        let json = """
        {"routes":[
          {"geometry":{"type":"LineString","coordinates":[[120.688,24.135],[120.689,24.136],[120.690,24.137]]},
           "distance":500,"duration":120,"engine":"valhalla","profile":"motor_scooter",
           "maneuvers":[{"type":"depart","modifier":"","name":"","distance":10,"location":[120.688,24.135]},
                        {"type":"turn","modifier":"right","name":"測試路","distance":80,"location":[120.689,24.136]}],
           "avoidApplied":[],"endpointExempt":[],"label":"推薦"},
          {"geometry":{"type":"LineString","coordinates":[[120.688,24.135],[120.6885,24.1362],[120.690,24.137]]},
           "distance":540,"duration":130,"engine":"valhalla","profile":"motor_scooter",
           "maneuvers":[],"avoidApplied":[],"endpointExempt":[],"label":"備選 2"}
        ]}
        """
        let routes = try NativeRoutePlanner.decode(Data(json.utf8), via: [], areas: [])
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].label, "推薦")
        XCTAssertEqual(routes[0].maneuvers[1].routeIndex, 0) // exact vertex belongs to the preceding segment by stable first-match rule
        XCTAssertEqual(NativeRoutePlanner.ridingManeuvers(routes[0])[1].modifier, "right")
    }

    func testRejectsDrivingOrConstraintBreakingResponse() {
        let json = """
        {"geometry":{"type":"LineString","coordinates":[[120.688,24.135],[120.690,24.137]]},
         "distance":500,"duration":120,"engine":"valhalla","profile":"auto","maneuvers":[]}
        """
        XCTAssertThrowsError(try NativeRoutePlanner.decode(Data(json.utf8), via: [], areas: []))
        XCTAssertThrowsError(try NativeRoutePlanner.request(origin: a, destination: c, via: Array(repeating:b,count:65), areas: []))
    }
}
