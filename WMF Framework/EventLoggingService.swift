import Foundation

enum EventLoggingError {
    case generic
}

@objc(WMFEventLoggingService)
public class EventLoggingService : NSObject, URLSessionDelegate {
    private struct Key {
        static let isEnabled = "SendUsageReports"
        static let appInstallID = "WMFAppInstallID"
        static let lastLoggedSnapshot = "WMFLastLoggedSnapshot"
        static let appInstallDate = "AppInstallDate"
        static let loggedDaysInstalled = "DailyLoggingStatsDaysInstalled"
    }
    
    private var pruningAge: TimeInterval = 60*60*24*30 // 30 days
    private var sendImmediatelyOnWWANThreshhold: TimeInterval = 30
    private var postBatchSize = 10
    private var postTimeout: TimeInterval = 60*2 // 2 minutes
    private var postInterval: TimeInterval = 60*10 // 10 minutes
    
    private var debugDisableImmediateSend = false
    

#if WMF_EVENT_LOGGING_DEV_DEBUG
    private static let scheme = "http"
    private static let host = "deployment.wikimedia.beta.wmflabs.org"
#else
    private static let scheme = "https"
    private static let host = "meta.wikimedia.org"
#endif
    private static let path = "/beacon/event"
    
    private let session: Session
    
    private let persistentStoreCoordinator: NSPersistentStoreCoordinator
    private let managedObjectContext: NSManagedObjectContext
    private let operationQueue: OperationQueue
    
    @objc(sharedInstance) public static let shared: EventLoggingService? = {
        let fileManager = FileManager.default
        var permanentStorageDirectory = fileManager.wmf_containerURL().appendingPathComponent("Event Logging", isDirectory: true)
        var didGetDirectoryExistsError = false
        do {
            try fileManager.createDirectory(at: permanentStorageDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch let error {
            DDLogError("EventLoggingService: Error creating permanent cache: \(error)")
        }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try permanentStorageDirectory.setResourceValues(values)
        } catch let error {
            DDLogError("EventLoggingService: Error excluding from backup: \(error)")
        }
        
        let permanentStorageURL = permanentStorageDirectory.appendingPathComponent("Events.sqlite")
        DDLogDebug("EventLoggingService: Events persistent store: \(permanentStorageURL)")
        
        return EventLoggingService(session: Session.shared, permanentStorageURL: permanentStorageURL)
    }()
    
    @objc
    public func log(event: Dictionary<String, Any>, schema: String, revision: Int, wiki: String) {
        let event: NSDictionary = ["event": event, "schema": schema, "revision": revision, "wiki": wiki]
        logEvent(event)
    }
    
    private init?(session: Session, permanentStorageURL: URL) {
        let bundle = Bundle.wmf
        let modelURL = bundle.url(forResource: "EventLogging", withExtension: "momd")!
        let model = NSManagedObjectModel(contentsOf: modelURL)!
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let options = [NSMigratePersistentStoresAutomaticallyOption: NSNumber(booleanLiteral: true), NSInferMappingModelAutomaticallyOption: NSNumber(booleanLiteral: true)]
        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        self.session = session
        do {
            try psc.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: permanentStorageURL, options: options)
        } catch {
            do {
                try FileManager.default.removeItem(at: permanentStorageURL)
            } catch {
                
            }
            do {
                try psc.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: permanentStorageURL, options: options)
            } catch {
                return nil
            }
        }
        
        self.persistentStoreCoordinator = psc
        self.managedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        self.managedObjectContext.persistentStoreCoordinator = psc
    }

    
    @objc
    public func reset() {
        self.resetSession()
        self.resetInstall()
    }

    // Called inside AsyncBlockOperation.
    private func prune() {
        
        self.managedObjectContext.perform {
            let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: "WMFEventRecord")
            fetch.returnsObjectsAsFaults = false
            
            let pruneDate = Date().addingTimeInterval(-(self.pruningAge)) as NSDate
            fetch.predicate = NSPredicate(format: "(recorded < %@) OR (posted != nil) OR (failed == TRUE)", pruneDate)
            let delete = NSBatchDeleteRequest(fetchRequest: fetch)
            delete.resultType = .resultTypeCount

            do {
                let result = try self.managedObjectContext.execute(delete)
                guard let deleteResult = result as? NSBatchDeleteResult else {
                    DDLogError("EventLoggingService: Could not read NSBatchDeleteResult")
                    return
                }
                
                guard let count = deleteResult.result as? Int else {
                    DDLogError("EventLoggingService: Could not read NSBatchDeleteResult count")
                    return
                }
                DDLogInfo("EventLoggingService: Pruned \(count) events")
                
            } catch let error {
                DDLogError("EventLoggingService: Error pruning events: \(error.localizedDescription)")
            }
        }
    }
    
    @objc
    private func logEvent(_ event: NSDictionary) {
        let now = NSDate()
        
        let moc = self.managedObjectContext
        moc.perform {
            let record = NSEntityDescription.insertNewObject(forEntityName: "WMFEventRecord", into: self.managedObjectContext) as! EventRecord
            record.event = event
            record.recorded = now
            record.userAgent = WikipediaAppUtils.versionedUserAgent()
            
            DDLogDebug("EventLoggingService: \(record.objectID) recorded!")
            
            self.save()
        }
    }
    
    @objc
    private func tryPostEvents(_ completion: (() -> Void)? = nil) {
        let operation = AsyncBlockOperation { (operation) in
            let moc = self.managedObjectContext
            moc.perform {
                let fetch: NSFetchRequest<EventRecord> = EventRecord.fetchRequest()
                fetch.sortDescriptors = [NSSortDescriptor(keyPath: \EventRecord.recorded, ascending: true)]
                fetch.predicate = NSPredicate(format: "(posted == nil) AND (failed != TRUE)")
                fetch.fetchLimit = self.postBatchSize

                var eventRecords: [EventRecord] = []

                do {
                    eventRecords = try moc.fetch(fetch)
                } catch let error {
                    DDLogError(error.localizedDescription)
                }

                defer {
                    if eventRecords.count > 0 {
                        self.postEvents(eventRecords, completion: {
                            operation.finish()
                        })
                    } else {
                        operation.finish()
                    }
                }
            }
        }
        operationQueue.addOperation(operation)
        guard let completion = completion else {
            return
        }
        operationQueue.addOperation(completion)
    }
    
    private func asyncSave() {
        self.managedObjectContext.perform {
            self.save()
        }
    }
    
    private func postEvents(_ eventRecords: [EventRecord], completion: @escaping () -> Void) {
        DDLogDebug("EventLoggingService: Posting \(eventRecords.count) events!")
        
        let taskGroup = WMFTaskGroup()
        
        var completedRecordIDs = Set<NSManagedObjectID>()
        var failedRecordIDs = Set<NSManagedObjectID>()
        
        for record in eventRecords {
            let moid = record.objectID
            guard let payload = record.event else {
                failedRecordIDs.insert(moid)
                continue
            }
            taskGroup.enter()
            let userAgent = record.userAgent ?? WikipediaAppUtils.versionedUserAgent()
            submit(payload: payload, userAgent: userAgent) { (error) in
                if error != nil {
                    failedRecordIDs.insert(moid)
                } else {
                    completedRecordIDs.insert(moid)
                }
                taskGroup.leave()
            }
        }
        
        
        taskGroup.waitInBackground {
            self.managedObjectContext.perform {
                let postDate = NSDate()
                for moid in completedRecordIDs {
                    let mo = try? self.managedObjectContext.existingObject(with: moid)
                    guard let record = mo as? EventRecord else {
                        continue
                    }
                    record.posted = postDate
                }
                
                for moid in failedRecordIDs {
                    let mo = try? self.managedObjectContext.existingObject(with: moid)
                    guard let record = mo as? EventRecord else {
                        continue
                    }
                    record.failed = true
                }
                self.save()
                if (completedRecordIDs.count == eventRecords.count) {
                    DDLogDebug("EventLoggingService: All records succeeded, attempting to post more")
                    self.tryPostEvents()
                } else {
                    DDLogDebug("EventLoggingService: Some records failed, waiting to post more")
                }
                completion()
            }
        }
    }
    
    private func submit(payload: NSObject, userAgent: String, completion: @escaping (EventLoggingError?) -> Void) {
        do {
            let payloadJsonData = try JSONSerialization.data(withJSONObject:payload, options: [])
            
            guard let payloadString = String(data: payloadJsonData, encoding: .utf8) else {
                DDLogError("EventLoggingService: Could not convert JSON data to string")
                completion(EventLoggingError.generic)
                return
            }
            
            let encodedPayloadJsonString = payloadString.wmf_UTF8StringWithPercentEscapes()
            var components = URLComponents()
            components.scheme = EventLoggingService.scheme
            components.host = EventLoggingService.host
            components.path = EventLoggingService.path
            components.percentEncodedQuery = encodedPayloadJsonString
            guard let url = components.url else {
                DDLogError("EventLoggingService: Could not creatre URL")
                completion(EventLoggingError.generic)
                return
            }
            
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            
            let task = self.session.dataTask(with: request, completionHandler: { (_, response, error) in
                guard error == nil,
                    let httpResponse = response as? HTTPURLResponse,
                    httpResponse.statusCode / 100 == 2 else {
                        completion(EventLoggingError.generic)
                        return
                }
                completion(nil)
                // DDLogDebug("EventLoggingService: event \(eventRecord.objectID) posted!")
            })
            task.resume()
            
        } catch let error {
            DDLogError(error.localizedDescription)
            completion(EventLoggingError.generic)
            return
        }
    }
    
    // mark stored values
    
    private func save() {
        guard managedObjectContext.hasChanges else {
            return
        }
        do {
            try managedObjectContext.save()
        } catch let error {
            DDLogError("Error saving EventLoggingService managedObjectContext: \(error)")
        }
    }
    
    private var semaphore = DispatchSemaphore(value: 1)
    
    private var libraryValueCache: [String: NSCoding] = [:]
    private func libraryValue(for key: String) -> NSCoding? {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        var value = libraryValueCache[key]
        if value != nil {
            return value
        }
        
        managedObjectContext.performAndWait {
            value = managedObjectContext.wmf_keyValue(forKey: key)?.value
            if value != nil {
                libraryValueCache[key] = value
                return
            }
            
            if let legacyValue = UserDefaults.wmf.object(forKey: key) as? NSCoding {
                value = legacyValue
                libraryValueCache[key] = legacyValue
                managedObjectContext.wmf_setValue(legacyValue, forKey: key)
                UserDefaults.wmf.removeObject(forKey: key)
                save()
            }
        }
    
        return value
    }
    
    private func setLibraryValue(_ value: NSCoding?, for key: String) {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        libraryValueCache[key] = value
        managedObjectContext.perform {
            self.managedObjectContext.wmf_setValue(value, forKey: key)
            self.save()
        }
    }
    
    @objc public var isEnabled: Bool {
        get {
            var isEnabled = false
            if let enabledNumber = libraryValue(for: Key.isEnabled) as? NSNumber {
                isEnabled = enabledNumber.boolValue
            } else {
                setLibraryValue(NSNumber(booleanLiteral: false), for: Key.isEnabled) // set false so that it's cached and doesn't keep fetching
            }
            return isEnabled
        }
        set {
            setLibraryValue(NSNumber(booleanLiteral: newValue), for: Key.isEnabled)
        }
    }
    
    @objc public var appInstallID: String? {
        get {
            var installID = libraryValue(for: Key.appInstallID) as? String
            if installID == nil || installID == "" {
                installID = UUID().uuidString
                setLibraryValue(installID as NSString?, for: Key.appInstallID)
            }
            return installID
        }
        set {
            setLibraryValue(newValue as NSString?, for: Key.appInstallID)
        }
    }
    
    @objc public var lastLoggedSnapshot: NSCoding? {
        get {
            return libraryValue(for: Key.lastLoggedSnapshot)
        }
        set {
            setLibraryValue(newValue, for: Key.lastLoggedSnapshot)
        }
    }
    
    @objc public var appInstallDate: Date? {
        get {
            var value = libraryValue(for: Key.appInstallDate) as? Date
            if value == nil {
                value = Date()
                setLibraryValue(value as NSDate?, for: Key.appInstallDate)
            }
            return value
        }
        set {
            setLibraryValue(newValue as NSDate?, for: Key.appInstallDate)
        }
    }
    
    @objc public var loggedDaysInstalled: NSNumber? {
        get {
            return libraryValue(for: Key.loggedDaysInstalled) as? NSNumber
        }
        set {
            setLibraryValue(newValue, for: Key.loggedDaysInstalled)
        }
    }
    
    private var _sessionID: String?
    @objc public var sessionID: String? {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        if _sessionID == nil {
            _sessionID = UUID().uuidString
        }
        return _sessionID
    }
    
    private var _sessionStartDate: Date?
    @objc public var sessionStartDate: Date? {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        if _sessionStartDate == nil {
            _sessionStartDate = Date()
        }
        return _sessionStartDate
    }
    
    @objc public func resetSession() {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        _sessionID = nil
        _sessionStartDate = Date()
    }
    
    private func resetInstall() {
        appInstallID = nil
        lastLoggedSnapshot = nil
        loggedDaysInstalled = nil
        appInstallDate = nil
    }
}

extension EventLoggingService: PeriodicWorker {
    public func doPeriodicWork(_ completion: @escaping () -> Void) {
        tryPostEvents(completion)
    }
}

extension EventLoggingService: BackgroundFetcher {
    public func performBackgroundFetch(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        doPeriodicWork {
            completion(.noData)
        }
    }
}
