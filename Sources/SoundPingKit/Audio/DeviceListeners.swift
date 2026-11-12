import CoreAudio
import Foundation
import Synchronization

/// Watches the devices of a run and turns what the HAL announces into `DeviceEvent`s (ENG-07).
///
/// A rate, buffer size or stream layout that differs from what the run opened with, a device that
/// is no longer alive or no longer listed, and an IO that stopped on its own all abort the run: a
/// number measured across such a change would hide an offset. A processor overload only rejects the
/// hits whose window it touched. Every notification is compared with the value the run started
/// with before it becomes an event, so another app changing its own buffer size on a shared device
/// (a per-process property) does not abort anything.
///
/// The listeners run on one private serial queue, never on the audio thread. `remove()` takes every
/// one of them away again.
/// Set once the listeners are taken away, so a notification that is already running says nothing.
private final class StopFlag: Sendable {
  private let flag = Atomic<Bool>(false)
  var isSet: Bool { flag.load(ordering: .relaxed) }
  func set() { flag.store(true, ordering: .relaxed) }
}

final class DeviceListeners: Sendable {
  /// The per-device selectors, with the four-character codes the HAL uses for them.
  static let deviceSelectors: [AudioObjectPropertySelector] = [
    kAudioDevicePropertyDeviceIsAlive,  // 'livn'
    kAudioDevicePropertyNominalSampleRate,  // 'nsrt'
    kAudioDevicePropertyBufferFrameSize,  // 'fsiz'
    kAudioDevicePropertyStreamConfiguration,  // 'slay'
    kAudioDeviceProcessorOverload,  // 'over'
    kAudioDevicePropertyIOStoppedAbnormally,  // 'stpd'
  ]
  /// The system object's list of devices: a device in use that leaves it is gone.
  static let systemSelector: AudioObjectPropertySelector = kAudioHardwarePropertyDevices  // 'dev#'

  struct Watched: Sendable {
    var id: AudioDeviceID
    var uid: String
    /// The buffer size this process was given, in frames.
    var bufferFrames: Int
  }

  private struct Registration: @unchecked Sendable {
    var object: AudioObjectID
    var address: AudioObjectPropertyAddress
    var block: AudioObjectPropertyListenerBlock
  }

  private let queue = DispatchQueue(label: "soundping.hal-listeners")
  private let registrations = Mutex<[Registration]>([])
  private let stopped = StopFlag()
  /// How many registrations the HAL refused; the run still works, it just watches less.
  let refused = Atomic<Int>(0)

  init(
    watching devices: [Watched], rate: Double, rt: RTState,
    sink: AsyncStream<DeviceEvent>.Continuation
  ) {
    let ids = devices.map(\.id)
    let uids = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.uid) })

    for device in devices {
      let layout = Self.layout(of: device.id)
      let uid = device.uid
      let id = device.id

      // 'livn'
      add(id, kAudioDevicePropertyDeviceIsAlive) { [stopped] in
        guard !stopped.isSet else { return }
        let alive = HALProperty.get(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(1))
        if alive == 0 { sink.yield(.gone(uid: uid)) }
      }
      // 'nsrt'
      add(id, kAudioDevicePropertyNominalSampleRate) { [stopped] in
        guard !stopped.isSet else { return }
        guard
          let now = HALProperty.get(
            id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
          abs(now - rate) > 0.5
        else { return }
        sink.yield(.sampleRateChanged(uid: uid, from: rate, to: now))
      }
      // 'fsiz'
      add(id, kAudioDevicePropertyBufferFrameSize) { [stopped] in
        guard !stopped.isSet else { return }
        guard
          let now = HALProperty.get(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)),
          Int(now) != device.bufferFrames
        else { return }
        sink.yield(.bufferSizeChanged(uid: uid, from: device.bufferFrames, to: Int(now)))
      }
      // 'slay', once per direction
      for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
        add(id, kAudioDevicePropertyStreamConfiguration, scope: scope) { [stopped] in
          guard !stopped.isSet else { return }
          if Self.layout(of: id) != layout { sink.yield(.streamConfigChanged(uid: uid)) }
        }
      }
      // 'over'
      add(id, kAudioDeviceProcessorOverload) { [stopped] in
        guard !stopped.isSet else { return }
        let frame = Int64(rt.inputNextLabel.load(ordering: .acquiring))
        sink.yield(.overload(uid: uid, atInputFrame: frame))
      }
      // 'stpd'
      add(id, kAudioDevicePropertyIOStoppedAbnormally) { [stopped] in
        guard !stopped.isSet else { return }
        sink.yield(.ioStopped(uid: uid))
      }
    }

    // 'dev#'
    add(AudioObjectID(kAudioObjectSystemObject), Self.systemSelector) { [stopped] in
      guard !stopped.isSet else { return }
      let listed = Set(
        HALProperty.array(
          AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices,
          of: AudioDeviceID.self, initial: AudioDeviceID(0)))
      for id in ids where !listed.contains(id) {
        sink.yield(.gone(uid: uids[id] ?? "unknown"))
      }
    }
  }

  /// The channel count of each buffer in both directions: what the IOProc's buffer list looks like.
  private static func layout(of device: AudioDeviceID) -> [[Int]] {
    [
      HALProperty.streamChannelCounts(device, scope: kAudioObjectPropertyScopeInput),
      HALProperty.streamChannelCounts(device, scope: kAudioObjectPropertyScopeOutput),
    ]
  }

  private func add(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    handler: @escaping @Sendable () -> Void
  ) {
    var address = HALProperty.address(selector, scope: scope)
    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    if status == noErr {
      registrations.withLock {
        $0.append(Registration(object: object, address: address, block: block))
      }
    } else {
      refused.wrappingAdd(1, ordering: .relaxed)
    }
  }

  /// Takes every listener away and waits for a notification that is already running. Idempotent.
  func remove() {
    stopped.set()
    let taken = registrations.withLock { list -> [Registration] in
      let all = list
      list = []
      return all
    }
    for registration in taken {
      var address = registration.address
      AudioObjectRemovePropertyListenerBlock(
        registration.object, &address, queue, registration.block)
    }
    queue.sync {}
  }
}
