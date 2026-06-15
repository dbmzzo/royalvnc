#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Server to Client Messages
extension VNCConnection {
	func startReceiveLoop() {
        logger.logDebug("Starting receive loop")

        receiveTask = Task(priority: taskPriority) {
			while !state.disconnectRequested,
                  connection.isReady {
				do {
					try await receive()
				} catch {
					handleBreakingError(error)
				}
			}
		}
	}
}

private extension VNCConnection {
	func receive() async throws {
		guard !state.disconnectRequested else {
			// Just ignore, since disconnect has already been requested
			return
		}

        guard connection.isReady else {
			throw VNCError.connection(.notReady)
		}

		let serverToClientMessage = try await VNCProtocol.ServerToClientMessage.receive(connection: connection)

		try await didReceive(messageType: serverToClientMessage.messageType)
	}

	func didReceive(messageType: UInt8) async throws {
		switch messageType {
			case VNCProtocol.FramebufferUpdate.messageType:
				try await handleFramebufferUpdateMessage()

			case VNCProtocol.SetColourMapEntries.messageType:
				try await handleSetColourMapEntriesMessage()

			case VNCProtocol.ServerCutText.messageType:
				try await handleServerCutTextMessage()

			case VNCProtocol.Bell.messageType:
				try await handleBellMessage()

			case VNCProtocol.EndOfContinuousUpdates.messageType:
				try await handleEndOfContinuousUpdatesMessage()

			default:
				throw VNCError.protocol(.unsupportedServerToClientMessage(messageType: messageType))
		}
	}

	func handleFramebufferUpdateMessage() async throws {
		guard let framebuffer = framebuffer else {
			throw VNCError.protocol(.framebufferUpdateReceivedWithoutFramebuffer)
		}

		logger.logDebug("Receiving Framebuffer Update")

		// DeepVNC stats: time the receive+decode of this frame, and the idle gap
		// since the previous one finished (≈ request round-trip on a non-CU link).
		let startNanos = DispatchTime.now().uptimeNanoseconds
		let gapMillis: Double? = lastFrameEndNanos == 0
			? nil
			: Double(startNanos &- lastFrameEndNanos) / 1_000_000

		let framebufferUpdate = try await VNCProtocol.FramebufferUpdate.receive(connection: connection,
																				framebuffer: framebuffer,
																				encodings: encodings,
																				logger: logger)

		let endNanos = DispatchTime.now().uptimeNanoseconds
		lastFrameEndNanos = endNanos
		// Encoding of the largest frame rect = what the server is really using.
		let dominantEncoding = framebufferUpdate.rectangles
			.max(by: { (Int($0.width) * Int($0.height)) < (Int($1.width) * Int($1.height)) })?
			.encodingType
		recordFrameTiming(receiveDecodeMillis: Double(endNanos &- startNanos) / 1_000_000,
						  gapMillis: gapMillis,
						  frameEncodingRawValue: dominantEncoding)

		logger.logDebug("Received Framebuffer Update: \(framebufferUpdate)")

		/*
		// Write out the framebuffer for testing purposes
		try framebuffer.writeSurface()
		*/

		try await sendFramebufferUpdateRequest()
	}

	func handleSetColourMapEntriesMessage() async throws {
		guard let framebuffer = framebuffer else {
			throw VNCError.protocol(.setColourMapEntriesReceivedWithoutFramebuffer)
		}

		logger.logDebug("Receiving Colour Map Entries")

		let colourMapEntries = try await VNCProtocol.SetColourMapEntries.receive(connection: connection,
																				 logger: logger)

		logger.logDebug("Received Colour Map Entries")

		framebuffer.updateColorMap(colourMapEntries)
	}

	func handleServerCutTextMessage() async throws {
		logger.logDebug("Receiving Clipboard Text from Server")

		let serverCutText = try await VNCProtocol.ServerCutText.receive(connection: connection,
																		logger: logger)

		let text = serverCutText.text

		logger.logDebug("Received Clipboard Text from Server")

		guard settings.isClipboardRedirectionEnabled else { return }

		clipboard.text = text
	}

	func handleBellMessage() async throws {
		logger.logDebug("Receiving Bell Message from Server")

		_ = try await VNCProtocol.Bell.receive(connection: connection,
											   logger: logger)

		logger.logDebug("Received Bell Message from Server")

		systemSound.play()
	}

	func handleEndOfContinuousUpdatesMessage() async throws {
		let first = !state.areContinuousUpdatesSupported

		state.areContinuousUpdatesSupported = true
		state.areContinuousUpdatesEnabled = false

		if first {
			logger.logDebug("Continuous Updates supported (server sent EndOfContinuousUpdates)")
		} else {
			logger.logDebug("Disabling Continuous Updates")
		}

		// DeepVNC patch: turn continuous updates on the first time the server
		// advertises support, so it pushes frames without a per-frame request.
		if first, settings.isContinuousUpdatesEnabled {
			try await sendEnableContinuousUpdates()
		} else {
			try await sendFramebufferUpdateRequest()
		}
	}
}
