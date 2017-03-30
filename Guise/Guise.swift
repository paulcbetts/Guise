/*
The MIT License (MIT)

Copyright (c) 2016 Gregory Higley (Prosumma)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import Foundation

/**
 `Name.default` is used for the default name of a container or type when one is not specified.
 */
public enum Name {
    /**
     `Name.default` is used for the default name of a container or type when one is not specified.
     */
    case `default`
}

/**
 Generates a hash value for one or more hashable values.
 */
private func hash<H: Hashable>(_ hashables: H...) -> Int {
    // djb2 hash algorithm: http://www.cse.yorku.ca/~oz/hash.html
    // &+ operator handles Int overflow
    return hashables.reduce(5381) { (result, hashable) in ((result << 5) &+ result) &+ hashable.hashValue }
}

infix operator ??= : AssignmentPrecedence

private func ??=<T>(lhs: inout T?, rhs: @autoclosure () -> T?) {
    if lhs != nil { return }
    lhs = rhs()
}

/**
 A simple non-reentrant lock allowing one writer and multiple readers.
 */
private class Lock {
    
    private let lock: UnsafeMutablePointer<pthread_rwlock_t> = {
        var lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        let status = pthread_rwlock_init(lock, nil)
        assert(status == 0)
        return lock
    }()
    
    private func lock<T>(_ acquire: (UnsafeMutablePointer<pthread_rwlock_t>) -> Int32, block: () -> T) -> T {
        let _ = acquire(lock)
        defer { pthread_rwlock_unlock(lock) }
        return block()
    }
    
    func read<T>(_ block: () -> T) -> T {
        return lock(pthread_rwlock_rdlock, block: block)
    }
    
    func write<T>(_ block: () -> T) -> T {
        return lock(pthread_rwlock_wrlock, block: block)
    }
    
    deinit {
        pthread_rwlock_destroy(lock)
    }
}

/**
 A unique key under which to register a block in Guise.
*/
public struct Key: Hashable {
    public let type: String
    public let name: AnyHashable
    public let container: AnyHashable
    
    public init<T, N: Hashable, C: Hashable>(type: T.Type, name: N, container: C) {
        self.type = String(reflecting: T.self)
        self.name = name
        self.container = container
        self.hashValue = hash(self.type, self.name, self.container)
    }
    
    public let hashValue: Int
}

public func ==(lhs: Key, rhs: Key) -> Bool {
    if lhs.hashValue != rhs.hashValue { return false }
    if lhs.type != rhs.type { return false }
    if lhs.name != rhs.name { return false }
    return true
}

/**
 The type of a registration block.
 
 These are what actually get registered. Guise does not register
 types or instances directly.
 */
public typealias Registration<P, T> = (P) -> T

/**
 The type of metadata dictionaries attached to registered dependencies.
 */
public typealias Metadata = [AnyHashable: Any]

/**
 The type of a metadata filter.
 */
public typealias Metafilter = (Metadata) -> Bool

/**
 This class creates and holds a type-erasing thunk over a registration block.
 */
private class Dependency {
    /** Default lifecycle for the dependency. */
    internal let cached: Bool
    /** Registered block. */
    private let registration: (Any) -> Any
    /** Cached instance, if any. */
    private var instance: Any?
    /** Metadata */
    internal let metadata: Metadata
    
    init<P, T>(metadata: Metadata, cached: Bool, registration: @escaping Registration<P, T>) {
        self.metadata = metadata
        self.cached = cached
        self.registration = { param in registration(param as! P) }
    }
    
    func resolve<T>(parameter: Any, cached: Bool?) -> T {
        var result: T
        if cached ?? self.cached {
            if instance == nil {
                instance = registration(parameter)
            }
            result = instance! as! T
        } else {
            result = registration(parameter) as! T
        }
        return result
    }
}

public struct Guise {
    private init() {}
    
    private static var lock = Lock()
    private static var registrations = [Key: Dependency]()
    
    /**
     Private helper method for registration.
    */
    private static func register<P, T>(key: Key, metadata: Metadata = [:], cached: Bool = false, registration: @escaping Registration<P, T>) -> Key {
        lock.write { registrations[key] = Dependency(metadata: metadata, cached: cached, registration: registration) }
        return key
    }
    
    /**
     Register the `registration` block with the type `T` in the given `name` and `container`.
     
     - returns: The unique `Key` for this registration.
     
     - parameters:
        - name: The name under which to register the block.
        - container: The container in which to register the block.
        - metadata: Arbitrary metadata associated with this registration.
        - cached: Whether or not to cache the result of the registration block.
        - registration: The block to register with Guise.
    */
    public static func register<P, T, N: Hashable, C: Hashable>(name: N, container: C, metadata: Metadata = [:], cached: Bool = false, registration: @escaping Registration<P, T>) -> Key {
        return register(key: Key(type: T.self, name: name, container: container), metadata: metadata, cached: cached, registration: registration)
    }

    /**
     Register the `registration` block with Guise under the given name and in the default container.
     
     - returns: The unique `Key` for this registration.
     
     - parameters:
        - name: The name under which to register the block.
        - cached: Whether or not to cache the result of the registration block.
        - registration: The block to register with Guise.
    */
    public static func register<P, T, N: Hashable>(name: N, metadata: Metadata = [:], cached: Bool = false, registration: @escaping Registration<P, T>) -> Key {
        return register(key: Key(type: T.self, name: name, container: Name.default), metadata: metadata, cached: cached, registration: registration)
    }
    
    /**
     Register the `registration` block with Guise with the default name in the given container.
     
     - returns: The unique `Key` for this registration.
     
     - parameters:
         - container: The container in which to register the block.
         - cached: Whether or not to cache the result of the registration block.
         - registration: The block to register with Guise.
    */
    public static func register<P, T, C: Hashable>(container: C, metadata: Metadata = [:], cached: Bool = false, registration: @escaping Registration<P, T>) -> Key {
        return register(key: Key(type: T.self, name: Name.default, container: container), metadata: metadata, cached: cached, registration: registration)
    }

    /**
     Register the `registration` block with Guise with the default name in the default container.
     
     - returns: The unique `Key` for this registration.
     
     - parameters:
         - cached: Whether or not to cache the result of the registration block.
         - registration: The block to register with Guise.
    */
    public static func register<P, T>(metadata: Metadata = [:], cached: Bool = false, registration: @escaping Registration<P, T>) -> Key {
        return register(key: Key(type: T.self, name: Name.default, container: Name.default), metadata: metadata, cached: cached, registration: registration)
    }
    
    /**
     Register the given instance with the specified name and in the specified container.
     
     - returns: The unique `Key` for this registration.
     
     - parameters:
        - instance: The instance to register.
        - name: The name under which to register the block.
        - container: The container in which to register the block.
    */
    public static func register<T, N: Hashable, C: Hashable>(instance: T, name: N, container: C, metadata: Metadata = [:]) -> Key {
        return register(key: Key(type: T.self, name: Name.default, container: Name.default), metadata: metadata, cached: true) { instance }
    }
    
    /**
     Register the given instance with the specified name and in the default container.
     
     - returns: The unique `Key` for this registration.
     
     - parameters:
        - instance: The instance to register.
        - name: The name under which to register the block.
    */
    public static func register<T, N: Hashable>(instance: T, name: N, metadata: Metadata = [:]) -> Key {
        return register(key: Key(type: T.self, name: name, container: Name.default), metadata: metadata, cached: true) { instance }
    }
    
    /**
     Register the given instance with the default name and in the specified container.
     
     - returns: The unique `Key` for this registration.
     
     - parameters:
         - instance: The instance to register.
         - container: The container in which to register the block.
    */
    public static func register<T, C: Hashable>(instance: T, container: C, metadata: Metadata = [:]) -> Key {
        return register(key: Key(type: T.self, name: Name.default, container: container), metadata: metadata, cached: true) { instance }
    }
    
    /**
     Register the given instance with the default name and in the default container.
     
     - returns: The unique `Key` for this registration.
     - parameter instance: The instance to register.
    */
    public static func register<T>(instance: T, metadata: Metadata = [:]) -> Key {
        return register(key: Key(type: T.self, name: Name.default, container: Name.default), metadata: metadata, cached: true) { instance }
    }
    
    /**
     Resolve a dependency registered with the given key.
     
     - returns: The resolved dependency or `nil` if it is not found.
     
     - parameters:
        - key: The key to resolve.
        - parameter: A parameter to pass to the resolution block.
        - cached: Whether to use the cached value or to call the block again.
     
     Passing `nil` for the `cached` parameter causes Guise to use the value of `cached` recorded
     when the dependency was registered. In most cases, this is what you want.
    */
    public static func resolve<T>(key: Key, parameter: Any = (), cached: Bool? = nil) -> T? {
        guard let dependency = lock.read({ registrations[key] }) else { return nil }
        return dependency.resolve(parameter: parameter, cached: cached)
    }
    
    /**
     Resolve multiple registrations at the same time.
     
     - returns: An array of the resolved dependencies.
     
     - parameters:
        - keys: The keys to resolve.
        - parameter: A parameter to pass to the resolution block.
        - cached: Whether to use the cached value or to call the resolution block again.
     
     Passing `nil` for the `cached` parameter causes Guise to use the value of `cached` recorded
     when the dependency was registered. In most cases, this is what you want.
     
     Use the `filter` overloads to conveniently get a list of keys. For example,
     
     ```swift
     // Get the keys for all plugins
     let keys = Guise.filter(type: Plugin.self)
     // Resolve the keys
     let plugins: [Plugin] = Guise.resolve(keys: keys)
     ```
    */
    public static func resolve<T, K: Sequence>(keys: K, parameter: Any = (), cached: Bool? = nil) -> [T] where K.Iterator.Element == Key {
        return lock.read{ registrations.filter{ keys.contains($0.key) }.map{ $0.value } }.map{ $0.resolve(parameter: parameter, cached: cached) }
    }
    
    /**
     Resolve multiple registrations at the same time.
     
     - returns: A dictionary mapping the keys to their resolved dependencies.
    */
    public static func resolve<T, K: Sequence>(keys: K, parameter: Any = (), cached: Bool? = nil) -> [Key: T] where K.Iterator.Element == Key {
        return lock.read{ registrations.filter{ keys.contains($0.key) }.map{ (key: $0.key, value: $0.value.resolve(parameter: parameter, cached: cached)) }.dictionary() }
    }
    
    /**
     Resolve a dependency registered with the given key.
     
     - returns: The resolved dependency or `nil` if it is not found.
     
     - parameters:
         - key: The key to resolve.
         - parameter: A parameter to pass to the resolution block.
         - cached: Whether to use the cached value or to call the block again.
     
     Passing `nil` for the `cached` parameter causes Guise to use the value of `cached` recorded
     when the dependency was registered. In most cases, this is what you want.
    */
    public static func resolve<T, N: Hashable, C: Hashable>(name: N, container: C, parameter: Any = (), cached: Bool? = nil) -> T? {
        return resolve(key: Key(type: T.self, name: name, container: container), parameter: parameter, cached: cached)
    }
    
    /**
     Resolve a dependency registered with the given type `T` and `name`.
     
     - returns: The resolved dependency or `nil` if it is not found.
     
     - parameters:
         - name: The name under which the block was registered.
         - parameter: A parameter to pass to the resolution block.
         - cached: Whether to use the cached value or to call the block again.
     
     Passing `nil` for the `cached` parameter causes Guise to use the value of `cached` recorded
     when the dependency was registered. In most cases, this is what you want.
    */
    public static func resolve<T, N: Hashable>(name: N, parameter: Any = (), cached: Bool? = nil) -> T? {
        return resolve(key: Key(type: T.self, name: name, container: Name.default), parameter: parameter, cached: cached)
    }

    /**
     Resolve a dependency registered with the given type `T` in the given `container`.
     
     - returns: The resolved dependency or `nil` if it is not found.
     
     - parameters:
         - container: The key to resolve.
         - parameter: A parameter to pass to the resolution block.
         - cached: Whether to use the cached value or to call the block again.
     
     Passing `nil` for the `cached` parameter causes Guise to use the value of `cached` recorded
     when the dependency was registered. In most cases, this is what you want.
    */
    public static func resolve<T, C: Hashable>(container: C, parameter: Any = (), cached: Bool? = nil) -> T? {
        return resolve(key: Key(type: T.self, name: Name.default, container: container), parameter: parameter, cached: cached)
    }

    /**
     Resolve a registered dependency.
     
     - returns: The resolved dependency or `nil` if it is not found.
     
     - parameters:
         - parameter: A parameter to pass to the resolution block.
         - cached: Whether to use the cached value or to call the block again.
     
     Passing `nil` for the `cached` parameter causes Guise to use the value of `cached` recorded
     when the dependency was registered. In most cases, this is what you want.
    */
    public static func resolve<T>(parameter: Any = (), cached: Bool? = nil) -> T? {
        return resolve(key: Key(type: T.self, name: Name.default, container: Name.default), parameter: parameter, cached: cached)
    }
    
    /**
     Helper method for filtering.
     */
    private static func filter(type: String?, name: AnyHashable?, container: AnyHashable?, metafilter: Metafilter? = nil) -> [Key] {
        return lock.read {
            var keys = [Key]()
            for (key, dependency) in registrations {
                if let type = type, type != key.type { continue }
                if let name = name, name != key.name { continue }
                if let container = container, container != key.container { continue }
                if let metafilter = metafilter, !metafilter(dependency.metadata) { continue }
                keys.append(key)
            }
            return keys
        }
    }
    
    /**
     Find the given key, optionally matching the metafilter query.
     
     This method will always return either an empty array or an array with one element.
    */
    public static func filter(key: Key, metafilter: Metafilter? = nil) -> [Key] {
        return lock.read {
            guard let dependency = registrations[key] else { return [] }
            if let metafilter = metafilter, metafilter(dependency.metadata) { return [key] }
            return []
        }
    }
    
    /**
     Find all keys for the given type, name, and container.
     
     Because all of type, name, and container are specified, this particular method will return either 
     an empty array or an array with a single value.
    */
    public static func filter<T, N: Hashable, C: Hashable>(type: T.Type, name: N, container: C, metafilter: Metafilter? = nil) -> [Key] {
        let key = Key(type: type, name: name, container: container)
        return filter(key: key)
    }
    
    /**
     Find all keys for the given type and name, independent of container.
    */
    public static func filter<T, N: Hashable>(type: T.Type, name: N, metafilter: Metafilter? = nil) -> [Key] {
        return filter(type: String(reflecting: type), name: name, container: nil, metafilter: metafilter)
    }
    
    /**
     Find all keys for the given type and container, independent of name.
    */
    public static func filter<T, C: Hashable>(type: T.Type, container: C, metafilter: Metafilter? = nil) -> [Key] {
        return filter(type: String(reflecting: type), name: nil, container: container, metafilter: metafilter)
    }
    
    /**
     Find all keys for the given name and container, independent of type.
    */
    public static func filter<N: Hashable, C: Hashable>(name: N, container: C, metafilter: Metafilter? = nil) -> [Key] {
        return filter(type: nil, name: name, container: container, metafilter: metafilter)
    }
    
    /**
     Find all keys for the given name, independent of the given type and container.
    */
    public static func filter<N: Hashable>(name: N, metafilter: Metafilter? = nil) -> [Key] {
        return filter(type: nil, name: name, container: nil, metafilter: metafilter)
    }
    
    /**
     Find all keys for the given container, independent of given type and name.
    */
    public static func filter<C: Hashable>(container: C, metafilter: Metafilter? = nil) -> [Key] {
        return filter(type: nil, name: nil, container: container, metafilter: metafilter)
    }
    
    /**
     Find all keys for the given type, independent of name and container.
    */
    public static func filter<T>(type: T.Type, metafilter: Metafilter? = nil) -> [Key] {
        return filter(type: String(reflecting: type), name: nil, container: nil, metafilter: metafilter)
    }
    
    public static func filter(metafilter: Metafilter? = nil) -> [Key] {
        return filter(type: nil, name: nil, container: nil, metafilter: metafilter)
    }
    
    /**
     Helper method for filtering.
     */
    private static func exists(type: String?, name: AnyHashable?, container: AnyHashable?, metafilter: Metafilter? = nil) -> Bool {
        return lock.read {
            for key in registrations.keys {
                if let type = type, type != key.type { continue }
                if let name = name, name != key.name { continue }
                if let container = container, container != key.container { continue }
                return true
            }
            return false
        }
    }
    
    /**
     Returns true if a registration exists for the given key.
    */
    public static func exists(key: Key, metafilter: Metafilter? = nil) -> Bool {
        return lock.read {
            guard let dependency = registrations[key] else { return false }
            if let metafilter = metafilter { return metafilter(dependency.metadata) }
            return true
        }
    }
    
    /**
     Returns true if a key with the given type, name, and container exists.
    */
    public static func exists<T, N: Hashable, C: Hashable>(type: T.Type, name: N, container: C, metafilter: Metafilter? = nil) -> Bool {
        return exists(key: Key(type: type, name: name, container: container), metafilter: metafilter)
    }
    
    /**
     Returns true if any keys with the given type and name exist in any containers.
    */
    public static func exists<T, N: Hashable>(type: T.Type, name: N, metafilter: Metafilter? = nil) -> Bool {
        return exists(type: String(reflecting: type), name: name, container: nil, metafilter: metafilter)
    }
    
    /**
     Returns true if any keys with the given type exist in the given container, independent of name.
    */
    public static func exists<T, C: Hashable>(type: T.Type, container: C, metafilter: Metafilter? = nil) -> Bool {
        return exists(type: String(reflecting: type), name: nil, container: container, metafilter: metafilter)
    }
    
    /**
     Returns true if any keys with the given name exist in the given container, independent of type.
    */
    public static func exists<N: Hashable, C: Hashable>(name: N, container: C, metafilter: Metafilter? = nil) -> Bool {
        return exists(type: nil, name: name, container: container, metafilter: metafilter)
    }
    
    /**
     Return true if any keys with the given name exist in any container, independent of type.
    */
    public static func exists<N: Hashable>(name: N, metafilter: Metafilter? = nil) -> Bool {
        return exists(type: nil, name: name, container: nil, metafilter: metafilter)
    }
    
    /**
     Returns true if there are any keys registered in the given container.
    */
    public static func exists<C: Hashable>(container: C, metafilter: Metafilter? = nil) -> Bool {
        return exists(type: nil, name: nil, container: container, metafilter: metafilter)
    }
    
    /**
     Returns true if there are any keys registered with the given type in any container, independent of name.
    */
    public static func exists<T>(type: T.Type, metafilter: Metafilter? = nil) -> Bool {
        return exists(type: String(reflecting: type), name: nil, container: nil, metafilter: metafilter)
    }
    
    /**
     All keys.
    */
    public static var keys: [Key] {
        return lock.read { Array(registrations.keys) }
    }
    
    /**
     Retrieve metadata
    */
    public static func metadata(for key: Key) -> Metadata? {
        return lock.read {
            guard let dependency = registrations[key] else { return nil }
            return dependency.metadata
        }
    }
    
    /**
     Retrieve metadata for multiple keys.
    */
    public static func metadata<K: Sequence>(for keys: K) -> [Key: Metadata] where K.Iterator.Element == Key {
        return lock.read { registrations.filter{ keys.contains($0.key) }.map{ (key: $0.key, value: $0.value.metadata) }.dictionary() }
    }
    
    /**
     Remove the dependencies registered under the given key(s).
    */
    public static func unregister(key: Key...) {
        unregister(keys: key)
    }
    
    /**
     Remove the dependencies registered under the given keys.
    */
    public static func unregister<K: Sequence>(keys: K) where K.Iterator.Element == Key {
        lock.write { registrations = registrations.filter{ !keys.contains($0.key) }.dictionary() }
    }
    
    /**
     Remove all dependencies.
    */
    public static func clear() {
        lock.write { registrations = [:] }
    }
}

extension Array {
    /**
     Reconstruct a dictionary after it's been reduced to an array of key-value pairs by `filter` and the like.
     
     ```
     var dictionary = [1: "ok", 2: "crazy", 99: "abnormal"]
     dictionary = dictionary.filter{ $0.value == "ok" }.dictionary()
     ```
    */
    func dictionary<K: Hashable, V>() -> [K: V] where Element == Dictionary<K, V>.Element {
        var dictionary = [K: V]()
        for element in self {
            dictionary[element.key] = element.value
        }
        return dictionary
    }
}
