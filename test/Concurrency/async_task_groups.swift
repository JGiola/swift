// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency
// REQUIRES: concurrency

func asyncFunc() async -> Int { 42 }
func asyncThrowsFunc() async throws -> Int { 42 }
func asyncThrowsOnCancel() async throws -> Int {
  // terrible suspend-spin-loop -- do not do this
  // only for purposes of demonstration
  while await !Task.isCancelled() {
    await Task.sleep(until: Task.Deadline.in(.seconds(1)))
  }

  throw Task.CancellationError()
}

func test_taskGroup_add() async throws -> Int {
  await try Task.withGroup(resultType: Int.self) { group in
    await group.add {
      await asyncFunc()
    }

    await group.add {
      await asyncFunc()
    }

    var sum = 0
    while let v = await try group.next() {
      sum += v
    }
    return sum
  } // implicitly awaits
}

func test_taskGroup_addHandles() async throws -> Int {
  await try Task.withGroup(resultType: Int.self) { group in
    let one = await group.addWithHandle {
      await asyncFunc()
    }

    let two = await group.addWithHandle {
      await asyncFunc()
    }

    _ = await try one.get()
    _ = await try two.get()
  } // implicitly awaits
}

func test_taskGroup_cancel_handles() async throws {
  await try Task.withGroup(resultType: Int.self) { group in
    let one = await group.addWithHandle {
      await try asyncThrowsOnCancel()
    }

    let two = await group.addWithHandle {
      await asyncFunc()
    }

    _ = await try one.get()
    _ = await try two.get()
  } // implicitly awaits
}

// ==== ------------------------------------------------------------------------
// MARK: Example group Usages

struct Boom: Error {}
func work() async -> Int { 42 }
func boom() async throws -> Int { throw Boom() }

func first_allMustSucceed() async throws {

  let first: Int = await try Task.withGroup(resultType: Int.self) { group in
    await group.add { await work() }
    await group.add { await work() }
    await group.add { await try boom() }

    if let first = await try group.next() {
      return first
    } else {
      fatalError("Should never happen, we either throw, or get a result from any of the tasks")
    }
    // implicitly await: boom
  }
  _ = first
  // Expected: re-thrown Boom
}

func first_ignoreFailures() async throws {
  func work() async -> Int { 42 }
  func boom() async throws -> Int { throw Boom() }

  let first: Int = await try Task.withGroup(resultType: Int.self) { group in
    await group.add { await work() }
    await group.add { await work() }
    await group.add {
      do {
        return await try boom()
      } catch {
        return 0 // TODO: until await try? works properly
      }
    }

    var result: Int = 0
    while let v = await try group.next() {
      result = v

      if result != 0 {
        break
      }
    }

    return result
  }
  _ = first
  // Expected: re-thrown Boom
}

// ==== ------------------------------------------------------------------------
// MARK: Advanced Custom Task Group Usage

func test_taskGroup_quorum_thenCancel() async {
  // imitates a typical "gather quorum" routine that is typical in distributed systems programming
  enum Vote {
    case yay
    case nay
  }
  struct Follower {
    init(_ name: String) {}
    func vote() async throws -> Vote {
      // "randomly" vote yes or no
      return .yay
    }
  }

  /// Performs a simple quorum vote among the followers.
  ///
  /// - Returns: `true` iff `N/2 + 1` followers return `.yay`, `false` otherwise.
  func gatherQuorum(followers: [Follower]) async -> Bool {
    await try! Task.withGroup(resultType: Vote.self) { group in
      for follower in followers {
        await group.add { await try follower.vote() }
      }

      defer {
        group.cancelAll()
      }

      var yays: Int = 0
      var nays: Int = 0
      let quorum = Int(followers.count / 2) + 1
      while let vote = await try group.next() {
        switch vote {
        case .yay:
          yays += 1
          if yays >= quorum {
            // cancel all remaining voters, we already reached quorum
            return true
          }
        case .nay:
          nays += 1
          if nays >= quorum {
            return false
          }
        }
      }

      return false
    }
  }

  _ = await gatherQuorum(followers: [Follower("A"), Follower("B"), Follower("C")])
}

