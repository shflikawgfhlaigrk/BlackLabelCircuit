// CircuitPortKit — one spelling for Combine schedulers and Foundation publishers on
// every platform. Apple's Combine makes DispatchQueue / RunLoop / OperationQueue
// schedulers directly; OpenCombine (Windows, Linux) reaches them through `.ocombine`.
// Converted code writes `DispatchQueue.main.circuitScheduler` and gets the right one.
import Foundation
import Dispatch

#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine

extension DispatchQueue { public var circuitScheduler: DispatchQueue { self } }
extension RunLoop { public var circuitScheduler: RunLoop { self } }
extension OperationQueue { public var circuitScheduler: OperationQueue { self } }
extension NotificationCenter { public var circuitCombine: NotificationCenter { self } }
extension URLSession { public var circuitCombine: URLSession { self } }

#elseif canImport(OpenCombine)
import OpenCombine
import OpenCombineDispatch
import OpenCombineFoundation

extension DispatchQueue { public var circuitScheduler: DispatchQueue.OCombine { ocombine } }
extension RunLoop { public var circuitScheduler: RunLoop.OCombine { ocombine } }
extension OperationQueue { public var circuitScheduler: OperationQueue.OCombine { ocombine } }
extension NotificationCenter { public var circuitCombine: NotificationCenter.OCombine { ocombine } }
extension URLSession { public var circuitCombine: URLSession.OCombine { ocombine } }
#endif
