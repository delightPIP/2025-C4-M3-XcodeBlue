//
//  HealthKitBackgroundService.swift
//  TarTanning
//
//  Created by taeni on 7/15/25.
//

import Foundation
import HealthKit
import SwiftData

@MainActor
protocol HealthKitBackgroundManagerDelegate: AnyObject {
    func backgroundDeliveryDidEnable(for type: HKObjectType)
    func backgroundDeliveryDidDisable(for type: HKObjectType)
    func observerQueryDidUpdate(for type: HKSampleType)
    func healthKitBackgroundServiceDidFail(with error: HealthKitError)
}

@MainActor
final class HealthKitBackgroundManager: ObservableObject {
    // MARK: - Singleton (전역에서 접근 가능)
    static let shared = HealthKitBackgroundManager()
    
    // MARK: - Delegate 및 의존성
    weak var delegate: HealthKitBackgroundManagerDelegate?
    var syncUseCase: SyncUVDataInBackgroundUseCase?

    // MARK: - 내부 상태
    private let healthStore = HKHealthStore()
    private var activeObserverQueries: Set<HKObserverQuery> = []

    @Published var isBackgroundDeliveryEnabled: Bool = false
    @Published var lastObservedType: HKSampleType?
    @Published var errorMessage: String?

    // MARK: - Background Delivery
    
    func configure(syncUseCase: SyncUVDataInBackgroundUseCase, for type: HKSampleType) async {
        self.syncUseCase = syncUseCase
        await enableBackgroundDelivery(for: type, frequency: .immediate)
        setupObserverQuery(for: type)
        print("[HealthKitBackgroundManager] Fully configured with useCase")
    }

    func enableBackgroundDelivery(for type: HKObjectType, frequency: HKUpdateFrequency) async {
        do {
            let success: Bool = try await withCheckedThrowingContinuation { continuation in
                healthStore.enableBackgroundDelivery(for: type, frequency: frequency) { success, error in
                    if let error = error {
                        continuation.resume(throwing: HealthKitError.backgroundDeliveryFailed(error))
                    } else {
                        continuation.resume(returning: success)
                    }
                }
            }

            isBackgroundDeliveryEnabled = success
            if success {
                errorMessage = nil
                delegate?.backgroundDeliveryDidEnable(for: type)
            } else {
                let error = HealthKitError.backgroundDeliveryFailed(NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Enable background delivery returned false"]))
                errorMessage = error.localizedDescription
                delegate?.healthKitBackgroundServiceDidFail(with: error)
            }

        } catch {
            let hkError = (error as? HealthKitError) ?? .backgroundDeliveryFailed(error)
            isBackgroundDeliveryEnabled = false
            errorMessage = hkError.localizedDescription
            delegate?.healthKitBackgroundServiceDidFail(with: hkError)
        }
    }

    func disableBackgroundDelivery(for type: HKObjectType) async {
        do {
            let success: Bool = try await withCheckedThrowingContinuation { continuation in
                healthStore.disableBackgroundDelivery(for: type) { success, error in
                    if let error = error {
                        continuation.resume(throwing: HealthKitError.backgroundDeliveryFailed(error))
                    } else {
                        continuation.resume(returning: success)
                    }
                }
            }

            isBackgroundDeliveryEnabled = !success
            if success {
                errorMessage = nil
                delegate?.backgroundDeliveryDidDisable(for: type)
            } else {
                let error = HealthKitError.backgroundDeliveryFailed(NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Disable background delivery returned false"]))
                errorMessage = error.localizedDescription
                delegate?.healthKitBackgroundServiceDidFail(with: error)
            }

        } catch {
            let hkError = (error as? HealthKitError) ?? .backgroundDeliveryFailed(error)
            errorMessage = hkError.localizedDescription
            delegate?.healthKitBackgroundServiceDidFail(with: hkError)
        }
    }

    // MARK: - Observer Query 설정

    func setupObserverQuery(for type: HKSampleType) {
        let observerQuery = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
            defer { completionHandler() }

            Task { @MainActor in
                guard let self else { return }

                if let error = error {
                    self.errorMessage = HealthKitError.observerQueryFailed(error).localizedDescription
                    self.delegate?.healthKitBackgroundServiceDidFail(with: .observerQueryFailed(error))
                } else {
                    self.lastObservedType = type
                    self.delegate?.observerQueryDidUpdate(for: type)
                    
                    print("[HealthKitBackgroundManager] ObserverQuery triggered. Executing background sync...")

                    if let syncUseCase = self.syncUseCase {
                        await syncUseCase.execute()
                        print("[HealthKitBackgroundManager] Background sync complete.")
                    } else {
                        print("[HealthKitBackgroundManager] syncUseCase not set")
                    }
                }
            }
        }

        activeObserverQueries.insert(observerQuery)
        healthStore.execute(observerQuery)
    }

    func stopAllObserverQueries() {
        activeObserverQueries.forEach { healthStore.stop($0) }
        activeObserverQueries.removeAll()
    }
}
