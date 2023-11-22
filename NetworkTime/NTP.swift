//
//  NTP.swift
//  ntp.swift
//
//  Created by Michael Sanders on 7/9/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Result

public enum SNTPClientError: ErrorType {
    case UnresolvableHost(underlyingError: CFStreamError?)
    case SocketError(underlyingError: NSError?)
}

public struct ReferenceTime {
    public let time: NSDate
    public let uptime: timeval
}

public extension ReferenceTime {
    func now() -> NSDate {
        let currentUptime = timeval.uptime()
        let interval = NSTimeInterval(milliseconds: currentUptime.milliseconds -
                                                    uptime.milliseconds)
        return time.dateByAddingTimeInterval(interval)
    }
}

public typealias NetworkTimeCallback = Result<ReferenceTime, SNTPClientError> -> Void

@objc public final class SNTPClient: NSObject {
    public let hostURLs: [NSURL]
    public let timeout: NSTimeInterval
    required public init(hostURLs: [NSURL],
                         timeout: NSTimeInterval = defaultTimeout) {
        self.hostURLs = hostURLs
        self.timeout = timeout
    }

    public func start() {
        dispatch_async(queue) {
            self.startTime = CFAbsoluteTimeGetCurrent()
            self.hosts = self.hostURLs.map { url in  SNTPHost(hostURL: url,
                                            timeout: self.timeout,
                                            onComplete: self.onComplete) }

            self.hosts.forEach { $0.start() }
        }
    }

    public func pause() {
        dispatch_async(queue) {
            self.hosts.forEach { $0.close() }
        }
    }

    public func retrieveNetworkTime(callback: NetworkTimeCallback) {
        dispatch_async(queue) {
            guard let referenceTime = self.referenceTime else {
                self.callbacks.append(callback)
                if self.results.count == self.hosts.count {
                    self.start() // Retry if we failed last time.
                }
                return
            }

            callback(.Success(referenceTime))
        }
    }

    private var startTime: NSTimeInterval? = nil
    private let queue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-client", nil)
    private var callbacks: [NetworkTimeCallback] = []
    private var hosts: [SNTPHost] = []
    private var results: [Result<ReferenceTime, SNTPClientError>] = []
    private var referenceTime: ReferenceTime?
}


// MARK: - Objective-C Bridging

@objc public final class BridgedReferenceTime: NSObject {
    public let referenceTime: ReferenceTime
    init(referenceTime: ReferenceTime) {
        self.referenceTime = referenceTime
    }

    public var time: NSDate { return referenceTime.time }
    public var uptime: timeval { return referenceTime.uptime }
    public func now() -> NSDate { return referenceTime.now() }
}

extension SNTPClient {
    @objc public func bridgedRetrieveNetworkTime(success: BridgedReferenceTime -> Void,
                                                 failure: NSError -> Void) {
        retrieveNetworkTime { result in
            switch result {
                case let .Success(time):
                    success(BridgedReferenceTime(referenceTime: time))
                case let .Failure(error):
                    failure(error.bridged)
            }
        }
    }
}

private let bridgedErrorDomain = "com.instacart.sntp-client-error"
private extension SNTPClientError {
    var bridged: NSError {
        switch self {
            case let .SocketError(underlyingError):
                if let underlyingError = underlyingError {
                    return underlyingError
                }
            default:
                break
        }

        let (code, description) = metadata
        return NSError(domain: bridgedErrorDomain,
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: description])
    }

    var metadata: (Int, String) {
        switch self {
            case .UnresolvableHost:
                return (1, "Unresolvable host name.")
            case .SocketError:
                return (2, "Failed connecting to NTP server.")
        }
    }
}

// MARK: -

private extension SNTPClient {
    func onComplete(result: Result<ReferenceTime, SNTPClientError>) {
        dispatch_async(queue) {
            self.results.append(result)
            switch result {
                case let .Success(referenceTime):
                    self.referenceTime = referenceTime
                    fallthrough
                case .Failure where self.results.count == self.hosts.count:
                    let endTime = CFAbsoluteTimeGetCurrent()
                    debugLog("\(self.results.count) results: \(self.results)")
                    debugLog("Took \(endTime - self.startTime!)s")
                    self.hosts.forEach { $0.close() }
                    self.callbacks.forEach { $0(result) }
                    self.callbacks = []
                default:
                    break
            }
        }
    }
}

private let defaultTimeout: NSTimeInterval = 5
