#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(MSVCRT)
import MSVCRT
#endif

// MARK: - Swift runtime declarations

@_silgen_name("swift_reflectionMirror_normalizedType")
private func _getNormalizedType<T>(_: T, type: Any.Type) -> Any.Type

@_silgen_name("swift_reflectionMirror_count")
private func _getChildCount<T>(_: T, type: Any.Type) -> Int

private typealias NameFreeFunc = @convention(c) (UnsafePointer<CChar>?) -> Void

@_silgen_name("swift_reflectionMirror_subscript")
private func _getChild<T>(
    of: T,
    type: Any.Type,
    index: Int,
    outName: UnsafeMutablePointer<UnsafePointer<CChar>?>,
    outFreeFunc: UnsafeMutablePointer<NameFreeFunc?>
) -> Any

@_silgen_name("swift_EnumCaseName")
private func _getEnumCaseName<T>(_ value: T) -> UnsafePointer<CChar>?

// Returns 'c' (class), 'e' (enum), 's' (struct), 't' (tuple), or '\0' (none)
@_silgen_name("swift_reflectionMirror_displayStyle")
private func _getDisplayStyle<T>(_: T) -> CChar

@_silgen_name("swift_OpaqueSummary")
private func _opaqueSummary(_ metadata: Any.Type) -> UnsafePointer<CChar>?

private func getChild<T>(of value: T,
                         type: Any.Type,
                         index: Int) -> Mirror.Child {
    var nameC: UnsafePointer<CChar>? = nil
    
    var freeFunc: NameFreeFunc? = nil

    let value = _getChild(of: value,
                          type: type,
                          index: index,
                          outName: &nameC,
                          outFreeFunc: &freeFunc)

    let name = nameC.flatMap(String.init(validatingUTF8:))
    freeFunc?(nameC)

    return (name, value)
}

// MARK: - SuperMirror

/// Like the `Mirror` type from the standard library, but ignores
/// any `CustomReflectable` overrides.
///
/// In addition, allows dynamic memer lookup
@dynamicMemberLookup
public struct SuperMirror<Subject>: CustomReflectable {

    /// Representation of descendant classes that don't override
    /// `customMirror`.
    ///
    /// Note that the effect of this setting goes no deeper than the
    /// nearest descendant class that overrides `customMirror`, which
    /// in turn can determine representation of *its* descendants.
    private enum DefaultDescendantRepresentation {
        /// Generate a default mirror for descendant classes that don't
        /// override `customMirror`.
        ///
        /// This case is the default.
        case generated

        /// Suppress the representation of descendant classes that don't
        /// override `customMirror`.
        ///
        /// This option may be useful at the root of a class cluster, where
        /// implementation details of descendants should generally not be
        /// visible to clients.
        case suppressed
    }

    /// An element of the reflected instance's structure.
    ///
    /// When the `label` component in not `nil`, it may represent the name of a
    /// stored property or an active `enum` case. If you pass strings to the
    /// `descendant(_:_:)` method, labels are used for lookup.
    public typealias Child = Mirror.Child

    public enum DisplayStyle {
        case tuple
        case `struct`
        case `enum`
        case `class`
        case none
    }

    fileprivate let subject: Subject

    fileprivate let subjectType: Any.Type

    fileprivate let children: [Child]

    fileprivate let displayStyle: DisplayStyle

    fileprivate let makeSuperclassMirror: () -> SuperMirror<Any>?

    private let _defaultDescendantRepresentation: DefaultDescendantRepresentation

    public init(_ subject: Subject) {
        self.init(internalReflecting: subject)
    }

    internal init(internalReflecting subject: Subject,
                  subjectType: Any.Type? = nil,
                  customAncestor: SuperMirror<Any>? = nil) {

        self.subject = subject

        let subjectType = subjectType
            ?? _getNormalizedType(subject, type: type(of: subject as Any))

        let childCount = _getChildCount(subject, type: subjectType)
        self.children = (0 ..< childCount).map {
            getChild(of: subject, type: subjectType, index: $0)
        }

        self.makeSuperclassMirror = {
            guard let subjectClass = subjectType as? AnyClass,
                let superclass = _getSuperclass(subjectClass) else {
                    return nil
            }

            // Handle custom ancestors. If we've hit the custom ancestor's subject type,
            // or descendants are suppressed, return it. Otherwise continue reflecting.
            if let customAncestor = customAncestor {
                if superclass == customAncestor.subjectType {
                    return customAncestor
                }
                if customAncestor._defaultDescendantRepresentation == .suppressed {
                    return customAncestor
                }
            }
            return SuperMirror<Any>(internalReflecting: subject,
                                    subjectType: superclass,
                                    customAncestor: customAncestor)
        }

        let rawDisplayStyle = _getDisplayStyle(subject)
        switch UnicodeScalar(Int(rawDisplayStyle)) {
        case "c":
            displayStyle = .class
        case "e":
            displayStyle = .enum
        case "s":
            displayStyle = .struct
        case "t":
            displayStyle = .tuple
        case "\0":
            // This is a metatype, opaque value or something else.
            // They have no children.
            displayStyle = .none
        default:
            fatalError("Unknown raw display style '\(rawDisplayStyle)'")
        }

        self.subjectType = subjectType
        self._defaultDescendantRepresentation = .generated
    }

    public subscript<Value>(
        dynamicMember keyPath: KeyPath<Subject, Value>
    ) -> SuperMirror<Value> {
        return SuperMirror<Value>(subject[keyPath: keyPath])
    }

    public subscript(dynamicMember member: String) -> SuperMirror<Any>? {
        if let index = Int(member) {
            if children.indices.contains(index) {
                return SuperMirror<Any>(children[index].value)
            }
            if let customMirror = (subject as? CustomReflectable)?.customMirror {
                return customMirror.descendant(index).map(SuperMirror<Any>.init)
            }
            return nil
        } else if let child = children.first(where: { $0.label == member }) {
            return SuperMirror<Any>(child.value)
        } else if let customMirror = (subject as? CustomReflectable)?.customMirror {
            return customMirror.descendant(member).map(SuperMirror<Any>.init)
        }

        return nil
    }

    public var customMirror: Mirror {
        return Mirror(reflecting: subject)
    }
}

// MARK: - SuperMirror's Attributes

/// The subject being reflected.
public func subject<Subject>(_ mirror: SuperMirror<Subject>) -> Subject {
    return mirror.subject
}

/// The subject being reflected.
public func subject<Subject>(_ mirror: SuperMirror<Subject>?) -> Subject? {
    return mirror?.subject
}

/// The static type of the subject being reflected.
///
/// This type may differ from the subject's dynamic type when this mirror
/// is the `superclassMirror` of another mirror.
public func subjectType<Subject>(_ mirror: SuperMirror<Subject>) -> Any.Type {
    return mirror.subjectType
}

/// The static type of the subject being reflected.
///
/// This type may differ from the subject's dynamic type when this mirror
/// is the `superclassMirror` of another mirror.
public func subjectType<Subject>(_ mirror: SuperMirror<Subject>?) -> Any.Type? {
    return mirror?.subjectType
}

/// A collection of `Child` elements describing the structure of the
/// reflected subject.
public func children<Subject>(
    _ mirror: SuperMirror<Subject>
) -> [SuperMirror<Subject>.Child] {
    return mirror.children
}

/// A collection of `Child` elements describing the structure of the
/// reflected subject.
public func children<Subject>(
    _ mirror: SuperMirror<Subject>?
) -> [SuperMirror<Subject>.Child]? {
    return mirror?.children
}

/// A suggested display style for the reflected subject.
public func displayStyle<Subject>(
    _ mirror: SuperMirror<Subject>
) -> SuperMirror<Subject>.DisplayStyle {
    return mirror.displayStyle
}

/// A suggested display style for the reflected subject.
public func displayStyle<Subject>(
    _ mirror: SuperMirror<Subject>?
) -> SuperMirror<Subject>.DisplayStyle? {
    return mirror?.displayStyle
}

/// A mirror of the subject's superclass, if one exists.
public func superclassMirror<Subject>(
    _ mirror: SuperMirror<Subject>
) -> SuperMirror<Any>? {
    return mirror.superclassMirror
}

/// A mirror of the subject's superclass, if one exists.
public func superclassMirror<Subject>(
    _ mirror: SuperMirror<Subject>?
) -> SuperMirror<Any>? {
    return mirror?.make
}

// MARK: - Dumping

@discardableResult
public func superdump<Subject>(_ mirror: SuperMirror<Subject>,
                               name: String? = nil,
                               indent: Int = 0,
                               maxDepth: Int = .max,
                               maxItems: Int = .max) -> Subject {
    var stdout = FileStream.standardOutput
    return superdump(mirror,
                     to: &stdout,
                     name: name,
                     indent: indent,
                     maxDepth: maxDepth,
                     maxItems: maxItems)
}

@discardableResult
public func superdump<Subject>(_ value: Subject,
                               name: String? = nil,
                               indent: Int = 0,
                               maxDepth: Int = .max,
                               maxItems: Int = .max) -> Subject {
    var stdout = FileStream.standardOutput
    return superdump(SuperMirror(value),
                     to: &stdout,
                     name: name,
                     indent: indent,
                     maxDepth: maxDepth,
                     maxItems: maxItems)
}

@discardableResult
public func superdump<Subject>(_ mirror: SuperMirror<Subject>?,
                               name: String? = nil,
                               indent: Int = 0,
                               maxDepth: Int = .max,
                               maxItems: Int = .max) -> Subject? {
    var stdout = FileStream.standardOutput
    return superdump(mirror,
                     to: &stdout,
                     name: name,
                     indent: indent,
                     maxDepth: maxItems,
                     maxItems: maxItems)
}

@discardableResult
public func superdump<Subject, TargetStream: TextOutputStream>(
    _ mirror: SuperMirror<Subject>?,
    to target: inout TargetStream,
    name: String? = nil,
    indent: Int = 0,
    maxDepth: Int = .max,
    maxItems: Int = .max
) -> Subject? {
    if let mirror = mirror {
        return superdump(mirror,
                         to: &target,
                         name: name,
                         indent: indent,
                         maxDepth: maxItems,
                         maxItems: maxItems) as Subject
    } else {
        print("nil", to: &target)
        return nil
    }
}

@discardableResult
public func superdump<Subject, TargetStream: TextOutputStream>(
    _ mirror: SuperMirror<Subject>,
    to target: inout TargetStream,
    name: String? = nil,
    indent: Int = 0,
    maxDepth: Int = .max,
    maxItems: Int = .max
) -> Subject {
    var maxItemCounter = maxItems
    var visitedItems = [ObjectIdentifier : Int]()
    target._lock()
    defer { target._unlock() }
    dumpUnlocked(
      mirror,
      to: &target,
      name: name,
      indent: indent,
      maxDepth: maxDepth,
      maxItemCounter: &maxItemCounter,
      visitedItems: &visitedItems)
    return mirror.subject
}

@discardableResult
public func superdump<Subject, TargetStream: TextOutputStream>(
    _ value: Subject,
    to target: inout TargetStream,
    name: String? = nil,
    indent: Int = 0,
    maxDepth: Int = .max,
    maxItems: Int = .max
) -> Subject {
    superdump(SuperMirror(value),
              to: &target,
              name: name,
              indent: indent,
              maxDepth: maxDepth,
              maxItems: maxItems)
}

private func dumpUnlocked<Subject, TargetStream: TextOutputStream>(
    _ mirror: SuperMirror<Subject>,
    to target: inout TargetStream,
    name: String?,
    indent: Int,
    maxDepth: Int,
    maxItemCounter: inout Int,
    visitedItems: inout [ObjectIdentifier : Int]
) {
    guard maxItemCounter > 0 else { return }

    let value = mirror.subject

    maxItemCounter -= 1

    for _ in 0..<indent { target.write(" ") }

    let count = mirror.children.count
    let bullet = count == 0    ? "-"
        : maxDepth <= 0 ? "▹" : "▿"
    target.write(bullet)
    target.write(" ")

    if let name = name {
        target.write(name)
        target.write(": ")
    }
    // This takes the place of the old mirror API's 'summary' property
    dumpPrintUnlocked(value, mirror, &target)

    let id: ObjectIdentifier?
    if type(of: value) is AnyObject.Type {
        // Object is a class (but not an ObjC-bridged struct)
        id = ObjectIdentifier(value as AnyObject)
    } else if let metatypeInstance = value as? Any.Type {
        // Object is a metatype
        id = ObjectIdentifier(metatypeInstance)
    } else {
        id = nil
    }
    if let theId = id {
        if let previous = visitedItems[theId] {
            target.write(" #")
            printUnlocked(previous, &target)
            target.write("\n")
            return
        }
        let identifier = visitedItems.count
        visitedItems[theId] = identifier
        target.write(" #")
        printUnlocked(identifier, &target)
    }

    target.write("\n")

    guard maxDepth > 0 else { return }

    if let superclassMirror = mirror.makeSuperclassMirror() {
        dumpSuperclassUnlocked(
            mirror: superclassMirror,
            to: &target,
            indent: indent + 2,
            maxDepth: maxDepth - 1,
            maxItemCounter: &maxItemCounter,
            visitedItems: &visitedItems)
    }

    var currentIndex = mirror.children.startIndex
    for i in 0..<count {
        if maxItemCounter <= 0 {
            for _ in 0..<(indent+4) {
                printUnlocked(" ", &target)
            }
            let remainder = count - i
            target.write("(")
            printUnlocked(remainder, &target)
            if i > 0 { target.write(" more") }
            if remainder == 1 {
                target.write(" child)\n")
            } else {
                target.write(" children)\n")
            }
            return
        }

        let (name, child) = mirror.children[currentIndex]
        mirror.children.formIndex(after: &currentIndex)
        dumpUnlocked(
            SuperMirror<Any>(child),
            to: &target,
            name: name,
            indent: indent + 2,
            maxDepth: maxDepth - 1,
            maxItemCounter: &maxItemCounter,
            visitedItems: &visitedItems)
    }
}

private func dumpSuperclassUnlocked<TargetStream: TextOutputStream>(
    mirror: SuperMirror<Any>,
    to target: inout TargetStream,
    indent: Int,
    maxDepth: Int,
    maxItemCounter: inout Int,
    visitedItems: inout [ObjectIdentifier: Int]
) {
    guard maxItemCounter > 0 else { return }
    maxItemCounter -= 1

    for _ in 0..<indent { target.write(" ") }

    let count = mirror.children.count
    let bullet = count == 0    ? "-"
        : maxDepth <= 0 ? "▹" : "▿"
    target.write(bullet)
    target.write(" super: ")
    _debugPrint_unlocked(mirror.subjectType, &target)
    target.write("\n")

    guard maxDepth > 0 else { return }

    if let superclassMirror = mirror.superclassMirror {
        dumpSuperclassUnlocked(mirror: superclassMirror,
                               to: &target,
                               indent: indent + 2,
                               maxDepth: maxDepth - 1,
                               maxItemCounter: &maxItemCounter,
                               visitedItems: &visitedItems)
    }

    var currentIndex = mirror.children.startIndex
    for i in 0..<count {
        if maxItemCounter <= 0 {
            for _ in 0..<(indent+4) {
                target.write(" ")
            }
            let remainder = count - i
            target.write("(")
            printUnlocked(remainder, &target)
            if i > 0 { target.write(" more") }
            if remainder == 1 {
                target.write(" child)\n")
            } else {
                target.write(" children)\n")
            }
            return
        }

        let (name, child) = mirror.children[currentIndex]
        mirror.children.formIndex(after: &currentIndex)
        dumpUnlocked(SuperMirror(child),
                     to: &target,
                     name: name,
                     indent: indent + 2,
                     maxDepth: maxDepth - 1,
                     maxItemCounter: &maxItemCounter,
                     visitedItems: &visitedItems)
    }
}

private func printUnlocked<T, TargetStream: TextOutputStream>(
    _ value: T,
    _ target: inout TargetStream
) {
    // Optional has no representation suitable for display; therefore,
    // values of optional type should be printed as a debug
    // string. Check for Optional first, before checking protocol
    // conformance below, because an Optional value is convertible to a
    // protocol if its wrapped type conforms to that protocol.
    if _isOptional(type(of: value)) {
        let debugPrintable = value as! CustomDebugStringConvertible
        debugPrintable.debugDescription.write(to: &target)
        return
    }
    if case let streamableObject as TextOutputStreamable = value {
        streamableObject.write(to: &target)
        return
    }

    if case let printableObject as CustomStringConvertible = value {
        printableObject.description.write(to: &target)
        return
    }

    if case let debugPrintableObject as CustomDebugStringConvertible = value {
        debugPrintableObject.debugDescription.write(to: &target)
        return
    }

    let mirror = SuperMirror(value)
    adHocPrintUnlocked(value, mirror, &target, isDebugPrint: false)
}

internal func adHocPrintUnlocked<Subject, TargetStream: TextOutputStream>(
    _ value: Subject,
    _ mirror: SuperMirror<Subject>,
    _ target: inout TargetStream,
    isDebugPrint: Bool
) {
    func printTypeName(_ type: Any.Type) {
        // Print type names without qualification, unless we're debugPrint'ing.
        target.write(_typeName(type, qualified: isDebugPrint))
    }

    switch mirror.displayStyle {
    case .tuple:
        target.write("(")
        var first = true
        for (label, value) in mirror.children {
            if first {
                first = false
            } else {
                target.write(", ")
            }

            if let label = label {
                if !label.isEmpty && label[label.startIndex] != "." {
                    target.write(label)
                    target.write(": ")
                }
            }

            _debugPrint_unlocked(value, &target)
        }
        target.write(")")
    case .struct:
        printTypeName(mirror.subjectType)
        target.write("(")
        var first = true
        for (label, value) in mirror.children {
            if let label = label {
                if first {
                    first = false
                } else {
                    target.write(", ")
                }
                target.write(label)
                target.write(": ")
                _debugPrint_unlocked(value, &target)
            }
        }
        target.write(")")
    case .enum:
        if let cString = _getEnumCaseName(value),
            let caseName = String(validatingUTF8: cString) {
            // Write the qualified type name in debugPrint.
            if isDebugPrint {
                printTypeName(mirror.subjectType)
                target.write(".")
            }
            target.write(caseName)
        } else {
            // If the case name is garbage, just print the type name.
            printTypeName(mirror.subjectType)
        }
        if let (_, value) = mirror.children.first {
            if SuperMirror(value).displayStyle == .tuple {
                _debugPrint_unlocked(value, &target)
            } else {
                target.write("(")
                _debugPrint_unlocked(value, &target)
                target.write(")")
            }
        }
    case .class:
        target.write(_typeName(mirror.subjectType))
    case .none:
        if let metatypeValue = value as? Any.Type {
            // Metatype
            printTypeName(metatypeValue)
        } else {
            // Fall back to the type or an opaque summary of the kind
            if let cString = _opaqueSummary(mirror.subjectType),
                let opaqueSummary = String(validatingUTF8: cString) {
                target.write(opaqueSummary)
            } else {
                target.write(_typeName(mirror.subjectType, qualified: true))
            }
        }
    }
}

private func dumpPrintUnlocked<Subject, TargetStream: TextOutputStream>(
    _ value: Subject,
    _ mirror: SuperMirror<Subject>,
    _ target: inout TargetStream
) {
    switch mirror.displayStyle {
    case .tuple:
        let count = mirror.children.count
        target.write("tuple ")
        target.write(count == 1 ? "(1 element)" : "(\(count) elements)")
        return
    case .class, .struct, .enum, .none:
        break
    }

    let usesCustomDescription: Bool
    if let debugPrintableObject = value as? CustomDebugStringConvertible {
        debugPrintableObject.debugDescription.write(to: &target)
        target.write(" (")
        usesCustomDescription = true
    } else if let printableObject = value as? CustomStringConvertible {
        printableObject.description.write(to: &target)
        target.write(" (")
        usesCustomDescription = true
    } else if let streamableObject = value as? TextOutputStreamable {
        streamableObject.write(to: &target)
        target.write(" (")
        usesCustomDescription = true
    } else {
        usesCustomDescription = false
    }

    defer {
        if usesCustomDescription {
            target.write(")")
        }
    }

    switch mirror.displayStyle {
    case .class:
        target.write("class ")
    case .struct:
        target.write("struct ")
    case .enum:
        target.write("enum ")
    case .tuple:
        // Already handled
        fatalError("unreachable")
    case .none:
        adHocPrintUnlocked(value, mirror, &target, isDebugPrint: true)
        return
    }

    target.write(_typeName(mirror.subjectType, qualified: true))
}

// MARK: - StdOut

public struct FileStream: TextOutputStream {

#if canImport(Darwin) || canImport(Glibc) || canImport(MSVCRT)
    public static let standardOutput = FileStream(stdout)

    public static let standardError = FileStream(stderr)

    private let file: UnsafeMutablePointer<FILE>

    private init(_ file: UnsafeMutablePointer<FILE>) {
        self.file = file
    }
#else
    public static let standardOutput = FileStream()

    @available(*, unavailable, message: """
    standardError is unavailable on this platform. Use standardOutput instead.
    """)
    public static let standardError = FileStream()

    private init() {}
#endif

    public mutating func write(_ string: String) {
        if string.isEmpty { return }
#if canImport(Darwin) || canImport(Glibc) || canImport(MSVCRT)
        var string = string
        _ = string.withUTF8 { utf8 in
            fwrite(utf8.baseAddress!, 1, utf8.count, file)
        }
#else
        print(string, terminator: "")
#endif
    }

    public mutating func _lock() {
#if canImport(Darwin) || canImport(Glibc)
        flockfile(file)
#elseif canImport(MSVCRT)
        _lock_file(file)
#endif
    }

    public mutating func _unlock() {
#if canImport(Darwin) || canImport(Glibc)
        funlockfile(file)
#elseif canImport(MSVCRT)
        _unlock_file(file)
#endif
    }
}

// MARK: -
