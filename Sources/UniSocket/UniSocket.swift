/*
 * Copyright 2017-2020 Seznam.cz, a.s.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Author: Daniel Fojt (daniel.fojt2@firma.seznam.cz)
 */

import Foundation
#if os(macOS) || os(iOS) || os(tvOS)
import Darwin
private let system_socket = Darwin.socket
private let system_bind = Darwin.bind
private let system_listen = Darwin.listen
private let system_accept = Darwin.accept
private let system_connect = Darwin.connect
private let system_close = Darwin.close
private let system_recv = Darwin.recv
private let system_send = Darwin.send
private let system_sendto = Darwin.sendto
typealias fdmask = Int32
#elseif os(Linux)
import Glibc
private let system_socket = Glibc.socket
private let system_bind = Glibc.bind
private let system_listen = Glibc.listen
private let system_accept = Glibc.accept
private let system_connect = Glibc.connect
private let system_close = Glibc.close
private let system_recv = Glibc.recv
private let system_send = Glibc.send
private let system_sendto = Glibc.sendto
typealias fdmask = __fd_mask
#endif

public enum UniSocketError: Error {
	case error(detail: String)
}

public enum UniSocketType: String {
	case tcp
	case udp
	case local
}

public enum UniSocketStatus: String {
	case none
	case stateless
	case connected
	case listening
	case readable
	case writable
}

public typealias UniSocketTimeout = (connect: UInt?, read: UInt?, write: UInt?)

public class UniSocket {

	public let type: UniSocketType
	public var timeout: UniSocketTimeout
	private(set) var status: UniSocketStatus = .none
	private var fd: Int32 = -1
	private var fdset = fd_set()
	private let fdmask_size: Int
	private let fdmask_bits: Int
	private let peer: String
	private var peer_addrinfo: UnsafeMutablePointer<addrinfo>
	private var peer_local = sockaddr_un()
	private var buffer: UnsafeMutablePointer<UInt8>
	private let bufferSize = 32768

	public init(type: UniSocketType, peer: String, port: Int32? = nil, timeout: UniSocketTimeout = (connect: 5, read: 5, write: 5)) throws {
		guard peer.count > 0 else {
			throw UniSocketError.error(detail: "invalid peer name")
		}
		self.type = type
		self.timeout = timeout
		self.peer = peer
		fdmask_size = MemoryLayout<fdmask>.size
		fdmask_bits = fdmask_size * 8
		buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
		peer_addrinfo = UnsafeMutablePointer<addrinfo>.allocate(capacity: 1)
		memset(peer_addrinfo, 0, MemoryLayout<addrinfo>.size)
		if type == .local {
			peer_local.sun_family = sa_family_t(AF_UNIX)
			withUnsafeMutablePointer(to: &peer_local.sun_path.0) { ptr in
				_ = peer.withCString {
					strcpy(ptr, $0)
				}
			}
			peer_addrinfo.pointee.ai_family = PF_LOCAL
#if os(macOS) || os(iOS) || os(tvOS)
			peer_addrinfo.pointee.ai_socktype = SOCK_STREAM
#elseif os(Linux)
			peer_addrinfo.pointee.ai_socktype = Int32(SOCK_STREAM.rawValue)
#endif
			peer_addrinfo.pointee.ai_protocol = 0
			let ptr: UnsafeMutablePointer<sockaddr_un> = withUnsafeMutablePointer(to: &peer_local) { $0 }
			peer_addrinfo.pointee.ai_addr = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
			peer_addrinfo.pointee.ai_addrlen = socklen_t(MemoryLayout<sockaddr_un>.size)
		} else {
			guard let p = port else {
				throw UniSocketError.error(detail: "missing port")
			}
			var rc: Int32
			var errstr: String = ""
#if os(macOS) || os(iOS) || os(tvOS)
			var hints = addrinfo(ai_flags: AI_PASSIVE, ai_family: PF_UNSPEC, ai_socktype: 0, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
#elseif os(Linux)
			var hints = addrinfo(ai_flags: AI_PASSIVE, ai_family: PF_UNSPEC, ai_socktype: 0, ai_protocol: 0, ai_addrlen: 0, ai_addr: nil, ai_canonname: nil, ai_next: nil)
#endif
			switch type {
			case .tcp:
#if os(macOS) || os(iOS) || os(tvOS)
				hints.ai_socktype = SOCK_STREAM
#elseif os(Linux)
				hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
#endif
			case .udp:
#if os(macOS) || os(iOS) || os(tvOS)
				hints.ai_socktype = SOCK_DGRAM
#elseif os(Linux)
				hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
#endif
			default:
				throw UniSocketError.error(detail: "unsupported socket type \(type)")
			}
			var ptr: UnsafeMutablePointer<addrinfo>? = peer_addrinfo
			peer_addrinfo.deallocate()
			rc = getaddrinfo(peer, String(p), &hints, &ptr)
			if rc != 0 {
				if rc == EAI_SYSTEM {
					errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
				} else {
					errstr = String(validatingUTF8: gai_strerror(rc)) ?? "unknown error code"
				}
				throw UniSocketError.error(detail: "failed to resolve '\(peer)', \(errstr)")
			}
			peer_addrinfo = ptr!
		}
	}

	deinit {
		try? close()
		buffer.deallocate()
		if type == .local {
			peer_addrinfo.deallocate()
		} else {
			freeaddrinfo(peer_addrinfo)
		}
	}

	private func FD_SET() -> Void {
		let index = Int(fd) / fdmask_bits
		let bit = Int(fd) % fdmask_bits
		var mask: fdmask = 1 << bit
		withUnsafePointer(to: &mask) { src in
			withUnsafeMutablePointer(to: &fdset) { dst in
				memset(dst, 0, MemoryLayout<fd_set>.size)
				memcpy(dst + (index * fdmask_size), src, fdmask_size)
			}
		}
	}

  ///
	/// Private function to return the last error based on the value of errno.
	///
	/// - Returns: String containing relevant text about the error.
	///
	private func lastError() -> String {

		return String(validatingUTF8: strerror(errno)) ?? "Error: \(errno)"
	}



  public func accept() throws -> UniSocket {

		// The socket must've been created, not connected and listening...
		if fd == -1 {

			throw UniSocketError.error(detail: "The socket has an invalid descriptor")
		}

		if status != .listening {
			throw UniSocketError.error(detail: "The socket is not listening")
		}

		var socketfd2: Int32 = -1
		// var address: Address? = nil
    let clientSocket = try UniSocket(type: type, peer: peer)

		var keepRunning: Bool = true
		repeat {
      let lenPtr: UnsafeMutablePointer<socklen_t> = withUnsafeMutablePointer(to: &clientSocket.peer_addrinfo.pointee.ai_addrlen) { $0 }
      let fd = system_accept(fd, clientSocket.peer_addrinfo.pointee.ai_addr, lenPtr)
      // guard let acceptAddress = try Address(addressProvider: { (addressPointer, addressLengthPointer) in
      // 	#if os(Linux)
      // 		let fd = Glibc.accept(self.socketfd, addressPointer, addressLengthPointer)
      // 	#else
      // 		let fd = Darwin.accept(self.socketfd, addressPointer, addressLengthPointer)
      // 	#endif

        if fd < 0 {

          // The operation was interrupted, continue the loop...
          if errno == EINTR {
            continue
            // throw OperationInterrupted.accept
          }

          throw UniSocketError.error(detail: "Socket accept failed: \(lastError())")
        }
        socketfd2 = fd
      // }) else {
      // 	throw Error(code: Socket.SOCKET_ERR_WRONG_PROTOCOL, reason: "Unable to determine incoming socket protocol family.")
      // }
      // address = acceptAddress

			keepRunning = false
		} while keepRunning

    print("client socket: \(socketfd2), listen socket: \(fd)")
    clientSocket.fd = socketfd2
    clientSocket.status = .connected
    clientSocket.FD_SET()

    return clientSocket

		// Create the new socket...
		//	Note: The current socket continues to listen.
		// let newSocket = try Socket(fd: socketfd2, remoteAddress: address!, path: self.signature?.path)

    // Return the new socket...
    // return newSocket
  }

  public func listen(backlog: Int32 = 1) throws -> Void {

    if status != .connected {
			throw UniSocketError.error(detail: "The socket is not connected")
		}

    let ret = system_listen(fd, backlog)
    if ret != 0 {
      let errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
			throw UniSocketError.error(detail: "failed to attach socket to '\(peer)' (\(errstr))")
    }

    status = .listening
  }

  public func bind() throws -> Void {
    guard status == .none else {
			throw UniSocketError.error(detail: "socket is \(status)")
		}
		var rc: Int32
		var errstr: String? = ""
		var ai: UnsafeMutablePointer<addrinfo>? = peer_addrinfo
		while ai != nil {
			fd = system_socket(ai!.pointee.ai_family, ai!.pointee.ai_socktype, ai!.pointee.ai_protocol)
			if fd == -1 {
				ai = ai?.pointee.ai_next
				continue
			}
			FD_SET()
			// let flags = fcntl(fd, F_GETFL)
			// if flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 {
				if type == .udp {
					status = .stateless
					return
				}
				rc = system_bind(fd, ai!.pointee.ai_addr, ai!.pointee.ai_addrlen)
				if rc == 0 {
					break
				}
				if errno != EINPROGRESS {
					errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
				} else if let e = waitFor(.connected) {
					errstr = e
				} else {
					break
				}
			// } else {
			// 	errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
			// }
			_ = system_close(fd)
			fd = -1
			ai = ai?.pointee.ai_next
		}
		if fd == -1 {
			throw UniSocketError.error(detail: "failed to attach socket to '\(peer)' (\(errstr ?? ""))")
		}
		status = .connected
  }

	public func attach() throws -> Void {
		guard status == .none else {
			throw UniSocketError.error(detail: "socket is \(status)")
		}
		var rc: Int32
		var errstr: String? = ""
		var ai: UnsafeMutablePointer<addrinfo>? = peer_addrinfo
		while ai != nil {
			fd = system_socket(ai!.pointee.ai_family, ai!.pointee.ai_socktype, ai!.pointee.ai_protocol)
			if fd == -1 {
				ai = ai?.pointee.ai_next
				continue
			}
			FD_SET()
			let flags = fcntl(fd, F_GETFL)
			if flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 {
				if type == .udp {
					status = .stateless
					return
				}
				rc = system_connect(fd, ai!.pointee.ai_addr, ai!.pointee.ai_addrlen)
				if rc == 0 {
					break
				}
				if errno != EINPROGRESS {
					errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
				} else if let e = waitFor(.connected) {
					errstr = e
				} else {
					break
				}
			} else {
				errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
			}
			_ = system_close(fd)
			fd = -1
			ai = ai?.pointee.ai_next
		}
		if fd == -1 {
			throw UniSocketError.error(detail: "failed to attach socket to '\(peer)' (\(errstr ?? ""))")
		}
		status = .connected
	}

	public func close() throws -> Void {
		if status == .connected {
			shutdown(fd, Int32(SHUT_RDWR))
			usleep(10000)
		}
		if fd != -1 {
			_ = system_close(fd)
			fd = -1
		}
		status = .none
	}

  private func getTimeout(_ status: UniSocketStatus, _ timeout: UInt?) -> UInt? {
    if let t = timeout {
      return t
    }

    switch status {
		case .connected: return self.timeout.connect
		case .readable:  return self.timeout.read
		case .writable:  return self.timeout.write
		default:
			return nil
		}
  }
  // func _select(_ nfds: Int32, _ readfds: UnsafeMutablePointer<fd_set>!, _ writefds: UnsafeMutablePointer<fd_set>!, _ errorfds: UnsafeMutablePointer<fd_set>!, _ timeout: UInt?) -> Int32 {
  //   var timer = timeval()
  //   if let t = timeout {
  //     timer.tv_sec = time_t(t)
  //     return select(nfds, readfds, writefds, errorfds, &timer)
  //   }
  //   else {
  //     return select(nfds, readfds, writefds, errorfds, nil)
  //   }
  // }

  func _select(_ nfds: Int32, _ readfds: UnsafeMutablePointer<fd_set>!, _ writefds: UnsafeMutablePointer<fd_set>!, _ errorfds: UnsafeMutablePointer<fd_set>!, _ timeout: UInt?) -> Int32 {
    var timer = timeval()
    if let t = timeout {
      timer.tv_sec = time_t(t)
    }

    return withUnsafeMutablePointer(to: &timer, { ptr in
      let optionalTimeoutArg = timeout != nil ? ptr : nil
      // print("select with timeout: \(optionalTimeoutArg)")
      return select(nfds, readfds, writefds, errorfds, optionalTimeoutArg)
    })
  }

	private func waitFor(_ status: UniSocketStatus, timeout: UInt? = nil) -> String? {
		var rc: Int32
		var fds = fdset
    let t = getTimeout(status, timeout)

		switch status {
		case .connected:
			rc = _select(fd + 1, nil, &fds, nil, t)
		case .readable:
			rc = _select(fd + 1, &fds, nil, nil, t)
		case .writable:
			rc = _select(fd + 1, nil, &fds, nil, t)
		default:
			return nil
		}
		if rc > 0 {
			return nil
		} else if rc == 0 {
			var len = socklen_t(MemoryLayout<Int32>.size)
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &rc, &len)
			if rc == 0 {
				rc = ETIMEDOUT
			}
		} else {
			rc = errno
		}
		return String(validatingUTF8: strerror(rc)) ?? "unknown error code"
	}

	public func recv(min: Int = 1, max: Int? = nil) throws -> Data {
		guard status == .connected || status == .stateless else {
			throw UniSocketError.error(detail: "socket is \(status)")
		}
		if let errstr = waitFor(.readable) {
			throw UniSocketError.error(detail: errstr)
		}
		var rc: Int = 0
		var data = Data(bytes: buffer, count: 0)
		while rc == 0 {
			var limit = bufferSize
			if let m = max, (m - data.count) < bufferSize {
				limit = m - data.count
			}
			rc = system_recv(fd, buffer, limit, 0)
			if rc == 0 {
				try? close()
				throw UniSocketError.error(detail: "connection closed by remote host")
			} else if rc == -1 {
				let errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
				throw UniSocketError.error(detail: "failed to read from socket, \(errstr)")
			}
			data.append(buffer, count: rc)
			if let m = max, data.count >= m {
				break
			} else if max == nil, rc == bufferSize, waitFor(.readable, timeout: 0) == nil {
				rc = 0
			} else if data.count >= min {
				break
			}
		}
		return data
	}

	public func send(_ buffer: Data) throws -> Void {
		guard status == .connected || status == .stateless else {
			throw UniSocketError.error(detail: "socket is \(status)")
		}
		var bytesLeft = buffer.count
		var rc: Int
		while bytesLeft > 0 {
			let rangeLeft = Range(uncheckedBounds: (lower: buffer.index(buffer.startIndex, offsetBy: (buffer.count - bytesLeft)), upper: buffer.endIndex))
			let bufferLeft = buffer.subdata(in: rangeLeft)
			if let errstr = waitFor(.writable) {
				throw UniSocketError.error(detail: errstr)
			}
			if status == .stateless {
				rc = bufferLeft.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in return system_sendto(fd, ptr.baseAddress, bytesLeft, 0, peer_addrinfo.pointee.ai_addr, peer_addrinfo.pointee.ai_addrlen) }
			} else {
				rc = bufferLeft.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in return system_send(fd, ptr.baseAddress, bytesLeft, 0) }
			}
			if rc == -1 {
				let errstr = String(validatingUTF8: strerror(errno)) ?? "unknown error code"
				throw UniSocketError.error(detail: "failed to write to socket, \(errstr)")
			}
			bytesLeft = bytesLeft - rc
		}
	}

	public func recvfrom() throws -> Data {

		throw UniSocketError.error(detail: "not yet implemented")

	}

}
