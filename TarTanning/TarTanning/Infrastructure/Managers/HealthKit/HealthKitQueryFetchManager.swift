//
//  HealthKitQueryFetchManager.swift
//  TarTanning
//
//  Created by taeni on 7/23/25.
//

import Foundation
import HealthKit

@MainActor
protocol HealthKitQueryFetchManagerDelegate: AnyObject {
    func fetchManagerDidFetchSamples(_ samples: [HKQuantitySample])
    func fetchManagerDidFail(with error: HealthKitError)
}

@MainActor
final class HealthKitQueryFetchManager: ObservableObject {
    static let shared = HealthKitQueryFetchManager()
    
    weak var delegate: HealthKitQueryFetchManagerDelegate?
    private let healthStore = HKHealthStore()

    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // Background observation properties
    private var backgroundObserverQuery: HKObserverQuery?
    private var backgroundDeliveryQuery: HKObserverQuery?
    
    private init() {}

    // MARK: - Authorization Methods
    
    /// HealthKit 권한 상태 확인 (간단한 확인용)
    func checkAuthorizationStatus() async -> Bool {
        guard let daylightType = HKQuantityType.quantityType(forIdentifier: .timeInDaylight) else {
            return false
        }
        
        let status = healthStore.authorizationStatus(for: daylightType)
        
        switch status {
        case .notDetermined:
            print("[HealthKitQueryFetchManager] HealthKit authorization: NOT_DETERMINED - 권한 요청 필요")
            return false
        case .sharingDenied:
            print("[HealthKitQueryFetchManager] HealthKit authorization: DENIED - 사용자가 거부함")
            return false
        case .sharingAuthorized:
            print("[HealthKitQueryFetchManager] HealthKit authorization: AUTHORIZED - 권한 있음")
            return true
        @unknown default:
            print("[HealthKitQueryFetchManager] HealthKit authorization: UNKNOWN(\(status.rawValue))")
            return false
        }
    }
    


    // MARK: 1. 하루 동안의 모든 샘플 가져오기
    func fetchTodaySamples() async {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        
        print("[HealthKitQueryFetchManager] Fetching today's samples from \(startOfDay.formatted()) to \(now.formatted())")
        await fetchSamples(from: startOfDay, to: now)
    }

    // MARK: 2. 특정 기간의 모든 샘플 가져오기
    func fetchSamples(from startDate: Date, to endDate: Date) async {
        guard let daylightType = HKQuantityType.quantityType(forIdentifier: .timeInDaylight) else {
            let error = HealthKitError.invalidType
            errorMessage = error.localizedDescription
            delegate?.fetchManagerDidFail(with: error)
            return
        }

        isLoading = true

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        do {
            let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: daylightType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [
                        NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                    ]
                ) { _, results, error in
                    if let error = error {
                        print("[HealthKitQueryFetchManager] Query error: \(error)")
                        continuation.resume(throwing: HealthKitError.queryFailed(error))
                    } else {
                        let quantitySamples = (results as? [HKQuantitySample]) ?? []
                        print("[HealthKitQueryFetchManager] Query successful, found \(quantitySamples.count) samples")
                        
                        // 샘플 상세 정보 출력
                        for (index, sample) in quantitySamples.enumerated() {
                            let durationMinutes = sample.quantity.doubleValue(for: .minute())
                            print("[HealthKitQueryFetchManager] Sample \(index + 1): \(durationMinutes) minutes (\(sample.startDate.formatted(date: .omitted, time: .shortened)) - \(sample.endDate.formatted(date: .omitted, time: .shortened)))")
                        }
                        
                        continuation.resume(returning: quantitySamples)
                    }
                }

                healthStore.execute(query)
            }

            isLoading = false
            errorMessage = nil
            delegate?.fetchManagerDidFetchSamples(samples)

        } catch {
            let hkError = (error as? HealthKitError) ?? HealthKitError.queryFailed(error)
            isLoading = false
            errorMessage = hkError.localizedDescription
            delegate?.fetchManagerDidFail(with: hkError)
        }
    }

    // MARK: 3. 특정 시점부터 N개의 샘플 가져오기
    func fetchSamples(from startDate: Date, limit: Int) async {
        guard let daylightType = HKQuantityType.quantityType(forIdentifier: .timeInDaylight) else {
            let error = HealthKitError.invalidType
            errorMessage = error.localizedDescription
            delegate?.fetchManagerDidFail(with: error)
            return
        }

        isLoading = true

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: nil, // future 제한 없이
            options: .strictStartDate
        )

        do {
            let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: daylightType,
                    predicate: predicate,
                    limit: limit,
                    sortDescriptors: [
                        NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                    ]
                ) { _, results, error in
                    if let error = error {
                        continuation.resume(throwing: HealthKitError.queryFailed(error))
                    } else {
                        let quantitySamples = (results as? [HKQuantitySample]) ?? []
                        continuation.resume(returning: quantitySamples)
                    }
                }

                healthStore.execute(query)
            }

            isLoading = false
            errorMessage = nil
            delegate?.fetchManagerDidFetchSamples(samples)

        } catch {
            let hkError = (error as? HealthKitError) ?? HealthKitError.queryFailed(error)
            isLoading = false
            errorMessage = hkError.localizedDescription
            delegate?.fetchManagerDidFail(with: hkError)
        }
    }
    
    // MARK: - Background Observation Methods
    
    /// HealthKit 데이터 변경 관찰 시작
    func startObservingHealthKitUpdates() {
        // 1. 중복 실행 방지
        guard backgroundObserverQuery == nil else {
            print("[HealthKitQueryFetchManager] Observer query already running")
            return
        }
        
        guard let daylightType = HKQuantityType.quantityType(forIdentifier: .timeInDaylight) else {
            print("[HealthKitQueryFetchManager] Invalid daylight type")
            return
        }
        
        // 2. 권한 확인
        let authStatus = healthStore.authorizationStatus(for: daylightType)
        guard authStatus == .sharingAuthorized else {
            print("[HealthKitQueryFetchManager] HealthKit authorization not granted: \(authStatus.rawValue)")
            return
        }
        
        // 3. Observer Query 설정 (데이터 변경 감지)
        backgroundObserverQuery = HKObserverQuery(sampleType: daylightType, predicate: nil) { [weak self] _, _, error in
            if let error = error {
                print("[HealthKitQueryFetchManager] Observer query error: \(error)")
            } else {
                print("[HealthKitQueryFetchManager] HealthKit data change detected")
                // NotificationCenter로 업데이트 알림
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .healthKitDataUpdated, object: nil)
                }
            }
        }
        
        // 4. Background Delivery 설정 (앱이 백그라운드일 때도 업데이트 받기)
        healthStore.enableBackgroundDelivery(for: daylightType, frequency: .hourly) { success, error in
            if success {
                print("[HealthKitQueryFetchManager] Background delivery enabled")
            } else if let error = error {
                print("[HealthKitQueryFetchManager] Background delivery failed: \(error)")
            }
        }
        
        // 5. Observer Query 실행
        if let observerQuery = backgroundObserverQuery {
            healthStore.execute(observerQuery)
        }
    }

    /// 권한이 허용된 후 Observer 시작하는 메서드 추가
    func startObservingWhenAuthorized() {
        guard let daylightType = HKQuantityType.quantityType(forIdentifier: .timeInDaylight) else {
            return
        }
        
        let authStatus = healthStore.authorizationStatus(for: daylightType)
        
        switch authStatus {
        case .sharingAuthorized:
            startObservingHealthKitUpdates()
        case .notDetermined:
            print("[HealthKitQueryFetchManager] Authorization not determined, waiting for user permission")
        case .sharingDenied:
            print("[HealthKitQueryFetchManager] Authorization denied by user")
        @unknown default:
            print("[HealthKitQueryFetchManager] Unknown authorization status: \(authStatus.rawValue)")
        }
    }
    
    /// HealthKit 데이터 변경 관찰 중지
    func stopObservingHealthKitUpdates() {
        if let observerQuery = backgroundObserverQuery {
            healthStore.stop(observerQuery)
            backgroundObserverQuery = nil
            print("[HealthKitQueryFetchManager] Stopped observing HealthKit updates")
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let healthKitDataUpdated = Notification.Name("healthKitDataUpdated")
}
