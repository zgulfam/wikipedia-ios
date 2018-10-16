import Foundation

@objc(WMFPeriodicWorker) public protocol PeriodicWorker: NSObjectProtocol {
    func doPeriodicWork(_ completion: @escaping () -> Void)
}

@objc(WMFPeriodicWorkerController) public class PeriodicWorkerController: NSObject {
    lazy var workTimer: RepeatingTimer = {
        assert(Thread.isMainThread)
        return RepeatingTimer(30, { [weak self] in
            self?.doPeriodicWork()
        })
    }()
    
    var workers = PointerArray<PeriodicWorker>()
    
    @objc public func add(_ worker: PeriodicWorker) {
        workers.append(worker)
    }
    
    @objc public func start() {
        workTimer.resume()
    }
    
    @objc public func stop() {
        workTimer.pause()
    }
    
    @objc public func doPeriodicWork(_ completion: (() -> Void)? = nil) {
        workers.allObjects.asyncForEach({ (worker, completion) in
            worker.doPeriodicWork(completion)
        }) { () in
            completion?()
        }
    }
}
