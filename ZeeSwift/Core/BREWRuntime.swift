import Darwin
import Foundation

final class BREWRuntime {
  static let base: UInt32 = 0x0010_0000
  // The game owns a contiguous module image; HLE objects must never occupy it.
  // Keep the historical layout for small modules and move the HLE arena for larger ones.
  struct AddressSpace {
    let codeSize: Int
    let hleBase: UInt32
    var codeEnd: UInt32 { BREWRuntime.base + UInt32(codeSize) }
    init(moduleSize: Int) throws {
      guard moduleSize > 0, moduleSize <= 0x00e0_0000 else {
        throw EmulationError.unsupported("BREW module exceeds the available code region (14 MiB)")
      }
      codeSize = max(0x0030_0000, (moduleSize + 0xfff) & ~0xfff)
      hleBase = max(0x0080_0000, (BREWRuntime.base + UInt32(codeSize) + 0xfffff) & ~0xfffff)
    }
  }
  let addressSpace: AddressSpace
  func hleAddress(_ offset: UInt32) -> UInt32 { addressSpace.hleBase + offset }
  static let returnAddress: UInt32 = 0xffff_fff0
  let memory = GuestMemory()
  let cpu: ARMCPU
  let jit: ARM64JIT
  let package: GamePackage
  let cancellation: EmulationCancellation
  var onCopyright: ((BREWCopyrightInfo) -> Bool)?
  var log: [String] = []
  var heap: UInt32 = 0x0100_0000
  var module: UInt32 = 0
  var bundledModules: [String: BREWLoadedModule] = [:]
  var loadingModules: Set<String> = []
  var nextModuleRegion: UInt32 = 0x0500_0000
  var applet: UInt32 = 0
  private var appletCloseRequested = false
  private var closingApplet = false
  private(set) var appletClosed = false
  var phase = "Loaded"
  var shell: UInt32 { hleAddress(0x2000) }
  private var globals: UInt32 { hleAddress(0x0) }
  private var allocations: [UInt32: Int] = [:]
  // One bit per 16-byte heap slot records released allocation starts. A fixed 512 KiB
  // bitmap bounds this compatibility bookkeeping independently of session duration.
  private var releasedAllocationStarts = [UInt64](repeating: 0, count: 65536)
  private(set) var repeatedFreeCount: UInt64 = 0
  private var allocationCallStack: (base: UInt32, size: Int)?
  private var freeBlocks: [(address: UInt32, size: UInt32)] = []
  // A trap address has one stable diagnostic name throughout this runtime.
  private var hleCallNames: [UInt32: String] = [:]
  private(set) var debugConsole = Data()
  private(set) var discardedDebugBytes: UInt64 = 0
  private static let hleInterfaces = [
      "AEE", "IShell", "IDisplay", "IHeap", "IGraphics", "IBitmap",
      "IFileMgr", "IFile", "IUnzipAStream", "IGL", "IEGL", "IHID", "ISignalCBFactory",
      "ISignalCtl", "IHIDDevice", "IEGL10", "IGLES10", "IMedia", "IThread",
      "IEGLSurfaceManip", "EGLSurfaceScale",
      "IImageDecoder", "IForceFeed", "ImageBitmap", "IImage", "IMediaUtil", "IMemAStream", "ISound", "ILicense",
      "IGLES11Ext", "GLExtensions",
      "IGLESImageonExt", "ITransform", "IHash", "ICipherFactory", "ICipher1", "IWeb", "ITextCtl", "IHashCtx", "INetMgr", "ISQL", "IRootForm", "IStatic", "IMenuCtl", "IWidget", "IValueModel", "ICM", "IVectorModel", "IInterfaceModel", "IXYContainer", "ICanvas", "ViewportContainer",
      "IFont", "IConfig", "ISourceUtil", "ISource",
    ]
  private(set) var calls: [String: Int] = [:]
  var useJIT = true
  enum ExecutionPolicy {
    case bounded
    case cancellable
    case diagnosticLimit(Int)
  }
  // Deterministic probes retain per-call ceilings. The app runs until return or Stop.
  var executionPolicy = ExecutionPolicy.bounded
  var executionSamples: [UInt32: Int]?
  var threads: [UInt32: BREWThread] = [:]
  var activeThread: UInt32?
  var invocationDepth = 0
  struct ScheduledCallback {
    var deadline: UInt64
    var callback: UInt32
    var context: UInt32
    var signal: UInt32? = nil
    var image: UInt32? = nil
    var stream: UInt32? = nil
  }
  var timers: [ScheduledCallback] = []
  var shellAlarms: [UInt16: Int64] = [:]
  static let alarmSavePath = "fs:/sys/zeeswift-alarms.json"
  private(set) var timerInvocationCounts: [UInt32: UInt64] = [:]
  let started = ProcessInfo.processInfo.systemUptime
  var virtualWallClockEpoch = Date()
  var clockTimeZone = TimeZone.autoupdatingCurrent
  // Extend the test clock across the guest's 32-bit millisecond rollover.
  private var virtualTimerMilliseconds: UInt64 = 0
  var virtualMilliseconds: UInt32? {
    didSet {
      if let current = virtualMilliseconds {
        if let previous = oldValue {
          virtualTimerMilliseconds &+= UInt64(current &- previous)
        } else {
          virtualTimerMilliseconds = UInt64(current)
        }
      }
    }
  }
  var timerMilliseconds: UInt64 {
    virtualMilliseconds != nil
      ? virtualTimerMilliseconds
      : UInt64((ProcessInfo.processInfo.systemUptime - started) * 1000)
  }
  var nextTimerDelay: UInt32? {
    guard let first = timers.first else { return nil }
    let now = timerMilliseconds
    return first.deadline > now ? UInt32(clamping: first.deadline - now) : 0
  }
  func scheduleCallback(
    delay: UInt32, callback: UInt32, context: UInt32, signal: UInt32? = nil, image: UInt32? = nil, stream: UInt32? = nil
  ) {
    let timer = ScheduledCallback(
      deadline: timerMilliseconds + UInt64(delay), callback: callback, context: context,
      signal: signal, image: image, stream: stream)
    // Equal deadlines retain registration order; immediate input can precede a long timer.
    let index = timers.firstIndex { $0.deadline > timer.deadline } ?? timers.endIndex
    timers.insert(timer, at: index)
  }
  var uptimeMilliseconds: UInt32 {
    virtualMilliseconds
      ?? UInt32(truncatingIfNeeded: UInt64((ProcessInfo.processInfo.systemUptime - started) * 1000))
  }
  private var wallClockSnapshot: (date: Date, milliseconds: Int64) {
    let date: Date
    let milliseconds: Int64
    if virtualMilliseconds != nil {
      milliseconds =
        Int64((virtualWallClockEpoch.timeIntervalSince1970 * 1000).rounded(.down))
        + Int64(virtualTimerMilliseconds)
      date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    } else {
      date = Date()
      milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
    return (date, milliseconds)
  }
  var localTimeSeconds: UInt32 {
    let (date, milliseconds) = wallClockSnapshot
    let seconds = milliseconds / 1000 - (milliseconds < 0 && milliseconds % 1000 != 0 ? 1 : 0)
    // BREW's civil-time epoch is 1980-01-06, not Unix's 1970-01-01.
    return UInt32(truncatingIfNeeded: seconds - 315_964_800 + Int64(clockTimeZone.secondsFromGMT(for: date)))
  }
  var utcTimeSeconds: UInt32 {
    let milliseconds = wallClockSnapshot.milliseconds
    let seconds = milliseconds / 1000 - (milliseconds < 0 && milliseconds % 1000 != 0 ? 1 : 0)
    return UInt32(truncatingIfNeeded: seconds - 315_964_800)
  }
  var shellAlarmWallMilliseconds: Int64 { wallClockSnapshot.milliseconds }
  var localDayMilliseconds: UInt32 {
    let (date, milliseconds) = wallClockSnapshot
    let local = milliseconds + Int64(clockTimeZone.secondsFromGMT(for: date)) * 1000
    return UInt32((local % 86_400_000 + 86_400_000) % 86_400_000)
  }
  func sleepGuest(milliseconds: UInt32) throws {
    try cancellation.check()
    if let virtualMilliseconds {
      self.virtualMilliseconds = virtualMilliseconds &+ milliseconds
    } else {
      // MSLEEP blocks this app's guest queue, not the macOS main thread. No timer callbacks
      // may reenter the guest while the synchronous BREW call is pending.
      try cancellation.wait(milliseconds: milliseconds)
    }
    try cancellation.check()
  }
  var display: UInt32 { hleAddress(0x5000) }
  var displayDestination: UInt32
  var displayClip: SIMD4<Int>?
  var clonedDisplays: [UInt32: BREWDisplayContext] = [:]
  var defaultDisplay: UInt32?
  var rootForms: [UInt32: BREWRootForm] = [:]
  var formWidgets: [UInt32: BREWFormWidget] = [:]
  var fontObjects: [UInt32: BREWFont] = [:]
  var eglColorBuffer: UInt32 = 0
  var eglColorBufferSnapshot = Data()
  var valueModels: [UInt32: BREWValueModel] = [:]
  var formContainers: [UInt32: UInt32] = [:]
  var formCanvases: [UInt32: BREWCanvas] = [:]
  var callManagers: [UInt32: UInt32] = [:]
  var staticControls: [UInt32: BREWStaticControl] = [:]
  var menuControls: [UInt32: BREWMenuControl] = [:]
  var deviceNotificationMasks: [UInt32: UInt32] = [:]
  var postedShellEvents: [UInt32: [UInt32]] = [:]
  var nextShellEvent: UInt32 = 1
  var heapObject: UInt32 { hleAddress(0x6000) }
  var resourceService: UInt32 { hleAddress(0xc000) }
  var resourceFileCache: (path: String, overlay: Data?, file: BREWResourceFile)?
  var imageDecoders: [UInt32: BREWImageDecoder] = [:]
  var bitmapTransforms: [UInt32: BREWBitmapTransform] = [:]
  var hashes: [UInt32: BREWMD5] = [:]
  var hashContexts: [UInt32: UInt32] = [:]
  var cipherFactories: [UInt32: UInt32] = [:]
  var ciphers: [UInt32: BREWAESCipher] = [:]
  var webObjects: [UInt32: BREWWeb] = [:]
  var netObjects: [UInt32: BREWNet] = [:]
  var sqlObjects: [UInt32: BREWSQLObject] = [:]
  var textControls: [UInt32: BREWTextControl] = [:]
  var imageBitmaps: [UInt32: BREWImageBitmap] = [:]
  var imageViewers: [UInt32: BREWImageViewer] = [:]
  var convertedBitmaps = Set<UInt32>()
  var fileManager: UInt32 { hleAddress(0xa000) }
  let framebuffer: UInt32 = 0x0600_0000
  let frames: FrameStore
  let frameSession: UUID
  var guestFrames: UInt64 = 0
  let gl = GLESState()
  var graphicsErrorLogCount = 0
  var glObject: UInt32 { hleAddress(0xd000) }
  var eglObject: UInt32 { hleAddress(0xe000) }
  var qeglObject: UInt32 { hleAddress(0x13000) }
  var qglesObject: UInt32 { hleAddress(0x14000) }
  var qsurfaceObject: UInt32 { hleAddress(0x15000) }
  var qglesExtensionObject: UInt32 { hleAddress(0x18000) }
  var imageonExtensionObject: UInt32 { hleAddress(0x19000) }
  var hidObject: UInt32 { hleAddress(0xf000) }
  var signalFactory: UInt32 { hleAddress(0x10000) }
  var hidConnectSignal: UInt32 = 0
  var hidDevice: UInt32 { hleAddress(0x12000) }
  // Player one remains available for keyboard use; player two is attached on demand.
  var hidPads = [HIDPadState(), HIDPadState(connected: false)]
  var hidConnections: [(handle: UInt32, status: UInt32)] = []
  var hidConnectionsDropped = false
  var hidButtons: Set<Int> { get { hidPads[0].buttons } set { hidPads[0].buttons = newValue } }
  var keyboardButtons: Set<Int> { get { hidPads[0].keyboard } set { hidPads[0].keyboard = newValue } }
  var controllerButtons: Set<Int> { get { hidPads[0].controller } set { hidPads[0].controller = newValue } }
  var hidAxes: [UInt32] { get { hidPads[0].axes } set { hidPads[0].axes = newValue } }
  var hidEvents: [(button: Int, down: Bool, time: UInt32)] { get { hidPads[0].events } set { hidPads[0].events = newValue } }
  var hidSignals: [UInt32: UInt32] { get { hidPads[0].signals } set { hidPads[0].signals = newValue } }
  var hidExclusive: UInt32 { get { hidPads[0].exclusive } set { hidPads[0].exclusive = newValue } }
  struct Signal {
    var callback: UInt32
    var context: UInt32
    var enabled = true
    var pending = false
    var references: UInt32 = 1
  }
  var signals: [UInt32: Signal] = [:]
  var graphics: UInt32 { hleAddress(0x7000) }
  var bitmap: UInt32 { hleAddress(0x8000) }
  var dib: UInt32 { hleAddress(0x9000) }
  struct OpenFile {
    var name: String
    var data: Data
    var position: Int
    var writable: Bool
    var references: UInt32 = 1
    // Retain error state without retaining the guest manager handle. A closed manager's
    // recycled address must not redirect an existing file's errors to a new manager.
    var manager: FileManagerState?
  }
  var files: [UInt32: OpenFile] = [:]
  var unzipData = Data()
  var unzipStreams: [UInt32: BREWUnzipStream] = [:]
  var savedFiles: [String: Data] = [:]
  var savedDirectories: Set<String> = []
  var absoluteFileAliases: [String: String] = [:]
  var removedPaths: Set<String> = []
  var mountedFiles: [String: ZIPArchive.Entry] = [:]
  var mountedDirectories: Set<String> = []
  let saveStore: GameSaveStore?
  let preferenceStore: BREWPreferenceStore
  var fileError: UInt32 = 0
  var fileManagers: [UInt32: FileManagerState] = [:]
  var media: [UInt32: BREWMedia] = [:]
  var sounds: [UInt32: BREWSound] = [:]
  var configObjects: [UInt32: UInt32] = [:]
  var shellBeep = BREWShellBeep()
  var soundTone = BREWShellBeep()
  var soundToneOwner: (handle: UInt32, sound: BREWSound)?
  var soundToneDeadline: UInt64?
  var soundNotifications: [BREWSoundNotification] = []
  var licenseReferences: [UInt32: UInt32] = [:]
  var onVibration: ((UInt16) -> Void)?
  var vibrationOwner: UInt32?
  var vibrationDeadline: UInt64?
  var memoryStreams: [UInt32: BREWMemoryStream] = [:]
  var sourceUtilities: [UInt32: UInt32] = [:]
  var memorySources: [UInt32: BREWMemorySource] = [:]
  var mediaUtilities: [UInt32: UInt32] = [:]
  var mediaNotifications: [BREWMediaNotification] = []
  var graphicsState: [UInt32: UInt32] = [:]
  var graphicsDestination: UInt32
  var graphicsViewport = SIMD4<Int>(0, 0, 640, 480)
  var graphicsViewportFramed = false
  var graphicsClip: SIMD4<Int>?
  var graphicsClipFramed = false
  var graphicsOrigin = SIMD2<Int>(0, 0)
  init(
    package: GamePackage, frames: FrameStore = FrameStore(), saveStore: GameSaveStore? = nil,
    cancellation: EmulationCancellation = EmulationCancellation(), frameSession: UUID? = nil
  ) throws {
    try cancellation.check()
    self.cancellation = cancellation
    self.package = package
    let addressSpace = try AddressSpace(moduleSize: package.module.count)
    self.addressSpace = addressSpace
    displayDestination = addressSpace.hleBase + 0x8000
    graphicsDestination = addressSpace.hleBase + 0x8000
    self.frames = frames
    self.frameSession = frameSession ?? frames.beginSession()
    self.saveStore = saveStore
    preferenceStore = BREWPreferenceStore(root: saveStore?.url.deletingLastPathComponent())
    savedFiles = saveStore?.files ?? [:]
    savedDirectories = saveStore?.directories ?? []
    removedPaths = saveStore?.removedPaths ?? []
    cpu = ARMCPU(memory: memory, trapRange: Self.trapRange)
    jit = try ARM64JIT()
    fileManagers[fileManager] = FileManagerState()
    mountFiles()
    try normalizeSavedPaths()
    try restoreShellAlarms()
    try memory.map(Self.base - 0x1000, size: addressSpace.codeSize + 0x1000, executable: true)
    try memory.map(addressSpace.hleBase, size: 0x100000)
    try memory.map(0x0100_0000, size: 64 * 1024 * 1024)
    try memory.map(framebuffer, size: 640 * 480 * 2)
    try memory.map(0x0700_0000, size: 1024 * 1024)
    try memory.write(Self.base, data: package.module)
    try memory.write32(Self.base - 4, globals)
    try memory.write32(Self.base - 8, shell)
    for i in 0..<1024 { try memory.write32(globals + UInt32(i * 4), 0xf000_0000 + UInt32(i * 4)) }
    try memory.write32(shell, shell + 0x100)
    for i in 0..<128 {
      try memory.write32(shell + 0x100 + UInt32(i * 4), 0xf001_0000 + UInt32(i * 4))
    }
    try memory.write32(display, display + 0x100)
    for i in 0..<128 {
      try memory.write32(display + 0x100 + UInt32(i * 4), 0xf002_0000 + UInt32(i * 4))
    }
    try memory.write32(heapObject, heapObject + 0x100)
    for i in 0..<32 {
      try memory.write32(heapObject + 0x100 + UInt32(i * 4), 0xf003_0000 + UInt32(i * 4))
    }
    for (object, trap) in [
      (hidObject, UInt32(0xf00b_0000)), (glObject, UInt32(0xf009_0000)),
      (eglObject, UInt32(0xf00a_0000)), (resourceService, UInt32(0xf008_0000)),
      (qeglObject, UInt32(0xf00f_0000)), (qglesObject, UInt32(0xf010_0000)),
      (qsurfaceObject, UInt32(0xf013_0000)),
      (qglesExtensionObject, UInt32(0xf01d_0000)),
      (imageonExtensionObject, UInt32(0xf01f_0000)),
      (fileManager, UInt32(0xf006_0000)), (graphics, UInt32(0xf004_0000)), (bitmap, 0xf005_0000),
      (dib, 0xf005_0000),
    ] {
      try memory.write32(object, object + 0x100)
      for i in 0..<(object == qglesObject ? 192 : 128) {
        try memory.write32(object + 0x100 + UInt32(i * 4), trap + UInt32(i * 4))
      }
    }
    try memory.write32(dib + 8, framebuffer)
    try memory.write32(dib + 16, 0xf81f) // Default transparent color: RGB565 magenta.
    try memory.write16(dib + 20, 640)
    try memory.write16(dib + 22, 480)
    try memory.write16(dib + 24, 1280)
    try memory.write8(dib + 28, 16)
    try memory.write8(dib + 29, 16)
    try memory.write32(signalFactory, signalFactory + 0x100)
    for i in 0..<8 {
      try memory.write32(signalFactory + 0x100 + UInt32(i * 4), 0xf00c_0000 + UInt32(i * 4))
    }
    cpu.r[13] = 0x070f_f000
    cpu.trap = { [weak self] cpu in
      guard let self else { return false }
      return try self.dispatch(cpu)
    }
    cpu.supervisorCall = { [weak self] cpu, number in
      guard let self else { return false }
      return try self.handleSupervisorCall(cpu, number: number)
    }
    log.append("\(package.title): \(package.format), \(package.module.count) Bytes")
    if saveStore != nil { log.append("Save-game files loaded: \(savedFiles.count)") }
  }
  func allocate(_ request: UInt32) throws -> UInt32 {
    let size = request & 0x7fff_ffff
    guard size > 0, size <= 32 * 1024 * 1024 else { return 0 }
    let aligned = (size + 15) & ~15
    let p: UInt32
    if let index = freeBlocks.firstIndex(where: { $0.size >= aligned }) {
      p = freeBlocks[index].address
      freeBlocks[index].address += aligned
      freeBlocks[index].size -= aligned
      if freeBlocks[index].size == 0 { freeBlocks.remove(at: index) }
    } else {
      guard heap <= 0x0500_0000 - aligned else { return 0 }
      p = heap
      heap += aligned
    }
    allocations[p] = Int(size)
    forgetReleasedAllocationStarts(p, aligned)
    if request & 0x8000_0000 == 0 {
      try memory.write(p, data: Data(count: Int(size)))
    }
    return p
  }
  private func releaseBlock(_ address: UInt32, _ size: UInt32) {
    guard size > 0 else { return }
    freeBlocks.append((address, size))
    freeBlocks.sort { $0.address < $1.address }
    var merged: [(address: UInt32, size: UInt32)] = []
    for block in freeBlocks {
      if let last = merged.last, last.address + last.size == block.address {
        merged[merged.count - 1].size += block.size
      } else {
        merged.append(block)
      }
    }
    if let last = merged.last, last.address + last.size == heap {
      heap = last.address
      merged.removeLast()
    }
    freeBlocks = merged
  }
  func allocatedSize(_ pointer: UInt32) -> Int? { allocations[pointer] }

  /// This HLE's MALLOC bridge uses a deterministic 32-byte callee call record.
  /// AAPCS permits callee stack storage, but specifies neither this layout nor its
  /// residual contents. This is our compatibility convention, not a firmware trace.
  /// Iron Sight reuses inactive stack storage after an optional model open fails.
  private func allocateFromGuestCall() throws -> UInt32 {
    let savedSP = cpu.r[13]
    guard savedSP >= 32, savedSP & 3 == 0 else { return try allocate(cpu.r[0]) }
    let frame = savedSP - 32
    var valid = frame >= 0x0700_0000 && savedSP <= 0x0710_0000
    if !valid {
      // Some games switch to their own MALLOC-backed stacks. Cache the enclosing
      // allocation; revalidate its lifetime/size without a heap scan on every call.
      if let cached = allocationCallStack, allocations[cached.base] == cached.size,
        frame >= cached.base, UInt64(savedSP) <= UInt64(cached.base) + UInt64(cached.size) {
        valid = true
      } else if let block = allocations.first(where: {
        frame >= $0.key && UInt64(savedSP) <= UInt64($0.key) + UInt64($0.value)
      }) {
        allocationCallStack = (block.key, block.value)
        valid = true
      }
    }
    guard valid else { return try allocate(cpu.r[0]) }
    _ = try memory.region(frame, 32)
    cpu.r[13] = frame
    defer { cpu.r[13] = savedSP }
    for index in 0..<4 { try memory.write32(frame + UInt32(index * 4), cpu.r[index]) }
    try memory.write32(frame + 16, cpu.r[12])
    try memory.write32(frame + 20, cpu.r[14])
    try memory.write32(frame + 24, 0)  // Result slot, also initialized on failure.
    try memory.write32(frame + 28, 0)  // Reserved call-record word.
    let result = try allocate(memory.read32(frame))
    try memory.write32(frame + 24, result)
    return result
  }

  private func forgetReleasedAllocationStarts(_ pointer: UInt32, _ extent: UInt32) {
    let first = Int((pointer - 0x0100_0000) >> 4)
    let last = first + Int(extent >> 4) - 1
    let firstWord = first >> 6, lastWord = last >> 6
    let firstMask = UInt64.max << (first & 63)
    let lastMask = UInt64.max >> (63 - (last & 63))
    if firstWord == lastWord {
      releasedAllocationStarts[firstWord] &= ~(firstMask & lastMask)
    } else {
      releasedAllocationStarts[firstWord] &= ~firstMask
      for index in (firstWord + 1)..<lastWord { releasedAllocationStarts[index] = 0 }
      releasedAllocationStarts[lastWord] &= ~lastMask
    }
  }

  func free(_ pointer: UInt32) throws {
    guard pointer != 0 else { return }
    guard let size = allocations.removeValue(forKey: pointer) else {
      if pointer >= 0x0100_0000, pointer < 0x0500_0000, pointer & 15 == 0 {
        let slot = Int((pointer - 0x0100_0000) >> 4)
        if releasedAllocationStarts[slot >> 6] & (UInt64(1) << (slot & 63)) != 0 {
          repeatedFreeCount &+= 1
          if repeatedFreeCount <= 4 || repeatedFreeCount.nonzeroBitCount == 1 {
            log.append("Wiederholtes FREE: \(pointer.hex), LR=\(cpu.r[14].hex) (#\(repeatedFreeCount))")
          }
          return
        }
      }
      throw EmulationError.invalid("FREE without matching allocation: " + pointer.hex)
    }
    let slot = Int((pointer - 0x0100_0000) >> 4)
    releasedAllocationStarts[slot >> 6] |= UInt64(1) << (slot & 63)
    releaseBlock(pointer, (UInt32(size) + 15) & ~15)
  }
  func reallocate(_ pointer: UInt32, _ request: UInt32) throws -> UInt32 {
    if pointer == 0 { return try allocate(request) }
    guard let previous = allocations[pointer] else {
      throw EmulationError.invalid("REALLOC without matching allocation: " + pointer.hex)
    }
    let size = request & 0x7fff_ffff
    if size == 0 {
      try free(pointer)
      return 0
    }
    guard size <= 32 * 1024 * 1024 else { return 0 }
    let oldExtent = (UInt32(previous) + 15) & ~15
    let newExtent = (size + 15) & ~15
    var inPlace = newExtent <= oldExtent
    if newExtent < oldExtent { releaseBlock(pointer + newExtent, oldExtent - newExtent) }
    if newExtent > oldExtent {
      let growth = newExtent - oldExtent
      if pointer + oldExtent == heap && heap <= 0x0500_0000 - growth {
        heap += growth
        inPlace = true
      } else if let index = freeBlocks.firstIndex(where: {
        $0.address == pointer + oldExtent && $0.size >= growth
      }) {
        freeBlocks[index].address += growth
        freeBlocks[index].size -= growth
        if freeBlocks[index].size == 0 { freeBlocks.remove(at: index) }
        inPlace = true
      }
    }
    if inPlace {
      allocations[pointer] = Int(size)
      forgetReleasedAllocationStarts(pointer, newExtent)
      if Int(size) > previous && request & 0x8000_0000 == 0 {
        try memory.write(pointer + UInt32(previous), data: Data(count: Int(size) - previous))
      }
      return pointer
    }
    let replacement = try allocate(request)
    guard replacement != 0 else { return 0 }  // Allocation failure preserves the source.
    try memory.write(replacement, data: memory.data(pointer, count: previous))
    try free(pointer)
    return replacement
  }
  @discardableResult func invoke(_ address: UInt32, _ args: [UInt32], budget: Int = 2_000_000)
    throws -> UInt32
  {
    try cancellation.check()
    guard !appletClosed else { throw EmulationError.appletClosed }
    for (i, a) in args.enumerated() {
      if i < 4 { cpu.r[i] = a } else { try memory.write32(cpu.r[13] + UInt32((i - 4) * 4), a) }
    }
    cpu.r[14] = Self.returnAddress
    cpu.branch(address)
    return try continueGuestExecution(budget: budget)
  }
  func continueGuestExecution(budget: Int) throws -> UInt32 {
    guard !appletClosed else { throw EmulationError.appletClosed }
    let instructionLimit: Int?
    switch executionPolicy {
    case .bounded: instructionLimit = budget
    case .cancellable: instructionLimit = nil
    case .diagnosticLimit(let limit): instructionLimit = limit
    }
    invocationDepth += 1
    defer { invocationDepth -= 1 }
    try cancellation.check()
    let start = cpu.count
    var cancellationCheck = start &+ 1024
    while cpu.pc != Self.returnAddress {
      if cpu.count >= cancellationCheck {
        try cancellation.check()
        if executionSamples != nil {
          executionSamples?[cpu.pc | (cpu.thumb ? 1 : 0), default: 0] += 1
        }
        cancellationCheck = cpu.count &+ 1024
      }
      let maximum: Int
      if let instructionLimit {
        let remaining = instructionLimit - Int(cpu.count - start)
        if remaining <= 0 { throw EmulationError.budget(cpu.pc) }
        maximum = min(32, remaining)
      } else {
        maximum = 32
      }
      if try !useJIT || !jit.execute(cpu, maximum: maximum) {
        try cpu.step()
      }
    }
    try cancellation.check()
    // CloseApplet returns to its caller first. Only deliver STOP after the outer
    // guest call unwinds, never while a timer or nested interface call owns its stack.
    if invocationDepth == 1, appletCloseRequested, !closingApplet {
      try closeRequestedApplet()
    }
    return cpu.r[0]
  }
  private func closeRequestedApplet() throws {
    appletCloseRequested = false
    guard applet != 0 else { return }
    closingApplet = true
    let registers = (0..<16).map { cpu.r[$0] }, flags = cpu.cpsr
    defer {
      closingApplet = false
      appletCloseRequested = false
      for i in 0..<16 { cpu.r[i] = registers[i] }
      cpu.cpsr = flags
    }
    // AEE.h: EVT_APP_STOP receives a boolean*; FALSE requests background operation.
    let closeFlag = try allocate(4)
    guard closeFlag != 0 else { throw EmulationError.invalid("EVT_APP_STOP: guest memory exhausted") }
    defer { try? free(closeFlag) }
    try memory.write32(closeFlag, 1)
    log.append("IShell.CloseApplet → EVT_APP_STOP")
    try event(1, value: closeFlag)
    guard try memory.read8(closeFlag) != 0 else {
      phase = "Applet in background"
      log.append("EVT_APP_STOP: Applet fordert Hintergrundbetrieb an")
      return
    }
    let table = try memory.read32(applet)
    let references = try invoke(memory.read32(table + 4), [applet], budget: 100_000_000)
    log.append("IApplet_Release → \(references)")
    applet = 0
    try memory.write32(hleAddress(0x4004), 0)
    timers.removeAll()
    signals.removeAll()
    hidPads = [HIDPadState(), HIDPadState(connected: false)]
    hidConnections.removeAll()
    hidConnectionsDropped = false
    hidConnectSignal = 0
    mediaNotifications.removeAll()
    for object in media.values {
      object.player?.stop()
      object.midiOutput?.stop()
      object.pcmStream?.player.stop()
    }
    shellBeep.stop()
    finishSoundTone()
    soundNotifications.removeAll()
    stopSoundVibration()
    appletClosed = true
    phase = "Game ended"
    frames.endSession(frameSession)
    throw EmulationError.appletClosed
  }
  func boot() throws {
    phase = "BREW module initialization"
    let output = hleAddress(0x4000)
    let result = try invoke(Self.base, [shell, 0, output])
    module = try memory.read32(output)
    log.append("AEEMod_Load → \(result.hex), IModule \(module.hex)")
    guard result == 0, module != 0 else {
      throw EmulationError.unsupported("AEEMod_Load reported \(result)")
    }
    phase = "Module loaded"
    let table = try memory.read32(module)
    log.append(
      "IModule-vtable: "
        + (try (0..<4).map { try memory.read32(table + UInt32($0 * 4)).hex }).joined(
          separator: ", "))
  }
  func createApplet() throws {
    phase = "Applet creation"
    let table = try memory.read32(module)
    let entry = try memory.read32(table + 8)
    let out = hleAddress(0x4004)
    let result = try invoke(entry, [module, shell, package.classID, out])
    applet = try memory.read32(out)
    log.append("IModule_CreateInstance → \(result.hex), IApplet \(applet.hex)")
    guard result == 0, applet != 0 else {
      throw EmulationError.unsupported("Applet creation: \(result)")
    }
    phase = "Applet created"
  }
  func event(_ code: UInt32, key: UInt32 = 0, value: UInt32 = 0) throws {
    guard !appletClosed else { throw EmulationError.appletClosed }
    let table = try memory.read32(applet)
    let entry = try memory.read32(table + 8)
    var eventValue = value
    if (code == 0 || code == 3) && value == 0 {
      // AEEShell.h: EVT_APP_START/RESUME always receive AEEAppStart.
      // pszArgs remains NULL for a normal library launch without arguments.
      eventValue = hleAddress(0x21500)
      try memory.write(eventValue, data: Data(repeating: 0, count: 24))
      try memory.write32(eventValue + 4, package.classID)
      try memory.write32(eventValue + 8, defaultDisplay ?? display)
      try memory.write16(eventValue + 16, 640)
      try memory.write16(eventValue + 18, 480)
    }
    _ = try invoke(entry, [applet, code, key, eventValue], budget: 10_000_000)
  }
  // onlyDue is used by the real-time app. Explicit test stepping may advance to a timer.
  func pumpTimers(limit: Int = 1, onlyDue: Bool = false) throws {
    guard !appletClosed else { throw EmulationError.appletClosed }
    try pumpSound()
    try pumpMedia()
    for _ in 0..<limit {
      guard !timers.isEmpty else { return }
      let remaining = nextTimerDelay ?? 0
      if onlyDue && remaining != 0 { return }
      let timer = timers.removeFirst()
      if !onlyDue, let virtualMilliseconds {
        self.virtualMilliseconds = virtualMilliseconds &+ remaining
      }
      if timer.callback == 0xf001fe00 && timer.deadline > timerMilliseconds {
        // nextTimerDelay is UInt32-clamped; a long alarm may require multiple
        // diagnostic clock steps and must not fire at the first clamp boundary.
        timers.insert(timer, at: 0)
        return
      }
      if let object = timer.signal {
        guard let signal = signals[object], signal.callback == timer.callback else { continue }
      }
      let invocation = timerInvocationCounts[timer.callback, default: 0] &+ 1
      timerInvocationCounts[timer.callback] = invocation
      // Resume loops can run millions of times. Keep early calls and powers of two,
      // retaining the exact counter without allocating a string on every callback.
      if invocation <= 4 || invocation.nonzeroBitCount == 1 {
        log.append("Timer → " + timer.callback.hex + " (#\(invocation))")
      }
      // ISHELL_SetTimerEx passes the same AEECallback pointer in both arguments.
      if let handle = timer.image {
        guard let image = imageViewers[handle], image.callback == timer.callback else { continue }
        let info = try allocate(10)
        guard info != 0 else { throw EmulationError.invalid("IImage callback: guest memory exhausted") }
        defer { try? free(info) }
        try writeImageViewerInfo(image, to: info)
        _ = try invoke(timer.callback, [timer.context, handle, info, image.loadError ?? 0],
          budget: 10_000_000)
      } else if timer.stream != nil {
        _ = try invoke(timer.callback, [timer.context], budget: 100_000_000)
      } else if timer.callback == timer.context {
        try memory.write32(timer.callback + 8, 0)
        try memory.write32(timer.callback + 12, 0)
        let callback = try memory.read32(timer.callback + 16)
        let context = try memory.read32(timer.callback + 20)
        _ = try invoke(callback, [context], budget: 100_000_000)
      } else {
        _ = try invoke(timer.callback, [timer.context], budget: 100_000_000)
      }
      // SignalCBFactory owns the adapter around the void guest callback. The adapter
      // rearms after notification; an explicitly detached/released signal stays detached.
      if let object = timer.signal {
        guard var signal = signals[object], signal.callback != 0 else { continue }
        signal.enabled = true
        signals[object] = signal
        if signal.pending { raiseSignal(object) }
      }
    }
  }
  private func handleSupervisorCall(_ cpu: ARMCPU, number: UInt32) throws -> Bool {
    guard number == (cpu.thumb ? 0xab : 0x123456) else { return false }
    let bytes: Data
    switch cpu.r[0] {
    case 3: bytes = Data([UInt8(try memory.read8(cpu.r[1]))])
    case 4: bytes = try memory.stringBytes(cpu.r[1])
    case 0x18: throw EmulationError.guestExit(cpu.r[1])
    default: throw EmulationError.unsupported("ARM semihosting call " + cpu.r[0].hex)
    }
    let retained = min(bytes.count, 65536 - debugConsole.count)
    debugConsole.append(bytes.prefix(retained))
    discardedDebugBytes &+= UInt64(bytes.count - retained)
    // WRITEC/WRITE0 have no result. Preserve registers as a deterministic choice.
    return true
  }
  private static let trapRange: ClosedRange<UInt32> =
    0xf000_0000...(0xf000_0000 + UInt32(hleInterfaces.count) * 0x10000 - 1)

  private func dispatch(_ cpu: ARMCPU) throws -> Bool {
    guard Self.trapRange.contains(cpu.pc) else { return false }
    let api = cpu.pc & 0xffff_0000
    let offset = cpu.pc & 0xffff
    let name: String
    if let cached = hleCallNames[cpu.pc] {
      name = cached
    } else {
      let index = Int((api - 0xf000_0000) >> 16)
      name = "\(Self.hleInterfaces[index])+\(offset.hex)"
      hleCallNames[cpu.pc] = name
    }
    calls[name, default: 0] += 1
    if log.count < 200 || calls[name] == 1 {
      log.append(
        "\(name)(\(cpu.r[0].hex), \(cpu.r[1].hex), \(cpu.r[2].hex), \(cpu.r[3].hex)) LR=\(cpu.r[14].hex)"
      )
    }
    if api == 0xf000_0000 {
      switch offset {
      case 0x8c: try getAEEVersion()
      case 0x80: try wideStringCopyN()
      case 0xa4:
        let date = wallClockSnapshot.date
        if cpu.r[0] != 0 {
          try memory.write8(cpu.r[0], clockTimeZone.isDaylightSavingTime(for: date) ? 1 : 0)
        }
        cpu.r[0] = UInt32(bitPattern: Int32(clockTimeZone.secondsFromGMT(for: date)))
      case 0x94, 0x98:
        let lhs = Double(bitPattern: UInt64(cpu.r[0]) | UInt64(cpu.r[1]) << 32)
        let rhs = Double(bitPattern: UInt64(cpu.r[2]) | UInt64(cpu.r[3]) << 32)
        let operation = try argument(4)
        if offset == 0x98 {
          let result: Bool
          switch operation {
          case 4: result = lhs < rhs
          case 5: result = lhs <= rhs
          case 6: result = lhs == rhs
          case 7: result = lhs > rhs
          case 8: result = lhs >= rhs
          default: throw EmulationError.unsupported("BREW f_cmp " + operation.hex)
          }
          cpu.r[0] = result ? 1 : 0
        } else {
          let result: Double
          switch operation {
          case 0: result = lhs + rhs
          case 1: result = lhs - rhs
          case 2: result = lhs * rhs
          case 3: result = lhs / rhs
          case 9: result = Darwin.pow(lhs, rhs)
          default: throw EmulationError.unsupported("BREW f_op " + operation.hex)
          }
          cpu.r[0] = UInt32(truncatingIfNeeded: result.bitPattern)
          cpu.r[1] = UInt32(truncatingIfNeeded: result.bitPattern >> 32)
        }
      case 0x19c:
        // Original AEEStdLib MAKEPATH(dir, file, output, inOutBytes).
        // Work on guest bytes: joining a path must not normalize its encoding,
        // scheme, case or dot components, or touch the host filesystem.
        let directory = cpu.r[0], filename = cpu.r[1], output = cpu.r[2], length = cpu.r[3]
        guard directory != 0, filename != 0, length != 0 else { cpu.r[0] = 14; break }
        _ = try memory.region(length, 4)
        var path = try memory.stringBytes(directory)
        let file = try memory.stringBytes(filename).drop(while: { $0 == 47 })
        if !path.isEmpty && !file.isEmpty && path.last != 47 { path.append(47) }
        path.append(contentsOf: file); path.append(0)
        if output == 0 {
          try memory.write32(length, UInt32(path.count)); cpu.r[0] = 0; break
        }
        let capacity = Int32(bitPattern: try memory.read32(length))
        guard capacity >= 0 else { cpu.r[0] = 14; break }
        guard Int(capacity) >= path.count else {
          // No partial path is usable. Leave the destination intact and report
          // that no bytes were written; callers can use the size-query form.
          try memory.write32(length, 0); cpu.r[0] = 38; break
        }
        try memory.write(output, data: path)
        try memory.write32(length, UInt32(path.count)); cpu.r[0] = 0
      case 0x1a4:
        // AEEStdLib.h STRIBEGINS(prefix, string): bytewise ASCII folding,
        // with no locale/Unicode normalization or allocation of a host string.
        let prefix = try memory.stringBytes(cpu.r[0]), string = cpu.r[1]
        func fold(_ byte: UInt32) -> UInt32 { (65...90).contains(byte) ? byte + 32 : byte }
        var matches = true
        for (index, byte) in prefix.enumerated() {
          let actual = try memory.read8(string &+ UInt32(index))
          if fold(actual) != fold(UInt32(byte)) { matches = false; break }
        }
        cpu.r[0] = matches ? 1 : 0
      case 0x1ac, 0x1b8, 0x1bc:
        let input = Double(bitPattern: UInt64(cpu.r[0]) | UInt64(cpu.r[1]) << 32)
        let integral = input.rounded(.towardZero)
        if offset == 0x1bc {
          guard let value = UInt32(exactly: integral) else {
            throw EmulationError.unsupported("UTRUNC outside uint32")
          }
          cpu.r[0] = value
        } else {
          guard let value = Int32(exactly: integral) else {
            throw EmulationError.unsupported("TRUNC outside int32")
          }
          cpu.r[0] = UInt32(bitPattern: value)
        }
      case 0x180:
        // AEEHelperFuncs.f_calc uses the base ARM ABI: double in r0:r1,
        // operation in r2, and the double result back in r0:r1.
        let input = Double(bitPattern: UInt64(cpu.r[0]) | UInt64(cpu.r[1]) << 32)
        let result: Double
        switch cpu.r[2] {
        case 10: result = Darwin.floor(input)
        case 11: result = Darwin.ceil(input)
        case 12: result = Darwin.sqrt(input)
        case 16: result = Darwin.sin(input)
        case 17: result = Darwin.cos(input)
        case 18: result = Double(bitPattern: input.bitPattern & 0x7fff_ffff_ffff_ffff)
        case 19: result = Darwin.tan(input)
        default: throw EmulationError.unsupported("BREW f_calc " + cpu.r[2].hex)
        }
        cpu.r[0] = UInt32(truncatingIfNeeded: result.bitPattern)
        cpu.r[1] = UInt32(truncatingIfNeeded: result.bitPattern >> 32)
      case 0x64:
        try convertWindowsBitmap()
      case 0xbc:
        guard convertedBitmaps.remove(cpu.r[0]) != nil else {
          throw EmulationError.invalid("SYSFREE without CONVERTBMP allocation")
        }
        _ = try releaseImageBitmap(cpu.r[0])
      case 0x134:
        cpu.r[0] = try fileSystemFree(total: cpu.r[0])
      case 0x138:
        let totalPointer = cpu.r[0]
        let largestPointer = cpu.r[1]
        for pointer in [totalPointer, largestPointer] where pointer != 0 {
          _ = try memory.region(pointer, 4)
        }
        let tail = 0x0500_0000 - heap
        let available = freeBlocks.reduce(tail) { $0 + $1.size }
        let largest = min(32 * 1024 * 1024, freeBlocks.reduce(tail) { max($0, $1.size) })
        if totalPointer != 0 { try memory.write32(totalPointer, 64 * 1024 * 1024) }
        if largestPointer != 0 { try memory.write32(largestPointer, largest) }
        cpu.r[0] = available
      case 0xc4:
        try stringToUnsignedLong()
      case 0x17c:
        try stringToDouble()
      case 0xf4:
        var bytes = try memory.stringBytes(cpu.r[0])
        bytes.append(0)
        let destination = try allocate(UInt32(bytes.count) | 0x8000_0000)
        if destination != 0 { try memory.write(destination, data: bytes) }
        cpu.r[0] = destination
      case 0x14c, 0x150, 0x154, 0x158:
        try boundedStringCopy(offset)
      case 0x90:
        var address = cpu.r[0]
        var reads = 0
        func nextByte() throws -> UInt32 {
          guard reads < 1_048_576 else { throw EmulationError.invalid("ATOI length") }
          reads += 1
          let value = try memory.read8(address)
          address &+= 1
          return value
        }
        var byte = try nextByte()
        while byte == 32 || (9...13).contains(byte) { byte = try nextByte() }
        let negative = byte == 45
        if byte == 43 || negative { byte = try nextByte() }
        var value: UInt32 = 0
        while (48...57).contains(byte) {
          // C atoi has undefined overflow. Keep a deterministic 32-bit wrap for
          // out-of-range guest text; valid signed ARM ints retain C semantics.
          value = value &* 10 &+ (byte - 48)
          byte = try nextByte()
        }
        cpu.r[0] = negative ? 0 &- value : value
      case 0xf8, 0xfc:
        let affix = try memory.stringBytes(cpu.r[0])
        let text = try memory.stringBytes(cpu.r[1])
        cpu.r[0] =
          (offset == 0xf8 ? text.prefix(affix.count) : text.suffix(affix.count)) == affix ? 1 : 0
      case 0x114, 0x118: // STRLOWER / STRUPPER return the original buffer.
        let bytes = try memory.stringBytes(cpu.r[0])
        // Match the byte-oriented ASCII casing used by STRICMP/STRISTR.
        // Preserve non-ASCII bytes rather than applying a host Unicode/locale conversion.
        let converted = Data(bytes.map { byte in
          if offset == 0x114 && (65...90).contains(byte) { return byte + 32 }
          if offset == 0x118 && (97...122).contains(byte) { return byte - 32 }
          return byte
        })
        if !converted.isEmpty { try memory.write(cpu.r[0], data: converted) }
      case 0x12c: cpu.r[0] = cpu.r[0].byteSwapped
      case 0x130: cpu.r[0] = UInt32(UInt16(truncatingIfNeeded: cpu.r[0]).byteSwapped)
      case 0x1b4:
        try sortGuest(base: cpu.r[0], count: cpu.r[1], size: cpu.r[2], comparator: cpu.r[3])
      case 0x10, 0xcc, 0xd0, 0xd4:
        let limit: UInt32 = (offset == 0xcc || offset == 0xd4) ? cpu.r[2] : 1_048_576
        let insensitive = offset == 0xd0 || offset == 0xd4
        var index: UInt32 = 0
        var result: Int32 = 0
        while index < limit {
          guard index < 1_048_576 else { throw EmulationError.invalid("String comparison length") }
          var a = try memory.read8(cpu.r[0] &+ index)
          var b = try memory.read8(cpu.r[1] &+ index)
          if insensitive {
            if (65...90).contains(a) { a += 32 }
            if (65...90).contains(b) { b += 32 }
          }
          if a != b || a == 0 {
            result = Int32(a) - Int32(b)
            break
          }
          index += 1
        }
        if index == 1_048_576 && offset != 0xcc && offset != 0xd4 {
          throw EmulationError.invalid("String comparison length")
        }
        cpu.r[0] = UInt32(bitPattern: result)
      case 0x00:
        if cpu.r[2] == 0 { break }
        try memory.write(cpu.r[0], data: memory.data(cpu.r[1], count: Int(cpu.r[2])))
      case 0xc8:
        let count = Int(cpu.r[2])
        if count > 0 {
          _ = try memory.region(cpu.r[0], count)
          var bytes = Data(count: count)
          for i in 0..<count {
            let byte = try memory.read8(cpu.r[1] &+ UInt32(i))
            if byte == 0 { break }
            bytes[i] = UInt8(byte)
          }
          try memory.write(cpu.r[0], data: bytes)
        }
      case 0xdc:
        let a = try memory.data(cpu.r[0], count: Int(cpu.r[2]))
        let b = try memory.data(cpu.r[1], count: Int(cpu.r[2]))
        var result: Int32 = 0
        for i in 0..<a.count {
          if a[i] != b[i] {
            result = Int32(a[i]) - Int32(b[i])
            break
          }
        }
        cpu.r[0] = UInt32(bitPattern: result)
      case 0xe8, 0xd8:
        func fold(_ data: Data) -> Data {
          offset == 0xe8 ? Data(data.map { (65...90).contains($0) ? $0 + 32 : $0 }) : data
        }
        let haystack = try fold(memory.stringBytes(cpu.r[0]))
        let needle = try fold(memory.stringBytes(cpu.r[1]))
        if needle.isEmpty { break }
        if let range = haystack.range(of: needle) {
          cpu.r[0] += UInt32(range.lowerBound)
        } else {
          cpu.r[0] = 0
        }
      case 0xec:
        let needle = try memory.stringBytes(cpu.r[1])
        if needle.isEmpty { break }
        let length = Int(cpu.r[2])
        guard needle.count <= length else {
          cpu.r[0] = 0
          break
        }
        let region = try memory.region(cpu.r[0], length)
        // MEMSTR searches binary bytes, including data after embedded NULs.
        // The guest queue owns the region for this synchronous, read-only search.
        let haystack = Data(bytesNoCopy: region.bytes.advanced(by: Int(cpu.r[0] - region.base)),
          count: length, deallocator: .none)
        cpu.r[0] = haystack.range(of: needle).map { cpu.r[0] + UInt32($0.lowerBound) } ?? 0
      case 0xa8:
        guard cpu.r[1] <= 65536 else { throw EmulationError.invalid("GETRAND length") }
        var random = SystemRandomNumberGenerator()
        try memory.write(
          cpu.r[0],
          data: Data((0..<cpu.r[1]).map { _ in UInt8.random(in: 0...255, using: &random) }))
      case 0x14: cpu.r[0] = UInt32(try memory.stringBytes(cpu.r[0]).count)
      case 0x18, 0x1c, 0x100, 0x104:
        let byte = UInt8(truncatingIfNeeded: cpu.r[1])
        var characters = SIMD4<UInt64>(repeating: 0)
        if offset == 0x104 {
          for value in try memory.stringBytes(cpu.r[1]) {
            characters[Int(value >> 6)] |= UInt64(1) << Int(value & 63)
          }
        }
        var match: UInt32 = 0
        var terminated = false
        for i: UInt32 in 0..<1_048_576 {
          let address = cpu.r[0] &+ i
          let current = try memory.read8(address)
          let found = offset == 0x104
            ? characters[Int(current >> 6)] & (UInt64(1) << Int(current & 63)) != 0
            : current == UInt32(byte)
          if found {
            match = address
            if offset != 0x1c {
              terminated = true
              break
            }
          }
          if current == 0 {
            // STRCHREND/STRCHRSEND fall back to the terminator.
            if offset >= 0x100 && match == 0 { match = address }
            terminated = true
            break
          }
        }
        guard terminated else { throw EmulationError.invalid("Guest string without terminator") }
        cpu.r[0] = match
      case 0x08: try memory.write(cpu.r[0], data: memory.stringBytes(cpu.r[1]) + Data([0]))
      case 0x0c:
        let count = try memory.stringBytes(cpu.r[0]).count
        try memory.write(cpu.r[0] + UInt32(count), data: memory.stringBytes(cpu.r[1]) + Data([0]))
      case 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x44:
        try wideStringCall(offset)
      case 0x3c: try formatWideGuestCall()
      case 0x54: try wideStringToUTF8()
      case 0x40:
        let destination = cpu.r[1]
        let size = Int(Int32(bitPattern: cpu.r[2]))
        guard size >= 0 else { throw EmulationError.invalid("STRTOWSTR length") }
        let capacity = size / 2
        if capacity > 0 {
          _ = try memory.region(destination, capacity * 2)
          var bytes = Data()
          for i in 0..<capacity - 1 {
            let byte = try memory.read8(cpu.r[0] &+ UInt32(i))
            if byte == 0 { break }
            bytes.append(UInt8(byte))
            bytes.append(0)
          }
          bytes.append(contentsOf: [0, 0])
          try memory.write(destination, data: bytes)
        }
        cpu.r[0] = destination
      case 0x50:
        // UTF8TOWSTR converts a counted byte sequence. An exact-size output
        // must retain every character; the caller may store the terminator
        // separately (as Z-Wheel's original string allocator does).
        let count = Int(Int32(bitPattern: cpu.r[1]))
        let size = Int(Int32(bitPattern: cpu.r[3]))
        guard count >= 0, count <= 65536, size >= 0, size <= 131072 else {
          cpu.r[0] = 0; break
        }
        let bytes = try memory.data(cpu.r[0], count: count)
        guard let string = String(data: bytes, encoding: .utf8) else { cpu.r[0] = 0; break }
        let units = Array(string.utf16)
        guard units.count <= size / 2 else { cpu.r[0] = 0; break }
        var output = Data()
        for unit in units { output.append(UInt8(truncatingIfNeeded: unit)); output.append(UInt8(unit >> 8)) }
        if units.last != 0 && output.count + 2 <= size { output.append(contentsOf: [0, 0]) }
        if !output.isEmpty { try memory.write(cpu.r[2], data: output) }
        cpu.r[0] = 1
      case 0xe4:
        let capacity = Int(cpu.r[3]) / 2
        guard capacity > 0, capacity <= 65536 else {
          throw EmulationError.invalid("STRTOWSTR length")
        }
        let input = try memory.string(cpu.r[0], limit: min(Int(cpu.r[1]) + 1, 65536))
        let units = Array(input.utf16.prefix(capacity - 1))
        for (i, c) in units.enumerated() { try memory.write16(cpu.r[2] + UInt32(i * 2), UInt32(c)) }
        try memory.write16(cpu.r[2] + UInt32(units.count * 2), 0)
      case 0x20, 0x13c, 0x140, 0x144:
        try formatGuestCall(offset: offset)
      case 0x04:
        if cpu.r[2] == 0 { break }
        guard cpu.r[2] <= 64 * 1024 * 1024 else {
          throw EmulationError.memory(cpu.r[0], Int(cpu.r[2]))
        }
        try memory.write(
          cpu.r[0], data: Data(repeating: UInt8(truncatingIfNeeded: cpu.r[1]), count: Int(cpu.r[2]))
        )
      case 0xac:
        cpu.r[0] = localDayMilliseconds
      case 0x184:
        try sleepGuest(milliseconds: cpu.r[0])
      case 0xb4:
        cpu.r[0] = localTimeSeconds
      case 0x1a8:
        cpu.r[0] = utcTimeSeconds // AEEStdLib GETUTCSECONDS: 1980-01-06 UTC epoch.
      case 0xb8:
        try getJulianDate()
      case 0x148:
        try julianToSeconds()
      case 0xb0:
        cpu.r[0] = uptimeMilliseconds
      case 0xc0: cpu.r[0] = try memory.read32(hleAddress(0x4004))  // GETAPPINSTANCE, observed applet layout +0x0c = IShell
      case 0x9c:
        let format = try memory.string(cpu.r[0])
        let scratch = hleAddress(0x1f000)
        for i in 0..<32 { try memory.write32(scratch + UInt32(i * 4), argument(i + 1)) }
        log.append("DBG: " + ((try? formatGuest(format, arguments: scratch)) ?? format))
        cpu.r[0] = 0
        // R3 is caller-saved. Use the first variadic word as our debug helper's
        // scratch result, after all original arguments have been captured.
        // Tork's loader spills it as a buffer capacity. This is an observed
        // compatibility convention, not a claim about the original firmware.
        cpu.r[3] = cpu.r[1]
      case 0x68: cpu.r[0] = try allocateFromGuestCall()
      case 0x6c:
        try free(cpu.r[0])
        cpu.r[0] = 0
      case 0x70: cpu.r[0] = try duplicateWideString(cpu.r[0])
      case 0x74: cpu.r[0] = try reallocate(cpu.r[0], cpu.r[1])
      default: throw EmulationError.hle(name, cpu.r[14])
      }
    } else if api == 0xf001_0000 {
      switch offset {
      case 0x20:
        // IShell.ActiveApplet returns a class ID (never an IApplet pointer).
        // This runtime hosts one foreground package; before creation/after close
        // no applet is visible. Nested forms remain part of the same applet.
        cpu.r[0] = applet != 0 && !appletClosed ? package.classID : 0
      case 0x74, 0x78:
        try changeShellAlarm(cancel: offset == 0x78)
      case 0x7c: cpu.r[0] = shellAlarms.isEmpty ? 0 : 1
      case 0xfe00:
        let key = UInt16(truncatingIfNeeded: cpu.r[0])
        if shellAlarms[key] != nil {
          var remaining = shellAlarms; remaining.removeValue(forKey: key)
          try saveShellAlarms(remaining)
          if applet != 0 { try event(0x400, key: UInt32(key)) }
        }
        cpu.r[0] = 0
      case 0x18:
        // This HLE hosts ordinary games, without PL_SYSTEM permission to close
        // other applications. AEEShell.h specifies EPRIVLEVEL for ReturnToIdle.
        if cpu.r[1] != 0 { cpu.r[0] = 21 }
        else if applet == 0 { cpu.r[0] = 1 }
        else {
          appletCloseRequested = true
          cpu.r[0] = 0
        }
      case 0x68:
        guard cpu.r[1] == 0 else {
          throw EmulationError.hle("IShell.Prompt with AEEPromptInfo", cpu.r[14])
        }
        // ShowCopyright is Prompt(NULL). TRUE means a real presenter accepted the dialog.
        cpu.r[0] = try onCopyright?(BREWCopyrightInfo(package: package)) == true ? 1 : 0
      case 0x44:
        try loadResourceString()
      case 0x4c:
        try loadResourceBitmap()
      case 0x48, 0xa4:
        try loadResourceData(extended: offset == 0xa4)
      case 0x50:
        try free(cpu.r[1])
        cpu.r[0] = 0
      case 0x5c, 0x60:
        try appPreferences(write: offset == 0x60)
      case 0x90:
        try scheduleGuestCallback(cpu.r[1])
      case 0x54: try sendShellEvent()
      case 0x58:
        // IShell.Beep returns a boolean, not an AEEResult. An unavailable tone
        // or audio device must not abort the applet or fabricate playback.
        let type = cpu.r[1]
        let played = shellBeep.play(type: type, loud: UInt8(truncatingIfNeeded: cpu.r[2]) != 0)
        log.append("IShell.Beep type \(type): \(played ? "accepted" : "unavailable")")
        cpu.r[0] = played ? 1 : 0
      case 0xff00:
        if let event = postedShellEvents.removeValue(forKey: cpu.r[0]), !appletClosed {
          let table = try memory.read32(event[0])
          _ = try invokeFormCallback(memory.read32(table + 8), event)
        }
        cpu.r[0] = 0
      case 0x88:
        // The TV-style guest display has no handset flip/orientation transitions.
        // Retain the subscription; no device-change events are fabricated.
        if cpu.r[2] == 0x0100105a && (cpu.r[1] == package.classID || cpu.r[1] == 0) {
          deviceNotificationMasks[cpu.r[1]] = cpu.r[3]; cpu.r[0] = 0
        } else { cpu.r[0] = 3 }
        cpu.r[0] = 0
      case 0x80:
        let mime = cpu.r[2] == 0 ? "" : try memory.string(cpu.r[2]).lowercased()
        switch cpu.r[1] {
        case 0, 0x0100_4000: // HTYPE_VIEWER / AEECLSID_VIEW, original AEEShell.h.
          switch mime {
          case "image/bmp", "image/x-ms-bmp": cpu.r[0] = 0x0100_4001
          case "image/png": cpu.r[0] = 0x0100_4004
          case "image/jpeg": cpu.r[0] = 0x0100_4005
          default: cpu.r[0] = 0
          }
        case 0x0100_5500:
          switch mime {
          case "audio/wav": cpu.r[0] = 0x0100_550a
          case "audio/mid", "audio/midi": cpu.r[0] = 0x0100_5501
          case "audio/mp3", "audio/mpeg": cpu.r[0] = 0x0100_5502
          default: cpu.r[0] = 0
          }
        default: cpu.r[0] = 0
        }
      case 0xb0:
        // IShell.GetDeviceInfoEx: item 41 is an AECHAR model name.
        // Unknown capabilities are explicitly unsupported; no fabricated success.
        let item = cpu.r[1]
        let buffer = cpu.r[2]
        let sizePointer = cpu.r[3]
        guard sizePointer != 0 else {
          cpu.r[0] = 14  // EBADPARM
          break
        }
        let capacity = Int(Int32(bitPattern: try memory.read32(sizePointer)))
        guard buffer == 0 || capacity >= 0 else {
          cpu.r[0] = 14
          break
        }
        guard item == 41 else {
          cpu.r[0] = 20  // EUNSUPPORTED
          break
        }
        let value = "Zeebo\0".data(using: .utf16LittleEndian)!
        if buffer != 0 {
          try memory.write(buffer, data: Data(value.prefix(min(capacity, value.count))))
        }
        try memory.write32(sizePointer, UInt32(value.count))
        cpu.r[0] = 0
      case 0xb4:
        // GetClassItemID: a stable local module identifier, not a store receipt ID.
        // Only the loaded package class is registered as a dynamic module here.
        cpu.r[0] = cpu.r[1] == package.classID ? package.classID : 0
      case 0xac:
        let source = cpu.r[1]
        let sizePointer = cpu.r[2]
        let out = try argument(4)
        let count = source == 0 ? 0 : Int(try memory.read32(sizePointer))
        let bytes = source == 0 ? Data() : try memory.data(source, count: min(count, 12))
        var mime: String?
        if bytes.starts(with: Data("MThd".utf8)) {
          mime = "audio/mid"
        } else if bytes.count >= 12, bytes.starts(with: Data("RIFF".utf8)),
          bytes.suffix(4) == Data("WAVE".utf8)
        {
          mime = "audio/wav"
        } else if BREWMedia.hasMP3Prefix(bytes) {
          mime = "audio/mp3"
        } else {
          mime = nil
        }
        if mime == nil && cpu.r[3] != 0 {
          let name = try memory.string(cpu.r[3]).lowercased()
          if name.hasSuffix(".mid") || name.hasSuffix(".midi") { mime = "audio/mid" }
          if name.hasSuffix(".wav") { mime = "audio/wav" }
          if name.hasSuffix(".mp3") { mime = "audio/mp3" }
        }
        if let mime {
          guard out != 0 else {
            cpu.r[0] = 14
            break
          }
          try memory.write32(out, guestString(mime))
          cpu.r[0] = 0
        } else {
          if out != 0 { try memory.write32(out, 0) }
          if count < 12 && sizePointer != 0 {
            try memory.write32(sizePointer, UInt32(12 - count))
            cpu.r[0] = 35
          } else {
            cpu.r[0] = 34
          }
        }
      case 0: cpu.r[0] = 2
      case 4: cpu.r[0] = 1
      case 8:
        let object: UInt32
        switch cpu.r[1] {
        case 0x0100_1001, 0x0101_27d4:
          object = defaultDisplay ?? display
          if let clone = clonedDisplays[object] { clone.references += 1 }
        case 0x0100_1056: object = try createSound()
        case 0x0100_1027: object = try createConfig()
        case 0x0100_100c: object = try createMemoryStream()
        case 0x0100_1011: object = try createSourceUtility()
        case 0x0100_100f: object = try createLicense()
        case 0x0100_1017: object = try createThread()
        case 0x0100_1002: object = heapObject
        case 0x0100_1003: object = try createFileManager()
        case 0x0100_1014: object = try createUnzipStream()
        case 0x0100_1015: object = try createMD5()
        case 0x0100_1039: object = try createMD5Context()
        case 0x0102_cce1: object = try createCipherFactory()
        case 0x0100_5000: object = try createWeb()
        case 0x0100_102e: object = try createNet()
        case 0x0102_c4e8: object = try createSQL()
        case 0x0102_8e51: object = try createRootForm()
        case 0x0102_8e47: object = try createRootForm(isRoot: false)
        case 0x0102_8e19: object = try createImageWidget()
        case 0x0102_8e2a: object = try createStaticWidget()
        case 0x0102_8e1b: object = try createListWidget()
        case 0x0102_8e36: object = try createViewportWidget()
        case 0x0102_8e26: object = try createScrollbarWidget()
        case 0x0102_8e14: object = try createDrawDecorator()
        case 0x0102_8e05: object = try createBorderWidget()
        case 0x0102_f67c: object = try createStandardFont()
        case 0x0102_8e3f: object = try createXYContainer()
        case 0x0102_8e3c: object = try createValueModel()
        case 0x0102_8e35: object = try createVectorModel()
        case 0x0101_1810: object = try createCallManager()
        case 0x0100_110a: object = try createStaticControl()
        case 0x0100_3101: object = try createMenuControl()
        case 0x0100_3109: object = try createTextControl()
        case 0x0100_2001: object = graphics
        case 0x0103_0766, 0x0102_6e23: object = try createImageDecoder()
        case 0x0102_fd92, 0x0102_6e22: object = try createImageDecoder(format: .jpeg)
        case 0x0100_4001: object = try createWindowsBMPImage()
        case 0x0100_4004: object = try createPNGImage()
        case 0x0100_4005, 0x0102_fd93: object = try createJPEGImage()
        case 0x0101_4bc3: object = glObject
        case 0x0101_4bc4: object = eglObject
        case 0x0103_d8ec: object = qeglObject
        case 0x0106_c411: object = hidObject
        case 0x0104_1207: object = signalFactory
        case 0x0100_5501, 0x0100_5502, 0x0100_5505, 0x0100_550a, 0x0100_5511, 0x0104_0046:
          object = try createMedia(classID: cpu.r[1])
        case 0x0100_550d: object = try createMediaUtility()
        default:
          if let result = try instantiateBundledClass(cpu.r[1], output: cpu.r[2]) {
            cpu.r[0] = result
            cpu.branch(cpu.r[14])
            return true
          }
          log.append("Class unavailable: " + cpu.r[1].hex)
          try memory.write32(cpu.r[2], 0)
          cpu.r[0] = 3
          cpu.branch(cpu.r[14])
          return true
        }
        try memory.write32(cpu.r[2], object)
        cpu.r[0] = object == 0 ? 2 : 0
      case 0x2c:
        timers.removeAll { $0.callback == cpu.r[2] && $0.context == cpu.r[3] }
        let delay = UInt32(max(0, Int32(bitPattern: cpu.r[1])))
        if cpu.r[2] == cpu.r[3] && cpu.r[2] != 0 {
          try scheduleGuestCallback(cpu.r[2], delay: delay)
        } else {
          scheduleCallback(delay: delay, callback: cpu.r[2], context: cpu.r[3])
        }
        cpu.r[0] = 0
      case 0x30:
        timers.removeAll { (cpu.r[1] == 0 || $0.callback == cpu.r[1]) && $0.context == cpu.r[2] }
        cpu.r[0] = 0
      case 0x34:
        // Query only; an overdue callback remains queued until pumpTimers.
        let now = timerMilliseconds
        if let timer = timers.first(where: { $0.callback == cpu.r[1] && $0.context == cpu.r[2] }),
          timer.deadline > now {
          cpu.r[0] = UInt32(clamping: timer.deadline - now)
        } else { cpu.r[0] = 0 }
      case 0x10:
        try memory.write16(cpu.r[1], 640)
        try memory.write16(cpu.r[1] + 2, 480)
        try memory.write16(cpu.r[1] + 14, 16)
        try memory.write32(cpu.r[1] + 24, 64 * 1024 * 1024)
        if let language = guestSystemLanguage { try memory.write32(cpu.r[1] + 40, language) }
        cpu.r[0] = 0
      default: throw EmulationError.hle(name, cpu.r[14])
      }
    } else if api == 0xf002_0000 {
      let handle = cpu.r[0]
      let context = clonedDisplays[handle]
      let previous = context == nil ? nil : captureDisplayContext()
      if let context { applyDisplayContext(context) }
      defer {
        if let context, let previous {
          context.destination = displayDestination; context.clip = displayClip
          context.settings = displaySettings()
          applyDisplayContext(previous)
        }
      }
      switch offset {
      case 0:
        if let context { context.references += 1; cpu.r[0] = context.references }
        else { cpu.r[0] = 2 }
      case 4: cpu.r[0] = try releaseDisplay(handle)
      case 0x50:
        let out = cpu.r[1]
        guard out != 0 else { cpu.r[0] = 14; break }
        _ = try memory.region(out, 4)
        let clone = try allocate(4)
        if clone != 0 {
          try memory.write32(clone, memory.read32(display))
          try retainBitmap(displayDestination)
          clonedDisplays[clone] = captureDisplayContext()
        }
        try memory.write32(out, clone); cpu.r[0] = clone == 0 ? 2 : 0
      case 0x54:
        if handle != (defaultDisplay ?? display) {
          if let context { context.references += 1 }
          _ = try releaseDisplay(defaultDisplay ?? display)
          defaultDisplay = handle
        }
        cpu.r[0] = 0
      case 0x58: cpu.r[0] = 1
      case 8: try displayFontMetrics()
      case 0x0c: try displayMeasureText()
      case 0x1c:
        if displayDestination == bitmap || displayDestination == dib { try publishFrame() }
        cpu.r[0] = 0
      case 0x24:
        // IDisplay.Backlight addresses a handset light, absent from our TV-style
        // output. Accept the request without changing the Mac's display brightness
        // or altering guest framebuffer pixels.
        cpu.r[0] = 0
      case 0x18:
        let result = try bitmapBlit(destination: displayDestination, source: argument(5),
          x: Int(Int32(bitPattern: cpu.r[1])), y: Int(Int32(bitPattern: cpu.r[2])),
          width: Int(Int32(bitPattern: cpu.r[3])), height: Int(Int32(bitPattern: argument(4))),
          sourceX: Int(Int32(bitPattern: argument(6))), sourceY: Int(Int32(bitPattern: argument(7))),
          rop: argument(8), clip: currentDisplayClip())
        guard result == 0 else { throw EmulationError.unsupported("IDisplay.BitBlt format/raster operation") }
        cpu.r[0] = 0
      case 0x38:
        let next = cpu.r[1] == 0 ? bitmap : cpu.r[1]
        try retainBitmap(next)
        let previous = displayDestination
        displayDestination = next
        displayClip = nil
        try releaseBitmap(previous)
        cpu.r[0] = 0
      case 0x3c:
        let destination = displayDestination
        try retainBitmap(destination)
        cpu.r[0] = destination
      case 0x10:
        try drawText()
        cpu.r[0] = 0
      case 0x14:
        try drawRectangle(cpu.r[1], frameColor: cpu.r[2], fillColor: cpu.r[3],
          flags: try argument(4))
        cpu.r[0] = 0
      case 0x28:
        let slot = 0x2800 + cpu.r[1]
        let old = graphicsState[slot, default: 0]
        graphicsState[slot] = cpu.r[2]
        cpu.r[0] = old
      case 0x40:
        try memory.write32(cpu.r[1], bitmap)
        cpu.r[0] = 0
      case 0x44:
        let key = 0x4400 + cpu.r[1]
        let previous = graphicsState[0x4400 + cpu.r[1], default: 0]
        graphicsState[key] = cpu.r[2]
        cpu.r[0] = previous
      case 0x48:
        if cpu.r[1] == 0 { displayClip = nil }
        else {
          let p = cpu.r[1]
          displayClip = try SIMD4((0..<4).map {
            Int(Int16(truncatingIfNeeded: try memory.read16(p + UInt32($0 * 2))))
          })
          displayClip = try currentDisplayClip()
        }
        cpu.r[0] = 0
      case 0x4c:
        let p = cpu.r[1]
        _ = try memory.region(p, 8)
        let clip = try currentDisplayClip()
        for i in 0..<4 { try memory.write16(p + UInt32(i * 2), UInt32(truncatingIfNeeded: clip[i])) }
        cpu.r[0] = 0
      default: throw EmulationError.hle(name, cpu.r[14])
      }
    } else if api == 0xf004_0000 {
      try dispatchGraphics(offset)
    } else if api == 0xf005_0000 {
      switch offset {
      case 0: cpu.r[0] = 2
      case 4: cpu.r[0] = 1
      case 0x30:
        if cpu.r[2] != 12 {
          cpu.r[0] = 20  // AEE_EUNSUPPORTED: unrecognized AEEBitmapInfo version/size.
        } else if cpu.r[1] == 0 {
          cpu.r[0] = 14
        } else {
          var info = Data()
          for value: UInt32 in [640, 480, 16] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { info.append(contentsOf: $0) }
          }
          try memory.write(cpu.r[1], data: info)
          cpu.r[0] = 0
        }
      case 8:
        if cpu.r[1] == 0x0100_1029 {
          let destination = cpu.r[0]
          cpu.r[0] = try queryBitmapTransform(destination, output: cpu.r[2])
        } else if cpu.r[1] == 0x0100_1045 {
          try memory.write32(cpu.r[2], dib)
          cpu.r[0] = 0
        } else {
          try memory.write32(cpu.r[2], 0)
          cpu.r[0] = 1
        }
      default:
        if try !dispatchBitmapOperation(offset) { throw EmulationError.hle(name, cpu.r[14]) }
      }
    } else if api == 0xf006_0000 {
      let handle = cpu.r[0]
      guard let manager = fileManagers[handle] else {
        throw EmulationError.invalid("Invalid file manager")
      }
      fileError = manager.lastError
      defer { manager.lastError = fileError }
      switch offset {
      case 0:
        manager.references &+= 1
        cpu.r[0] = manager.references
      case 4:
        manager.references -= 1
        cpu.r[0] = manager.references
        if manager.references == 0 {
          fileManagers.removeValue(forKey: handle)
          if handle != fileManager { try free(handle) }
        }
      case 0x0c:
        guard cpu.r[1] != 0 else {
          fileError = 0x103
          cpu.r[0] = 1
          break
        }
        let raw = try memory.string(cpu.r[1])
        guard let path = try? filePath(raw, allowRoot: true) else {
          fileError = 0x103
          cpu.r[0] = 1
          break
        }
        try getFileInfo(path, output: cpu.r[2])
      case 0x28: try initializeFileEnumeration(manager)
      case 0x2c: try nextFileInfo(manager)
      case 0x30: try renameFile()
      case 0x10, 0x14, 0x18:
        try changeFileTree(offset)
      case 0x1c:
        guard cpu.r[1] != 0 else {
          fileError = 0x103
          cpu.r[0] = 1
          break
        }
        let raw = try memory.string(cpu.r[1])
        guard let path = try? filePath(raw, allowRoot: true) else {
          log.append("File path could not be resolved: " + raw.debugDescription)
          fileError = 0x103
          cpu.r[0] = 1
          break
        }
        let exists = fileKind(path) != nil
        fileError = exists ? 0 : 0x101
        cpu.r[0] = exists ? 0 : 1
      case 0x24: cpu.r[0] = fileError
      case 0x20:
        cpu.r[0] = try fileSystemFree(total: cpu.r[1])
      case 8:
        guard cpu.r[1] != 0 else {
          fileError = 0x103
          cpu.r[0] = 0
          break
        }
        let raw = try memory.string(cpu.r[1])
        guard let path = try? filePath(raw) else {
          log.append("File path could not be resolved: " + raw.debugDescription)
          fileError = 0x103
          cpu.r[0] = 0
          break
        }
        let mode = cpu.r[2]
        log.append("OpenFile: \(path), mode \(mode)")
        guard fileKind(path) != .directory else {
          fileError = mode & 4 != 0 ? 0x100 : 0x10a
          cpu.r[0] = 0
          break
        }
        var content: Data?
        if let saved = savedFiles[path] {
          log.append("Read from save game: \(path), \(saved.count) bytes")
        }
        if mode & 4 != 0 {
          guard fileKind(path) == nil else {
            fileError = 0x100  // EFILEEXISTS, per AEEFile.h create semantics.
            cpu.r[0] = 0
            break
          }
          guard fileKind(GameSaveStore.parent(path)) == .directory else {
            fileError = 0x109
            cpu.r[0] = 0
            break
          }
          content = Data()
          do { try saveFile(path, data: Data()) } catch {
            fileError = fileStorageError(error)
            cpu.r[0] = 0
            break
          }
        } else {
          content = try fileContents(path)
        }
        if let content {
          let handle = try allocate(16)
          guard handle != 0 else {
            cpu.r[0] = 0
            cpu.branch(cpu.r[14])
            return true
          }
          try memory.write32(handle, hleAddress(0xb000))
          for i in 0..<32 {
            try memory.write32(hleAddress(0xb000) + UInt32(i * 4), 0xf007_0000 + UInt32(i * 4))
          }
          files[handle] = OpenFile(
            name: path, data: content, position: mode & 8 != 0 ? content.count : 0,
            writable: mode & 14 != 0, manager: manager)
          cpu.r[0] = handle
          fileError = 0
        } else {
          cpu.r[0] = 0
          fileError = 0x101
        }
      default: throw EmulationError.hle(name, cpu.r[14])
      }
    } else if api == 0xf007_0000 {
      let handle = cpu.r[0]
      guard var file = files[handle] else {
        throw EmulationError.invalid("Invalid guest file handle")
      }
      fileError = file.manager?.lastError ?? 0
      defer { file.manager?.lastError = fileError }
      if let latest = savedFiles[file.name] { file.data = latest }
      switch offset {
      case 0:
        file.references &+= 1
        files[handle] = file
        cpu.r[0] = file.references
      case 4:
        file.references -= 1
        if file.references == 0 { files.removeValue(forKey: handle) } else { files[handle] = file }
        cpu.r[0] = file.references
      case 0x0c:
        let start = min(file.position, file.data.count)
        let n = min(Int(cpu.r[2]), file.data.count - start)
        try memory.write(cpu.r[1], data: file.data.subdata(in: start..<(start + n)))
        file.position += n
        files[handle] = file
        cpu.r[0] = UInt32(n)
      case 0x14:
        guard file.writable else {
          cpu.r[0] = UInt32.max
          break
        }
        let count = Int(cpu.r[2])
        let end = file.position + Int(cpu.r[2])
        guard end <= 16 * 1024 * 1024 else {
          cpu.r[0] = UInt32.max
          break
        }
        let bytes = try memory.data(cpu.r[1], count: count)
        if end > file.data.count {
          file.data.append(Data(repeating: 0, count: end - file.data.count))
        }
        file.data.replaceSubrange(file.position..<end, with: bytes)
        file.position = end
        do { try saveFile(file.name, data: file.data) } catch {
          fileError = fileStorageError(error)
          cpu.r[0] = UInt32.max
          break
        }
        files[handle] = file
        cpu.r[0] = UInt32(count)
      case 0x18:
        try getFileInfo(file.name, output: cpu.r[1])
      case 0x24:
        try getOpenFileInfoEx(file.name, size: file.data.count, output: cpu.r[1])
      case 0x20:
        // IFile.Truncate reduces a writable file and moves this handle to EOF.
        // Publish neither the shortened contents nor the new cursor until the
        // save overlay has committed successfully; other open handles refresh
        // their contents from that overlay without changing their own cursors.
        let length = Int(cpu.r[1])
        guard file.writable else {
          fileError = 0x10a; cpu.r[0] = 1; break  // EINVALIDOPERATION
        }
        guard length <= file.data.count else {
          fileError = 0x104; cpu.r[0] = 1; break  // EBADSEEKPOS; not file extension.
        }
        let shortened = Data(file.data.prefix(length))
        do { try saveFile(file.name, data: shortened) } catch {
          fileError = fileStorageError(error); cpu.r[0] = 1; break
        }
        file.data = shortened; file.position = length
        files[handle] = file
        fileError = 0; cpu.r[0] = 0
      case 0x1c:
        let origin = cpu.r[1]
        let offset = Int(Int32(bitPattern: cpu.r[2]))
        if origin == 2 && offset == 0 {
          // Tell remains valid when another handle has shortened the file past
          // this handle's independent cursor. It does not seek or extend data.
          files[handle] = file
          cpu.r[0] = UInt32(file.position)
          break
        }
        let base = origin == 0 ? 0 : origin == 2 ? file.position : file.data.count
        let position = base + offset
        if origin > 2 || position < 0 || (file.writable && position > GameSaveStore.maximumFileSize)
          || (position > file.data.count && !file.writable)
        {
          cpu.r[0] = 1
        } else {
          if position > file.data.count {
            file.data.append(Data(count: position - file.data.count))
            do { try saveFile(file.name, data: file.data) } catch {
              fileError = fileStorageError(error)
              cpu.r[0] = 1
              break
            }
          }
          file.position = position
          files[handle] = file
          cpu.r[0] = 0
        }
      default: throw EmulationError.hle(name, cpu.r[14])
      }
    } else if api == 0xf008_0000 {
      try dispatchUnzip(offset)
    } else if api == 0xf009_0000 {
      try dispatchGL(offset)
    } else if api == 0xf00a_0000 {
      try dispatchEGL(offset)
    } else if api == 0xf00b_0000 {
      try dispatchHID(offset)
    } else if api == 0xf00e_0000 {
      try dispatchHIDDevice(offset)
    } else if api == 0xf00c_0000 || api == 0xf00d_0000 {
      try dispatchSignal(api: api, offset: offset)
    } else if api == 0xf00f_0000 || api == 0xf010_0000 {
      try dispatchQGraphics(egl: api == 0xf00f_0000, offset: offset)
    } else if api == 0xf011_0000 {
      try dispatchMedia(offset)
    } else if api == 0xf012_0000 {
      try dispatchThread(offset)
    } else if api == 0xf013_0000 {
      try dispatchSurfaceManip(offset)
    } else if api == 0xf014_0000 {
      try dispatchSurfaceScale(offset)
    } else if api == 0xf015_0000 || api == 0xf016_0000 {
      try dispatchImageDecoder(offset, feeding: api == 0xf016_0000)
    } else if api == 0xf017_0000 {
      try dispatchImageBitmap(offset)
    } else if api == 0xf018_0000 {
      try dispatchImageViewer(offset)
    } else if api == 0xf019_0000 {
      try dispatchMediaUtility(offset)
    } else if api == 0xf01b_0000 {
      try dispatchSound(offset)
    } else if api == 0xf01a_0000 {
      try dispatchMemoryStream(offset)
    } else if api == 0xf01c_0000 {
      try dispatchLicense(offset)
    } else if api == 0xf01d_0000 || api == 0xf01e_0000 {
      try dispatchDrawTexture(offset, qualcomm: api == 0xf01d_0000)
    } else if api == 0xf01f_0000 {
      try dispatchImageonGraphics(offset)
    } else if api == 0xf020_0000 {
      try dispatchBitmapTransform(offset)
    } else if api == 0xf021_0000 {
      try dispatchHash(offset)
    } else if api == 0xf022_0000 {
      try dispatchCipherFactory(offset)
    } else if api == 0xf023_0000 {
      try dispatchCipher(offset)
    } else if api == 0xf024_0000 {
      try dispatchWeb(offset)
    } else if api == 0xf027_0000 {
      try dispatchNet(offset)
    } else if api == 0xf028_0000 {
      try dispatchSQL(offset)
    } else if api == 0xf029_0000 {
      try dispatchRootForm(offset)
    } else if api == 0xf02c_0000 {
      try dispatchFormWidget(offset)
    } else if api == 0xf02d_0000 {
      try dispatchValueModel(offset)
    } else if api == 0xf02e_0000 {
      try dispatchCallManager(offset)
    } else if api == 0xf02f_0000 {
      try dispatchVectorModel(offset)
    } else if api == 0xf030_0000 {
      try dispatchInterfaceModel(offset)
    } else if api == 0xf031_0000 {
      try dispatchXYContainer(offset)
    } else if api == 0xf032_0000 {
      try dispatchFormCanvas(offset)
    } else if api == 0xf033_0000 {
      try dispatchViewportContainer(offset)
    } else if api == 0xf034_0000 {
      try dispatchFont(offset)
    } else if api == 0xf035_0000 {
      try dispatchConfig(offset)
    } else if api == 0xf036_0000 {
      try dispatchSourceUtility(offset)
    } else if api == 0xf037_0000 {
      try dispatchMemorySource(offset)
    } else if api == 0xf02a_0000 {
      try dispatchStaticControl(offset)
    } else if api == 0xf02b_0000 {
      try dispatchMenuControl(offset)
    } else if api == 0xf026_0000 {
      try dispatchHashContext(offset)
    } else if api == 0xf025_0000 {
      try dispatchTextControl(offset)
    } else if api == 0xf003_0000 {
      switch offset {
      case 0: cpu.r[0] = 2
      case 4: cpu.r[0] = 1
      case 8: cpu.r[0] = try allocate(cpu.r[1])
      case 0x0c: cpu.r[0] = try reallocate(cpu.r[1], cpu.r[2])
      case 0x10: try free(cpu.r[1]); cpu.r[0] = 0
      case 0x14:
        cpu.r[0] = try duplicateWideString(cpu.r[1])
      case 0x18: cpu.r[0] = cpu.r[1] <= 0x0500_0000 - heap ? 1 : 0
      case 0x1c: cpu.r[0] = UInt32(allocations.values.reduce(0, +))
      default: throw EmulationError.hle(name, cpu.r[14])
      }
    } else {
      throw EmulationError.hle(name, cpu.r[14])
    }
    cpu.branch(cpu.r[14])
    return true
  }
  // Supplied AEEShell.h: NULL or a short GetPrefs buffer returns the record
  // size. Failure leaves the caller's defaults intact. Class zero is this app.
  func appPreferences(write: Bool) throws {
    let classID = cpu.r[1] == 0 ? package.classID : cpu.r[1]
    let version = UInt16(truncatingIfNeeded: cpu.r[2])
    let buffer = cpu.r[3]
    let size = Int(UInt16(truncatingIfNeeded: try argument(4)))
    if write {
      guard buffer != 0, size > 0 else { cpu.r[0] = 14; return }
      let data = try memory.data(buffer, count: size)
      do {
        try preferenceStore.write(classID, version: version, data: data)
        cpu.r[0] = 0
      } catch { cpu.r[0] = 1 }
    } else {
      let record: BREWPreferenceStore.Record?
      do { record = try preferenceStore.read(classID) }
      catch { cpu.r[0] = 1; return }
      guard let record, record.version == version else { cpu.r[0] = 1; return }
      guard buffer != 0, size >= record.data.count else {
        cpu.r[0] = UInt32(record.data.count)
        return
      }
      try memory.write(buffer, data: record.data)
      cpu.r[0] = 0
    }
  }
  // Original OEM AEEConfig.h: IConfig has IBase, GetItem, SetItem, GetModel.
  // Its supported setting belongs to this emulated package, never the host OS.
  var guestSystemLanguage: UInt32? {
    guard let data = savedFiles["zeeswift/system-language"], data.count == 4 else { return nil }
    return try? data.u32(0)
  }
  func createConfig() throws -> UInt32 {
    let handle = try allocate(4), table = hleAddress(0x22100)
    guard handle != 0 else { return 0 }
    for offset in stride(from: UInt32(0), through: 16, by: 4) {
      try memory.write32(table + offset, 0xf0350000 + offset)
    }
    try memory.write32(handle, table); configObjects[handle] = 1
    return handle
  }
  func dispatchConfig(_ offset: UInt32) throws {
    let handle = cpu.r[0]
    guard let refs = configObjects[handle] else { throw EmulationError.invalid("Released IConfig") }
    switch offset {
    case 0: configObjects[handle] = refs + 1; cpu.r[0] = refs + 1
    case 4:
      if refs == 1 { configObjects.removeValue(forKey: handle); try free(handle) }
      else { configObjects[handle] = refs - 1 }
      cpu.r[0] = refs - 1
    case 8, 12:
      guard cpu.r[1] == 63 else { cpu.r[0] = 20; return } // CFGI_LNG, uint32 language code
      guard cpu.r[2] != 0, cpu.r[3] == 4 else { cpu.r[0] = 14; return }
      if offset == 8 { try memory.write32(cpu.r[2], guestSystemLanguage ?? 0) }
      else {
        let value = try memory.data(cpu.r[2], count: 4)
        do { try saveFile("zeeswift/system-language", data: value) }
        catch { cpu.r[0] = 1; return }
        log.append("IConfig.CFGI_LNG = " + (try value.u32(0)).hex)
      }
      cpu.r[0] = 0
    case 16:
      guard cpu.r[1] != 0 else { cpu.r[0] = 14; return }
      try memory.write32(cpu.r[1], 0); cpu.r[0] = 20 // no configuration-change model yet
    default: throw EmulationError.hle("IConfig+" + offset.hex, cpu.r[14])
    }
  }
  func saveFile(_ path: String, data: Data) throws {
    var updated = savedFiles
    updated[path] = data
    guard data.count <= GameSaveStore.maximumFileSize,
      updated.count <= 1024,
      updated.values.reduce(0, { $0 + $1.count }) <= GameSaveStore.capacity
    else { throw EmulationError.invalid("Save-game storage limit") }
    try commitFiles(
      updated, directories: savedDirectories.union(GameSaveStore.parents(of: updated.keys)),
      removed: removedPaths)
    log.append(
      "File saved: \(path), \(data.count) bytes\(saveStore == nil ? " (session)" : " (persistent)")"
    )
  }
  func drawRectangle(_ rectangle: UInt32, frameColor: UInt32, fillColor: UInt32,
    flags: UInt32) throws
  {
    let layout = try bitmapLayout(displayDestination)
    let clip = try currentDisplayClip()
    var x = 0
    var y = 0
    var width = layout.width
    var height = layout.height
    if rectangle != 0 {
      x = Int(Int16(truncatingIfNeeded: try memory.read16(rectangle)))
      y = Int(Int16(truncatingIfNeeded: try memory.read16(rectangle + 2)))
      width = Int(Int16(truncatingIfNeeded: try memory.read16(rectangle + 4)))
      height = Int(Int16(truncatingIfNeeded: try memory.read16(rectangle + 6)))
    }
    guard width > 0, height > 0 else { return }
    let left = max(clip.x, x)
    let right = min(clip.x + clip.z, x + width)
    let top = max(clip.y, y)
    let bottom = min(clip.y + clip.w, y + height)
    guard right > left, bottom > top else { return }

    // IDisplay.DrawRect uses independent frame/fill bits. Several games draw
    // sprites or text first and then issue a frame-only call. Treating that call
    // as a solid fill erases everything inside the rectangle.
    let drawsFrame = flags & 1 != 0
    let drawsFill = flags & 2 != 0
    guard drawsFrame || drawsFill else { return }
    let framePixel = drawsFrame ? try bitmapNative(frameColor, layout) : 0
    let fillPixel = drawsFill ? try bitmapNative(fillColor, layout) : 0
    for row in top..<bottom {
      for col in left..<right {
        let edge = col == x || col == x + width - 1 || row == y || row == y + height - 1
        if drawsFrame && edge {
          try bitmapWritePixel(layout, col, row, framePixel)
        } else if drawsFill {
          try bitmapWritePixel(layout, col, row, fillPixel)
        }
      }
    }
  }
  func publishFrame() throws {
    // The fixed RGB565 framebuffer belongs to the guest worker. Validate its
    // complete range once, then read it without 307,200 repeated region lookups.
    let region = try memory.region(framebuffer, 640 * 480 * 2)
    let source = region.bytes.advanced(by: Int(framebuffer - region.base))
    var output = Data(count: 640 * 480 * 4)
    output.withUnsafeMutableBytes { bytes in
      let p = bytes.bindMemory(to: UInt32.self)
      for i in 0..<(640 * 480) {
        let value = UInt32(source.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self).littleEndian)
        let r = (value >> 11) & 31
        let g = (value >> 5) & 63
        let b = value & 31
        p[i] =
          0xff00_0000 | (((r << 3) | (r >> 2)) << 16) | (((g << 2) | (g >> 4)) << 8) | (b << 3)
          | (b >> 2)
      }
    }
    frames.publish(output, session: frameSession)
    guestFrames &+= 1
  }
  private func formatGuest(_ format: String, arguments: UInt32, byteStrings: Bool = false) throws
    -> String
  {
    var index = arguments
    return try formatGuest(format, byteStrings: byteStrings) {
      defer { index &+= 4 }
      return try self.memory.read32(index)
    }
  }
  private func formatWideGuestCall() throws {
    let destination = cpu.r[0], capacity = Int(Int32(bitPattern: cpu.r[1])), pointer = cpu.r[2]
    guard capacity >= 0 else { throw EmulationError.invalid("WSPRINTF length") }
    guard capacity >= 2 else { return }
    var units: [UInt16] = []
    for i in 0..<65536 {
      let unit = UInt16(try memory.read16(pointer &+ UInt32(i * 2)))
      if unit == 0 { break }
      units.append(unit)
    }
    guard units.count < 65536 else { throw EmulationError.invalid("WSPRINTF format without terminator") }
    let format = String(decoding: units, as: UTF16.self)
    // Original WSPRINTF is void and does no processing if a float format occurs.
    if hasFloatingFormat(format) { return }
    var index = 3
    let output = try formatGuest(format, byteStrings: true, wideOutput: true) {
      defer { index += 1 }
      return try self.argument(index)
    }
    var bytes = Data()
    for unit in output.utf16.prefix(capacity / 2 - 1) {
      bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(unit >> 8))
    }
    bytes.append(contentsOf: [0, 0])
    try memory.write(destination, data: bytes)
  }
  private func formatGuestCall(offset: UInt32) throws {
    let bounded = offset == 0x140 || offset == 0x144
    let destination = cpu.r[0]
    let capacity = bounded ? cpu.r[1] : 0
    let format = try memory.byteString(cpu.r[bounded ? 2 : 1])
    // AEEStdLib specifies -1 with no processing if any floating conversion is
    // present. Check before even dereferencing a va_list or an earlier %s.
    if hasFloatingFormat(format) {
      cpu.r[0] = UInt32.max
      return
    }
    let firstArgument = bounded ? 3 : 2
    let output: String
    if offset == 0x13c || offset == 0x140 {
      output = try formatGuest(
        format, arguments: memory.read32(cpu.r[firstArgument]), byteStrings: true)
    } else {
      // Consume only requested arguments, including the r3 -> stack boundary.
      var index = firstArgument
      output = try formatGuest(format, byteStrings: true) {
        defer { index += 1 }
        return try self.argument(index)
      }
    }
    let bytes = Data(output.unicodeScalars.map { UInt8($0.value) })
    if bounded {
      // BREW counts the terminator, unlike ISO C snprintf's would-have-written length.
      if destination == 0 {
        cpu.r[0] = UInt32(bytes.count + 1)
      } else if capacity == 0 {
        cpu.r[0] = 0
      } else {
        guard capacity <= 0x7fff_ffff else { throw EmulationError.invalid("SNPRINTF length") }
        let result = Data(bytes.prefix(Int(capacity) - 1)) + Data([0])
        try memory.write(destination, data: result)
        cpu.r[0] = UInt32(result.count)
      }
    } else {
      try memory.write(destination, data: bytes + Data([0]))
      cpu.r[0] = UInt32(bytes.count)
    }
  }
  private func hasFloatingFormat(_ format: String) -> Bool {
    let chars = Array(format)
    var i = 0
    while i < chars.count {
      guard chars[i] == "%" else { i += 1; continue }
      i += 1
      if i < chars.count && chars[i] == "%" { i += 1; continue }
      while i < chars.count && "-+ #0".contains(chars[i]) { i += 1 }
      if i < chars.count && chars[i] == "*" { i += 1 }
      else { while i < chars.count && chars[i].isNumber { i += 1 } }
      if i < chars.count && chars[i] == "." {
        i += 1
        if i < chars.count && chars[i] == "*" { i += 1 }
        else { while i < chars.count && chars[i].isNumber { i += 1 } }
      }
      if i + 2 < chars.count && String(chars[i...i + 2]) == "I64" { i += 3 }
      else if i < chars.count && "hlL".contains(chars[i]) { i += 1 }
      if i < chars.count {
        if "fFeEgG".contains(chars[i]) { return true }
        i += 1
      }
    }
    return false
  }
  private func formatGuest(_ format: String, byteStrings: Bool, wideOutput: Bool = false,
    next: () throws -> UInt32) throws
    -> String
  {
    let chars = Array(format)
    var out = ""
    var cursor = 0
    while cursor < chars.count {
      guard chars[cursor] == "%" else {
        out.append(chars[cursor])
        cursor += 1
        continue
      }
      cursor += 1
      guard cursor < chars.count else { throw EmulationError.invalid("Guest format") }
      if chars[cursor] == "%" {
        out.append("%")
        cursor += 1
        continue
      }
      var flags = ""
      var width = 0
      var precision: Int?
      while cursor < chars.count && "-+ #0".contains(chars[cursor]) {
        flags.append(chars[cursor])
        cursor += 1
      }
      if cursor < chars.count && chars[cursor] == "*" {
        width = Int(Int32(bitPattern: try next()))
        cursor += 1
      } else {
        while cursor < chars.count, let digit = chars[cursor].wholeNumberValue {
          width = width * 10 + digit
          cursor += 1
          if width > 65536 { throw EmulationError.invalid("Format width") }
        }
      }
      if cursor < chars.count && chars[cursor] == "." {
        cursor += 1
        precision = 0
        if cursor < chars.count && chars[cursor] == "*" {
          precision = Int(Int32(bitPattern: try next()))
          cursor += 1
        } else {
          while cursor < chars.count, let digit = chars[cursor].wholeNumberValue {
            precision = (precision ?? 0) * 10 + digit
            cursor += 1
            if precision! > 65536 { throw EmulationError.invalid("Format precision") }
          }
        }
      }
      var hasModifier = false
      if cursor + 2 < chars.count && String(chars[cursor...cursor + 2]) == "I64" {
        hasModifier = true
        cursor += 3
      } else if cursor < chars.count && "hlL".contains(chars[cursor]) {
        hasModifier = true
        cursor += 1
      }
      guard cursor < chars.count, abs(width) <= 65536 else {
        throw EmulationError.invalid("Guest format")
      }
      if let precision, precision > 65536 { throw EmulationError.invalid("Format precision") }
      let spec = chars[cursor]
      // The original wide helper accepts strings only as unmodified %s.
      // The %c contract consumes an int containing a single-byte character. The existing
      // character conversion is then encoded as AECHAR by formatWideGuestCall.
      guard !wideOutput || "diuxXopsc".contains(spec) else {
        throw EmulationError.unsupported("WSPRINTF format %" + String(spec))
      }
      let value = try next()
      cursor += 1
      var field: String
      switch spec {
      case "S":
        if value == 0 {
          field = "(null)"
          if let precision, precision >= 0 { field = String(field.prefix(precision)) }
        } else {
          // AECHAR is a 16-bit guest unit. Bound reads by precision, including
          // zero, before looking for a terminator. Match WSTRTOSTR's supported
          // single-byte range; do not silently truncate an unknown OEM encoding.
          var scalars = String.UnicodeScalarView()
          let limit = precision.flatMap { $0 >= 0 ? $0 : nil } ?? 65536
          var terminated = false
          for i in 0..<limit {
            let unit = try memory.read16(value &+ UInt32(i * 2))
            if unit == 0 { terminated = true; break }
            guard unit <= 0xff else {
              throw EmulationError.unsupported("Guest format %S character outside Latin-1")
            }
            scalars.append(UnicodeScalar(UInt8(unit)))
          }
          if !terminated && (precision == nil || precision! < 0) {
            throw EmulationError.invalid("Guest format %S without terminator")
          }
          field = String(scalars)
        }
      case "s":
        if wideOutput {
          guard flags.isEmpty, width == 0, precision == nil, !hasModifier else {
            throw EmulationError.unsupported("WSPRINTF %s with format/length modifier")
          }
          if value == 0 { field = "(null)" }
          else {
            var units: [UInt16] = []
            for i in 0..<65536 {
              let unit = UInt16(try memory.read16(value &+ UInt32(i * 2)))
              if unit == 0 { break }
              units.append(unit)
            }
            guard units.count < 65536 else { throw EmulationError.invalid("WSPRINTF %s without terminator") }
            field = String(decoding: units, as: UTF16.self)
          }
        } else if byteStrings, value != 0, let precision, precision >= 0 {
          var scalars = String.UnicodeScalarView()
          for i in 0..<precision {
            let byte = try memory.read8(value &+ UInt32(i))
            if byte == 0 { break }
            scalars.append(UnicodeScalar(UInt8(byte)))
          }
          field = String(scalars)
        } else {
          field =
            value == 0
            ? "(null)" : try byteStrings ? memory.byteString(value) : memory.string(value)
        }
        if let precision, precision >= 0 { field = String(field.prefix(precision)) }
      case "d", "i":
        field = String(Int32(bitPattern: value))
        if value < 0x8000_0000 {
          if flags.contains("+") {
            field = "+" + field
          } else if flags.contains(" ") {
            field = " " + field
          }
        }
      case "u": field = String(value)
      case "x", "X", "p":
        field = String(value, radix: 16, uppercase: spec == "X")
        if spec == "p" || flags.contains("#") && value != 0 {
          field = (spec == "X" ? "0X" : "0x") + field
        }
      case "o": field = String(value, radix: 8)
      case "c": field = String(UnicodeScalar(UInt8(truncatingIfNeeded: value)))
      case "C":
        guard value <= 0xff else {
          throw EmulationError.unsupported("Guest format %C character outside Latin-1")
        }
        field = String(UnicodeScalar(UInt8(value)))
      default: throw EmulationError.unsupported("Guest format %" + String(spec))
      }
      let integer = "diuxXo".contains(spec)
      if integer {
        var prefix = ""
        if field.first == "-" || field.first == "+" || field.first == " " {
          prefix = String(field.removeFirst())
        } else if field.hasPrefix("0x") || field.hasPrefix("0X") {
          prefix = String(field.prefix(2))
          field.removeFirst(2)
        }
        if let precision, precision >= 0 {
          if value == 0 && precision == 0 { field = "" }
          field = String(repeating: "0", count: max(0, precision - field.count)) + field
        }
        if spec == "o" && flags.contains("#") && field.first != "0" { prefix = "0" }
        if flags.contains("0"), !flags.contains("-"), width > 0,
          precision == nil || precision! < 0
        {
          field = String(repeating: "0", count: max(0, width - prefix.count - field.count)) + field
        }
        field = prefix + field
      }
      let padding = max(0, abs(width) - field.count)
      if flags.contains("-") || width < 0 {
        field += String(repeating: " ", count: padding)
      } else if flags.contains("0") && !integer && spec == "p" {
        if field.first == "-" || field.first == "+" {
          let sign = field.removeFirst()
          field = String(sign) + String(repeating: "0", count: padding) + field
        } else {
          field = String(repeating: "0", count: padding) + field
        }
      } else {
        field = String(repeating: " ", count: padding) + field
      }
      out += field
      guard out.utf8.count <= 65536 else { throw EmulationError.invalid("Guest format length") }
    }
    return out
  }
  var report: String {
    let performance = frames.performance()
    let fpsLine = L10n.format("Game FPS: %.1f · Average since start: %.1f · Measurement time: %.2f s · %@",
      performance?.fps ?? 0, performance?.averageFPS ?? 0, performance?.elapsedSeconds ?? 0,
      virtualMilliseconds == nil ? L10n.text("Real time") : L10n.text("synthetic test clock: no comparable game FPS"))
    let diagnostic = debugConsole.isEmpty ? [] : [
      L10n.format("ARM diagnostic output (%lld additional bytes discarded):", discardedDebugBytes),
      String(decoding: debugConsole, as: UTF8.self),
    ]
    return ([
      L10n.format("Phase: %@", L10n.text(phase)),
      L10n.format("MOD: %lld bytes, code: %@..<%@, HLE: %@", package.module.count, Self.base.hex, addressSpace.codeEnd.hex, addressSpace.hleBase.hex),
      L10n.format("ARM/Thumb instructions: %lld", cpu.count),
      L10n.format("Native JIT instructions: %lld", jit.executedInstructions),
      L10n.format("JIT blocks: %lld", jit.compiledBlocks),
      L10n.format("Repeated FREE calls: %lld", repeatedFreeCount),
      L10n.format("Guest frames: %lld", guestFrames), L10n.format("GL draw calls: %lld", gl.draws),
      L10n.format("PC: %@", cpu.pc.hex),
      fpsLine,
      L10n.format("HID position queries: %lld", calls["IHIDDevice+0x00000028", default: 0]),
      L10n.format("Timer calls: %lld", timerInvocationCounts.values.reduce(0, &+)),
      L10n.format("Save-game files: %lld, %lld bytes", savedFiles.count,
        savedFiles.values.reduce(0) { $0 + $1.count }),
    ] + log + diagnostic + cpu.trace).joined(separator: "\n")
  }
}
