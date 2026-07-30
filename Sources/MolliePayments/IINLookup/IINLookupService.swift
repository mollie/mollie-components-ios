import Foundation
import MollieCore

package actor IINLookupService {
    private let httpClient: any HTTPClient
    private let debounceInterval: TimeInterval
    private var pendingTask: Task<IINResult?, Never>?

    package init(httpClient: any HTTPClient, debounceInterval: TimeInterval = 0.3) {
        self.httpClient = httpClient
        self.debounceInterval = debounceInterval
    }

    package func lookup(prefix: String) async -> IINResult? {
        guard prefix.count >= 6 else { return nil }
        pendingTask?.cancel()
        let task = Task<IINResult?, Never> { [httpClient, debounceInterval] in
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
            if Task.isCancelled {
                return nil
            }
            return try? await httpClient.perform(IINEndpoint.lookup(prefix: prefix))
        }
        pendingTask = task
        return await task.value
    }
}
