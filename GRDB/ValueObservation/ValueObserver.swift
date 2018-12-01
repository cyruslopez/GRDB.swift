import Foundation

/// Support for ValueObservation.
/// See DatabaseWriter.add(observation:onError:onChange:)
class ValueObserver<Reducer: ValueReducer>: TransactionObserver {
    /* private */ let region: DatabaseRegion // Internal for testability
    private var reducer: Reducer
    private let fetch: (Database, Reducer) -> Future<Reducer.Fetched>
    private let notificationQueue: DispatchQueue?
    private let onError: ((Error) -> Void)?
    private let onChange: (Reducer.Value) -> Void
    private let reduceQueue: DispatchQueue
    private var isChanged = false
    
    init(
        region: DatabaseRegion,
        reducer: Reducer,
        configuration: Configuration,
        fetch: @escaping (Database, Reducer) -> Future<Reducer.Fetched>,
        notificationQueue: DispatchQueue?,
        onError: ((Error) -> Void)?,
        onChange: @escaping (Reducer.Value) -> Void)
    {
        self.region = region
        self.reducer = reducer
        self.fetch = fetch
        self.notificationQueue = notificationQueue
        self.onChange = onChange
        self.onError = onError
        self.reduceQueue = configuration.makeDispatchQueue(defaultLabel: "GRDB", purpose: "ValueObservation.reducer")
    }
    
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        return region.isModified(byEventsOfKind: eventKind)
    }
    
    func databaseDidChange(with event: DatabaseEvent) {
        if region.isModified(by: event) {
            isChanged = true
            stopObservingDatabaseChangesUntilNextTransaction()
        }
    }
    
    func databaseDidCommit(_ db: Database) {
        guard isChanged else { return }
        isChanged = false
        
        // Grab future fetched values from the database writer queue
        let future = fetch(db, reducer)
        
        // Wait for future fetched values in reduceQueue. This guarantees:
        // - that notifications have the same ordering as transactions.
        // - that expensive reduce operations are computed without blocking
        // any database dispatch queue.
        reduceQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            
            do {
                if let value = try strongSelf.reducer.value(future.wait()) {
                    if let queue = strongSelf.notificationQueue {
                        queue.async {
                            guard let strongSelf = self else { return }
                            strongSelf.onChange(value)
                        }
                    } else {
                        strongSelf.onChange(value)
                    }
                }
            } catch {
                guard strongSelf.onError != nil else {
                    // TODO: how can we let the user know about the error?
                    return
                }
                if let queue = strongSelf.notificationQueue {
                    queue.async {
                        guard let strongSelf = self else { return }
                        strongSelf.onError?(error)
                    }
                } else {
                    strongSelf.onError?(error)
                }
            }
        }
    }
    
    func databaseDidRollback(_ db: Database) {
        isChanged = false
    }
}
