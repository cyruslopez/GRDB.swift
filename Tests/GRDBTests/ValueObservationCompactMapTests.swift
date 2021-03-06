import XCTest
#if GRDBCUSTOMSQLITE
    import GRDBCustomSQLite
#else
    #if SWIFT_PACKAGE
        import CSQLite
    #else
        import SQLite3
    #endif
    import GRDB
#endif

class ValueObservationCompactMapTests: GRDBTestCase {
    func testCompactMap() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [String] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            // The base reducer
            var count = 0
            let reducer = AnyValueReducer(
                fetch: { _ in /* don't fetch anything */ },
                value: { _ -> Int? in
                    count += 1
                    return count
            })
            
            // Create an observation
            let observation = ValueObservation
                .tracking(DatabaseRegion.fullDatabase, reducer: { _ in reducer })
                .compactMap { count -> String? in
                    if count % 2 == 0 { return nil }
                    return "\(count)"
            }
            
            // Start observation
            let observer = try observation.start(in: dbWriter) { count in
                counts.append(count)
                notificationExpectation.fulfill()
            }
            try withExtendedLifetime(observer) {
                try dbWriter.writeWithoutTransaction { db in
                    try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                    try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                }
                
                waitForExpectations(timeout: 1, handler: nil)
                XCTAssertEqual(counts, ["1", "3"])
            }
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testCompactMapPreservesConfiguration() {
        var observation = ValueObservation.tracking(DatabaseRegion(), fetch: { _ in })
        observation.requiresWriteAccess = true
        observation.scheduling = .unsafe(startImmediately: true)
        
        let mappedObservation = observation.compactMap { _ in }
        XCTAssertEqual(mappedObservation.requiresWriteAccess, observation.requiresWriteAccess)
        switch mappedObservation.scheduling {
        case .unsafe:
            break
        default:
            XCTFail()
        }
    }
}
